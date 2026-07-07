from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from threading import Lock
from typing import Any

from fastapi import Request
from fastapi.responses import Response

import mlx_vlm.server as base


BACKEND_NAME = f"mlx_vlm/{base.__version__}"
TRACKED_PATHS = {
    "/chat/completions",
    "/v1/chat/completions",
    "/responses",
    "/v1/responses",
}


@dataclass
class RequestObservation:
    endpoint: str
    model: str | None
    stream: bool
    image_count: int
    audio_count: int
    structured_output: bool
    thinking_enabled: bool
    start_time: float
    first_token_at: float | None = None


@dataclass
class ModelAggregate:
    model: str
    requests_started: int = 0
    requests_completed: int = 0
    requests_failed: int = 0
    streaming_requests: int = 0
    prompt_tokens_total: int = 0
    completion_tokens_total: int = 0
    generated_tokens_total: int = 0
    request_time_total_seconds: float = 0.0
    decode_time_total_seconds: float = 0.0
    last_request_at: float | None = None

    def to_dict(self) -> dict[str, Any]:
        avg_request_tok_s = (
            self.completion_tokens_total / self.request_time_total_seconds
            if self.request_time_total_seconds > 0
            else 0.0
        )
        avg_decode_tok_s = (
            self.generated_tokens_total / self.decode_time_total_seconds
            if self.decode_time_total_seconds > 0
            else 0.0
        )
        return {
            "model": self.model,
            "requests_started": self.requests_started,
            "requests_completed": self.requests_completed,
            "requests_failed": self.requests_failed,
            "streaming_requests": self.streaming_requests,
            "prompt_tokens_total": self.prompt_tokens_total,
            "completion_tokens_total": self.completion_tokens_total,
            "generated_tokens_total": self.generated_tokens_total,
            "avg_request_time_s": (
                self.request_time_total_seconds / self.requests_completed
                if self.requests_completed > 0
                else 0.0
            ),
            "avg_request_tok_s": avg_request_tok_s,
            "avg_decode_tok_s": avg_decode_tok_s,
            "last_request_at": self.last_request_at,
        }


