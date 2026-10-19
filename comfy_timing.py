"""Small, dependency-free helpers for separating ComfyUI job phase timings."""

from __future__ import annotations

import json
import time
from typing import Any, Callable


def wait_for_execution(ws: Any, prompt_id: str, queued_at: float,
                       clock: Callable[[], float] = time.monotonic) -> dict[str, float]:
    """Wait for one ComfyUI prompt and measure queue wait vs execution time.

    ComfyUI's websocket marks execution start/completion but does not reliably
    expose model-load time separately from sampler time. The execution metric
    intentionally keeps those together.
    """
    execution_started: float | None = None
    while True:
        raw_message = ws.recv()
        if not isinstance(raw_message, str):
            continue
        message = json.loads(raw_message)
        message_type = message.get("type")
        data = message.get("data") or {}
        if data.get("prompt_id") != prompt_id:
            continue
        now = clock()
        if message_type in {"execution_error", "execution_interrupted"}:
            error_type = str(data.get("exception_type") or message_type)
            error_message = str(data.get("exception_message") or "ComfyUI stopped the prompt")
            raise RuntimeError(
                f"ComfyUI prompt {prompt_id} failed ({error_type}): {error_message}"
            )
        if message_type == "execution_start" and execution_started is None:
            execution_started = now
            continue
        if message_type == "executing":
            if data.get("node") is not None:
                if execution_started is None:
                    execution_started = now
                continue
            finished_at = now
            if execution_started is None:
                execution_started = finished_at
            return {
                "queue_wait_seconds": max(0.0, execution_started - queued_at),
                "execution_seconds": max(0.0, finished_at - execution_started),
            }
