#!/usr/bin/env bash
set -Eeuo pipefail

mount_root="${QWEN_NETWORK_VOLUME_MOUNT:-/runpod-volume}"
mount_root="$(realpath -e "$mount_root")" || {
    echo "Network Volume mount path does not exist" >&2
    exit 2
}
volume_dir="${QWEN_MODEL_VOLUME_DIR:-$mount_root/qwen-models}"
volume_dir="$(realpath -m "$volume_dir")"
case "$volume_dir" in
    "$mount_root"/*) ;;
    *) echo "QWEN_MODEL_VOLUME_DIR must be inside $mount_root" >&2; exit 2 ;;
esac
if ! mountpoint -q "$mount_root"; then
    echo "RunPod Network Volume is not mounted at $mount_root" >&2
    exit 2
fi

names=(
    "qwen_image_edit_2511_fp8mixed.safetensors"
    "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
    "qwen_2.5_vl_7b_fp8_scaled.safetensors"
    "qwen_image_vae.safetensors"
)
sources=(
    "/ComfyUI/models/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors"
    "/ComfyUI/models/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
    "/ComfyUI/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
    "/ComfyUI/models/vae/qwen_image_vae.safetensors"
)

mkdir -p "$volume_dir"
lock_dir="$volume_dir/.qwen-model-seed.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "A Qwen model-volume seed is already running or left a stale lock: $lock_dir" >&2
    echo "Verify no other seeder is active before removing that lock directory." >&2
    exit 3
fi
temp_path=""
cleanup() {
    [ -z "$temp_path" ] || rm -f -- "$temp_path"
    rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

start_time=$(date +%s)
for i in "${!names[@]}"; do
    source_path="${sources[$i]}"
    target_path="$volume_dir/${names[$i]}"
    if [ ! -s "$source_path" ]; then
        echo "Source model is missing or empty: $source_path" >&2
        exit 4
    fi

    if [ -e "$target_path" ]; then
        source_real=$(readlink -f -- "$source_path")
        target_real=$(readlink -f -- "$target_path")
        if [ "$source_real" = "$target_real" ]; then
            echo "QWEN_VOLUME_SEED file=${names[$i]} result=already_linked"
            continue
        fi
        source_hash=$(sha256sum -- "$source_path" | awk '{print $1}')
        target_hash=$(sha256sum -- "$target_path" | awk '{print $1}')
        if [ "$source_hash" != "$target_hash" ]; then
            echo "Refusing to overwrite a different existing volume file: $target_path" >&2
            exit 5
        fi
        echo "QWEN_VOLUME_SEED file=${names[$i]} result=verified_existing"
        continue
    fi

    temp_path="$target_path.partial.$$"
    cp -- "$source_path" "$temp_path"
    source_hash=$(sha256sum -- "$source_path" | awk '{print $1}')
    copied_hash=$(sha256sum -- "$temp_path" | awk '{print $1}')
    if [ "$source_hash" != "$copied_hash" ]; then
        echo "SHA-256 verification failed while copying ${names[$i]}" >&2
        exit 6
    fi
    mv -- "$temp_path" "$target_path"
    temp_path=""
    echo "QWEN_VOLUME_SEED file=${names[$i]} result=copied_and_sha256_verified bytes=$(stat -c '%s' "$target_path")"
done

echo "QWEN_VOLUME_SEED total_seconds=$(($(date +%s) - start_time)) result=PASS"