class MetricsTracker:
    def __init__(self) -> None:
        self._lock = Lock()
        self.started_at = time.time()
        self.requests_started = 0
        self.requests_completed = 0
        self.requests_failed = 0
        self.streaming_requests = 0
        self.in_flight = 0
        self.prompt_tokens_total = 0
        self.completion_tokens_total = 0
        self.generated_tokens_total = 0
        self.request_time_total_seconds = 0.0
        self.decode_time_total_seconds = 0.0
        self.last_request_at: float | None = None
        self.latest_request: dict[str, Any] | None = None
        self.models: dict[str, ModelAggregate] = {}

    def record_started(self, observation: RequestObservation) -> None:
        with self._lock:
            self.requests_started += 1
            self.in_flight += 1
            if observation.stream:
                self.streaming_requests += 1
            model_key = observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_started += 1
            if observation.stream:
                aggregate.streaming_requests += 1

    def record_failed(self, observation: RequestObservation) -> None:
        with self._lock:
            self.requests_failed += 1
            self.in_flight = max(0, self.in_flight - 1)
            model_key = observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_failed += 1
            aggregate.last_request_at = time.time()

    def record_completed(
        self,
        observation: RequestObservation,
        completion: dict[str, Any],
    ) -> None:
        completed_at = time.time()
        prompt_tokens = int(completion.get("prompt_tokens") or 0)
        completion_tokens = int(completion.get("completion_tokens") or 0)
        generated_tokens = int(completion.get("generated_tokens") or completion_tokens)
        elapsed = float(completion.get("request_elapsed_s") or 0.0)
        decode_tps = float(completion.get("decode_tok_s") or 0.0)
        decode_time = (
            generated_tokens / decode_tps if generated_tokens > 0 and decode_tps > 0 else elapsed
        )
        request_tok_s = completion.get("request_tok_s")
        if request_tok_s is None and elapsed > 0 and completion_tokens > 0:
            request_tok_s = completion_tokens / elapsed

        latest = {
            "timestamp_unix": completed_at,
            "endpoint": observation.endpoint,
            "model": completion.get("model") or observation.model,
            "stream": observation.stream,
            "backend": BACKEND_NAME,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "generated_tokens": generated_tokens,
            "reasoning_tokens": 0,
            "total_tokens": prompt_tokens + generated_tokens,
            "prompt_eval_time_s": completion.get("prompt_eval_time_s"),
            "prefill_tok_s": completion.get("prefill_tok_s"),
            "ttft_s": completion.get("ttft_s"),
            "decode_elapsed_s": decode_time if decode_time > 0 else None,
            "request_elapsed_s": elapsed if elapsed > 0 else None,
            "request_tok_s": request_tok_s,
            "decode_tok_s": completion.get("decode_tok_s"),
            "peak_memory_gb": completion.get("peak_memory_gb"),
            "finish_reason": completion.get("finish_reason"),
            "image_count": observation.image_count,
            "audio_count": observation.audio_count,
            "structured_output": observation.structured_output,
            "thinking_enabled": observation.thinking_enabled,
            "tool_parser": current_tool_parser(),
            "tool_calls": bool(completion.get("tool_calls")),
            "apc_enabled": base.apc_manager is not None,
        }

        with self._lock:
            self.requests_completed += 1
            self.in_flight = max(0, self.in_flight - 1)
            self.prompt_tokens_total += prompt_tokens
            self.completion_tokens_total += completion_tokens
            self.generated_tokens_total += generated_tokens
            self.request_time_total_seconds += elapsed
            self.decode_time_total_seconds += max(0.0, decode_time)
            self.last_request_at = completed_at
            self.latest_request = latest

            model_key = latest["model"] or observation.model or "Unknown"
            aggregate = self.models.setdefault(model_key, ModelAggregate(model=model_key))
            aggregate.requests_completed += 1
            aggregate.prompt_tokens_total += prompt_tokens
            aggregate.completion_tokens_total += completion_tokens
            aggregate.generated_tokens_total += generated_tokens
            aggregate.request_time_total_seconds += elapsed
            aggregate.decode_time_total_seconds += max(0.0, decode_time)
            aggregate.last_request_at = completed_at

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            avg_request_time = (
                self.request_time_total_seconds / self.requests_completed
                if self.requests_completed > 0
                else 0.0
            )
            avg_request_tok_s = (
                self.completion_tokens_total / self.request_time_total_seconds
                if self.request_time_total_seconds > 0
                else 0.0
            )
            avg_decode_tok_s = (
                self.generated_tokens_total / self.decode_time_total_seconds
                if self.decode_time_total_seconds > 0
                else 0.0
            )
            return {
                "latest": self.latest_request,
                "summary": {
                    "uptime_s": max(0.0, time.time() - self.started_at),
                    "requests_started": self.requests_started,
                    "requests_completed": self.requests_completed,
                    "requests_failed": self.requests_failed,
                    "streaming_requests": self.streaming_requests,
                    "in_flight": self.in_flight,
                    "prompt_tokens_total": self.prompt_tokens_total,
                    "completion_tokens_total": self.completion_tokens_total,
                    "generated_tokens_total": self.generated_tokens_total,
                    "avg_request_time_s": avg_request_time,
                    "avg_request_tok_s": avg_request_tok_s,
                    "avg_decode_tok_s": avg_decode_tok_s,
                    "last_request_at": self.last_request_at,
                },
                "server": current_runtime_snapshot(),
                "models": [
                    aggregate.to_dict()
                    for aggregate in sorted(
                        self.models.values(),
                        key=lambda item: (item.last_request_at or 0.0, item.model),
                        reverse=True,
                    )
                ],
            }


TRACKER = MetricsTracker()


def iter_message_media(messages: list[Any]) -> tuple[int, int]:
    image_count = 0
    audio_count = 0
    for message in messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type in {"image_url", "input_image"}:
                image_count += 1
            elif item_type == "input_audio":
                audio_count += 1
    return image_count, audio_count


