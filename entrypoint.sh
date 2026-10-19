#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
BOOT_START_EPOCH=$(date +%s)
log_elapsed() {
    local label="$1"
    local now
    now=$(date +%s)
    echo "QWEN_TIMING stage=${label} elapsed_seconds=$((now - BOOT_START_EPOCH))"
}

configure_qwen_model_volume() {
    local volume_dir="${QWEN_MODEL_VOLUME_DIR:-}"
    if [ -z "$volume_dir" ]; then
        if [ "${QWEN_MODEL_STORAGE:-container}" = "volume" ]; then
            echo "QWEN_MODEL_STORAGE=volume requires QWEN_MODEL_VOLUME_DIR" >&2
            return 1
        fi
        return 0
    fi

    local mount_root="${QWEN_NETWORK_VOLUME_MOUNT:-/runpod-volume}"
    mount_root="$(realpath -e "$mount_root")" || {
        echo "Network Volume mount path does not exist" >&2
        return 1
    }
    volume_dir="$(realpath -m "$volume_dir")"
    case "$volume_dir" in
        "$mount_root"/*) ;;
        *) echo "QWEN_MODEL_VOLUME_DIR must be inside $mount_root" >&2; return 1 ;;
    esac
    if ! mountpoint -q "$mount_root"; then
        echo "RunPod Network Volume is not mounted at $mount_root" >&2
        return 1
    fi

    local names=(
        "qwen_image_edit_2511_fp8mixed.safetensors"
        "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
        "qwen_2.5_vl_7b_fp8_scaled.safetensors"
        "qwen_image_vae.safetensors"
    )
    local paths=(
        "/ComfyUI/models/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors"
        "/ComfyUI/models/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
        "/ComfyUI/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
        "/ComfyUI/models/vae/qwen_image_vae.safetensors"
    )

    local i target
    for i in "${!names[@]}"; do
        target="$volume_dir/${names[$i]}"
        if [ ! -s "$target" ]; then
            echo "Required Qwen model is missing or empty on the volume: $target" >&2
            echo "Seed the volume from the model-baked runtime before enabling volume mode." >&2
            return 1
        fi
        mkdir -p "$(dirname "${paths[$i]}")"
        ln -sfn "$target" "${paths[$i]}"
    done
    echo "Qwen models linked from Network Volume: $volume_dir"
}

log_qwen_model_sizes() {
    local names=(
        "qwen_image_edit_2511_fp8mixed.safetensors"
        "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
        "qwen_2.5_vl_7b_fp8_scaled.safetensors"
        "qwen_image_vae.safetensors"
    )
    local paths=(
        "/ComfyUI/models/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors"
        "/ComfyUI/models/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
        "/ComfyUI/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
        "/ComfyUI/models/vae/qwen_image_vae.safetensors"
    )
    local total=0 i bytes
    for i in "${!names[@]}"; do
        if [ ! -s "${paths[$i]}" ]; then
            echo "Required Qwen model is missing or empty: ${paths[$i]}" >&2
            return 1
        fi
        bytes=$(stat -c '%s' "${paths[$i]}")
        total=$((total + bytes))
        echo "QWEN_MODEL_ASSET name=${names[$i]} bytes=$bytes"
    done
    echo "QWEN_MODEL_ASSET_TOTAL bytes=$total"
}

if [ "${QWEN_SEED_MODEL_VOLUME:-false}" = "true" ]; then
    mount_root="${QWEN_NETWORK_VOLUME_MOUNT:-/runpod-volume}"
    mount_root="$(realpath -e "$mount_root")" || {
        echo "Network Volume mount path does not exist" >&2
        exit 1
    }
    export QWEN_MODEL_VOLUME_DIR="${QWEN_MODEL_VOLUME_DIR:-$mount_root/qwen-models}"
    /seed_qwen_models_to_volume.sh
fi
configure_qwen_model_volume
log_qwen_model_sizes

# CUDA 검사 및 설정
echo "Checking CUDA availability..."

# Python을 통한 CUDA 검사
python_cuda_check() {
    python3 -c "
import torch
try:
    if torch.cuda.is_available():
        print('CUDA_AVAILABLE')
        exit(0)
    else:
        print('CUDA_NOT_AVAILABLE')
        exit(1)
except Exception as e:
    print(f'CUDA_ERROR: {e}')
    exit(2)
" 2>/dev/null
}

# CUDA 검사 실행
cuda_status=$(python_cuda_check)
case $? in
    0)
        echo "✅ CUDA is available and working (Python check)"
        export CUDA_VISIBLE_DEVICES=0
        export FORCE_CUDA=1
        ;;
    1)
        echo "❌ CUDA is not available (Python check)"
        echo "Error: CUDA is required but not available. Exiting..."
        exit 1
        ;;
    2)
        echo "❌ CUDA check failed (Python check)"
        echo "Error: CUDA initialization failed. Exiting..."
        exit 1
        ;;
esac
log_elapsed cuda_check_complete

# 추가적인 nvidia-smi 검사
if command -v nvidia-smi &> /dev/null; then
    if nvidia-smi &> /dev/null; then
        echo "✅ NVIDIA driver working (nvidia-smi check)"
    else
        echo "❌ NVIDIA driver found but not working"
        echo "Error: NVIDIA driver is not working properly. Exiting..."
        exit 1
    fi
else
    echo "❌ NVIDIA driver not found"
    echo "Error: NVIDIA driver is required but not found. Exiting..."
    exit 1
fi

# CUDA 환경 변수 설정
echo "Using CUDA device: $CUDA_VISIBLE_DEVICES"

# Start ComfyUI in the background
echo "Starting ComfyUI in the background..."
python /ComfyUI/main.py --listen --use-sage-attention &

# Wait for ComfyUI to be ready
echo "Waiting for ComfyUI to be ready..."
max_wait=120  # 최대 2분 대기
wait_count=0
while [ $wait_count -lt $max_wait ]; do
    if curl -s http://127.0.0.1:8188/ > /dev/null 2>&1; then
        echo "ComfyUI is ready!"
        break
    fi
    echo "Waiting for ComfyUI... ($wait_count/$max_wait)"
    sleep 2
    wait_count=$((wait_count + 2))
done

if [ $wait_count -ge $max_wait ]; then
    echo "Error: ComfyUI failed to start within $max_wait seconds"
    exit 1
fi
log_elapsed comfyui_ready

# Start the handler in the foreground
# 이 스크립트가 컨테이너의 메인 프로세스가 됩니다.
echo "Starting the handler..."
log_elapsed handler_start
exec python handler.py
