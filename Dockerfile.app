# Build small application-only releases against a previously published,
# immutable Qwen runtime image. Pass a registry image digest as build arg.
ARG QWEN_RUNTIME_IMAGE
FROM ${QWEN_RUNTIME_IMAGE}

WORKDIR /
COPY handler.py /handler.py
COPY comfy_timing.py /comfy_timing.py
COPY workflow/ /workflow/
COPY entrypoint.sh /entrypoint.sh
COPY seed_qwen_models_to_volume.sh /seed_qwen_models_to_volume.sh
RUN chmod +x /entrypoint.sh /seed_qwen_models_to_volume.sh

CMD ["/entrypoint.sh"]