def parse_request_observation(request: Request, payload: dict[str, Any]) -> RequestObservation:
    image_count = 0
    audio_count = 0
    if request.url.path.endswith("chat/completions"):
        image_count, audio_count = iter_message_media(payload.get("messages") or [])
    elif request.url.path.endswith("responses"):
        input_items = payload.get("input")
        if isinstance(input_items, list):
            image_count, audio_count = iter_message_media(input_items)

    return RequestObservation(
        endpoint=request.url.path.lstrip("/"),
        model=payload.get("model"),
        stream=bool(payload.get("stream")),
        image_count=image_count,
        audio_count=audio_count,
        structured_output=payload.get("response_format") is not None or payload.get("text") is not None,
        thinking_enabled=payload.get("enable_thinking")
        if isinstance(payload.get("enable_thinking"), bool)
        else base.get_server_enable_thinking(),
        start_time=time.perf_counter(),
    )


def current_tool_parser() -> str | None:
    processor = base.model_cache.get("processor") if isinstance(base.model_cache, dict) else None
    if processor is None:
        return None
    try:
        return base._infer_tool_parser_from_processor(processor)
    except Exception:
        return None


def current_runtime_snapshot() -> dict[str, Any]:
    config = base.model_cache.get("config") if isinstance(base.model_cache, dict) else None
    text_config = getattr(config, "text_config", None)
    loaded_context_size = getattr(text_config, "max_position_embeddings", None)

    queue_depth = 0
    requests_queue = getattr(getattr(base, "response_generator", None), "requests", None)
    if requests_queue is not None:
        try:
            queue_depth = requests_queue.qsize()
        except Exception:
            queue_depth = 0

    if base.apc_manager is not None:
        apc_snapshot = dict(base.apc_manager.stats_snapshot())
        apc_snapshot["enabled"] = True
    else:
        apc_snapshot = {"enabled": False}

    return {
        "loaded_model": base.model_cache.get("model_path") if isinstance(base.model_cache, dict) else None,
        "loaded_adapter": base.model_cache.get("adapter_path") if isinstance(base.model_cache, dict) else None,
        "loaded_context_size": loaded_context_size,
        "configured_context_limit": loaded_context_size,
        "effective_context_limit": loaded_context_size,
        "loaded_tool_parser": current_tool_parser(),
        "continuous_batching_enabled": getattr(base, "response_generator", None) is not None,
        "request_queue_depth": queue_depth,
        "apc": apc_snapshot,
    }


class StreamAccumulator:
    def __init__(self, observation: RequestObservation, kind: str) -> None:
        self.observation = observation
        self.kind = kind
        self.model = observation.model
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.generated_tokens = 0
        self.prefill_tok_s: float | None = None
        self.decode_tok_s: float | None = None
        self.peak_memory_gb: float | None = None
        self.finish_reason: str | None = None
        self.tool_calls = False

    def feed(self, block: str) -> None:
        lines = [line for line in block.splitlines() if line]
        if not lines:
            return

        event_name = None
        data_parts: list[str] = []
        for line in lines:
            if line.startswith("event:"):
                event_name = line.partition(":")[2].strip()
            elif line.startswith("data:"):
                data_parts.append(line.partition(":")[2].lstrip())

        if not data_parts:
            return

        data_text = "\n".join(data_parts)
        if data_text == "[DONE]":
            return

        try:
            payload = json.loads(data_text)
        except json.JSONDecodeError:
            return

        if self.kind == "chat":
            self._consume_chat_chunk(payload)
        else:
            self._consume_responses_event(event_name, payload)

    def _consume_chat_chunk(self, payload: dict[str, Any]) -> None:
        self.model = payload.get("model") or self.model
        usage = payload.get("usage") or {}
        self.prompt_tokens = int(usage.get("prompt_tokens") or self.prompt_tokens)
        self.completion_tokens = int(usage.get("completion_tokens") or self.completion_tokens)
        self.generated_tokens = int(usage.get("completion_tokens") or self.generated_tokens)
        if usage.get("prompt_tps") is not None:
            self.prefill_tok_s = float(usage["prompt_tps"])
        if usage.get("generation_tps") is not None:
            self.decode_tok_s = float(usage["generation_tps"])
        if usage.get("peak_memory") is not None:
            self.peak_memory_gb = float(usage["peak_memory"])

        choices = payload.get("choices") or []
        if not choices:
            return

        choice = choices[0] or {}
        if choice.get("finish_reason"):
            self.finish_reason = choice["finish_reason"]
        delta = choice.get("delta") or {}
        if delta.get("tool_calls"):
            self.tool_calls = True
        if self.observation.first_token_at is None:
            content = delta.get("content")
            reasoning = delta.get("reasoning")
            if (isinstance(content, str) and content) or (isinstance(reasoning, str) and reasoning):
                self.observation.first_token_at = time.perf_counter()

    def _consume_responses_event(self, event_name: str | None, payload: dict[str, Any]) -> None:
        if event_name == "response.output_text.delta" and payload.get("delta"):
            if self.observation.first_token_at is None:
                self.observation.first_token_at = time.perf_counter()
            return

        if event_name != "response.completed":
            return

        response = payload.get("response") or {}
        self.model = response.get("model") or self.model
        usage = response.get("usage") or {}
        self.prompt_tokens = int(usage.get("input_tokens") or self.prompt_tokens)
        self.completion_tokens = int(usage.get("output_tokens") or self.completion_tokens)
        self.generated_tokens = int(usage.get("output_tokens") or self.generated_tokens)

    def finalize(self) -> dict[str, Any]:
        elapsed = max(0.0, time.perf_counter() - self.observation.start_time)
        prompt_eval_time = None
        if self.prefill_tok_s and self.prefill_tok_s > 0 and self.prompt_tokens > 0:
            prompt_eval_time = self.prompt_tokens / self.prefill_tok_s

        return {
            "model": self.model,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "generated_tokens": self.generated_tokens or self.completion_tokens,
            "request_elapsed_s": elapsed,
            "request_tok_s": (
                self.completion_tokens / elapsed if elapsed > 0 and self.completion_tokens > 0 else None
            ),
            "decode_tok_s": self.decode_tok_s,
            "prompt_eval_time_s": prompt_eval_time,
            "prefill_tok_s": self.prefill_tok_s,
            "ttft_s": (
                max(0.0, self.observation.first_token_at - self.observation.start_time)
                if self.observation.first_token_at is not None
                else None
            ),
            "peak_memory_gb": self.peak_memory_gb,
            "finish_reason": self.finish_reason,
            "tool_calls": self.tool_calls or self.finish_reason == "tool_calls",
        }


def parse_chat_response(body: bytes, observation: RequestObservation) -> dict[str, Any]:
    payload = json.loads(body.decode("utf-8"))
    usage = payload.get("usage") or {}
    choices = payload.get("choices") or []
    choice = choices[0] if choices else {}
    elapsed = max(0.0, time.perf_counter() - observation.start_time)
    prompt_tokens = int(usage.get("prompt_tokens") or 0)
    completion_tokens = int(usage.get("completion_tokens") or 0)
    prompt_tps = usage.get("prompt_tps")
    generation_tps = usage.get("generation_tps")
    prompt_eval_time = (
        prompt_tokens / float(prompt_tps)
        if prompt_tps and float(prompt_tps) > 0 and prompt_tokens > 0
        else None
    )
    return {
        "model": payload.get("model") or observation.model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "generated_tokens": int(usage.get("completion_tokens") or completion_tokens),
        "request_elapsed_s": elapsed,
        "request_tok_s": (
            completion_tokens / elapsed if elapsed > 0 and completion_tokens > 0 else None
        ),
        "decode_tok_s": float(generation_tps) if generation_tps is not None else None,
        "prompt_eval_time_s": prompt_eval_time,
        "prefill_tok_s": float(prompt_tps) if prompt_tps is not None else None,
        "ttft_s": None,
        "peak_memory_gb": float(usage["peak_memory"]) if usage.get("peak_memory") is not None else None,
        "finish_reason": choice.get("finish_reason"),
        "tool_calls": (
            choice.get("finish_reason") == "tool_calls"
            or bool((choice.get("message") or {}).get("tool_calls"))
        ),
    }


def parse_responses_body(body: bytes, observation: RequestObservation) -> dict[str, Any]:
    payload = json.loads(body.decode("utf-8"))
    usage = payload.get("usage") or {}
    elapsed = max(0.0, time.perf_counter() - observation.start_time)
    prompt_tokens = int(usage.get("input_tokens") or 0)
    completion_tokens = int(usage.get("output_tokens") or 0)
    return {
        "model": payload.get("model") or observation.model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "generated_tokens": completion_tokens,
        "request_elapsed_s": elapsed,
        "request_tok_s": (
            completion_tokens / elapsed if elapsed > 0 and completion_tokens > 0 else None
        ),
        "decode_tok_s": (
            completion_tokens / elapsed if elapsed > 0 and completion_tokens > 0 else None
        ),
        "prompt_eval_time_s": None,
        "prefill_tok_s": None,
        "ttft_s": None,
        "peak_memory_gb": None,
        "finish_reason": "stop",
        "tool_calls": False,
    }


async def materialize_response(response: Any) -> tuple[Any, bytes]:
    response_body = bytes(getattr(response, "body", b"") or b"")
    if response_body or not hasattr(response, "body_iterator"):
        return response, response_body

    chunks: list[bytes] = []
    async for chunk in response.body_iterator:
        if isinstance(chunk, bytes):
            chunks.append(chunk)
        elif isinstance(chunk, bytearray):
            chunks.append(bytes(chunk))
        else:
            chunks.append(str(chunk).encode("utf-8"))

    response_body = b"".join(chunks)
    rebuilt = Response(
        content=response_body,
        status_code=response.status_code,
        headers=dict(response.headers),
        media_type=getattr(response, "media_type", None),
        background=getattr(response, "background", None),
    )
    return rebuilt, response_body


def install_metrics_overlay() -> None:
    if getattr(base.app.state, "mlx_platform_metrics_installed", False):
        return
    base.app.state.mlx_platform_metrics_installed = True

    @base.app.middleware("http")
    async def metrics_middleware(request: Request, call_next):
        if request.url.path not in TRACKED_PATHS:
            return await call_next(request)

        body = await request.body()
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
        except json.JSONDecodeError:
            payload = {}
        observation = parse_request_observation(request, payload)
        TRACKER.record_started(observation)

        try:
            response = await call_next(request)
        except Exception:
            TRACKER.record_failed(observation)
            raise

        if response.status_code >= 400:
            TRACKER.record_failed(observation)
            return response

        content_type = response.headers.get("content-type", "")
        if "text/event-stream" in content_type and hasattr(response, "body_iterator"):
            accumulator = StreamAccumulator(
                observation,
                "chat" if request.url.path.endswith("chat/completions") else "responses",
            )
            original_iterator = response.body_iterator

            async def wrapped_iterator():
                buffer = ""
                try:
                    async for chunk in original_iterator:
                        text = (
                            chunk.decode("utf-8", errors="replace")
                            if isinstance(chunk, (bytes, bytearray))
                            else str(chunk)
                        )
                        buffer += text
                        while "\n\n" in buffer:
                            block, buffer = buffer.split("\n\n", 1)
                            try:
                                accumulator.feed(block)
                            except Exception as error:
                                base.logger.warning("metrics stream instrumentation failed: %s", error)
                        yield chunk
                    if buffer.strip():
                        try:
                            accumulator.feed(buffer)
                        except Exception as error:
                            base.logger.warning("metrics stream instrumentation failed: %s", error)
                    try:
                        TRACKER.record_completed(observation, accumulator.finalize())
                    except Exception as error:
                        base.logger.warning("metrics completion instrumentation failed: %s", error)
                except Exception:
                    TRACKER.record_failed(observation)
                    raise

            response.body_iterator = wrapped_iterator()
            return response

        try:
            response, response_body = await materialize_response(response)
            if request.url.path.endswith("chat/completions"):
                completion = parse_chat_response(response_body, observation)
            else:
                completion = parse_responses_body(response_body, observation)
            TRACKER.record_completed(observation, completion)
        except Exception as error:
            base.logger.warning("metrics instrumentation failed for %s: %s", request.url.path, error)

        return response

    @base.app.get("/metrics")
    @base.app.get("/v1/metrics", include_in_schema=False)
    async def metrics_endpoint():
        return TRACKER.snapshot()


def main() -> None:
    install_metrics_overlay()
    base.main()


install_metrics_overlay()


if __name__ == "__main__":
    main()
