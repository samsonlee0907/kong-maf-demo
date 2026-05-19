"""
FastAPI host for the Kong + MAF demo.

Endpoints:
  GET  /health
  GET  /portal
  GET  /ui/config
  GET  /ui/logs/{trace_id}
  POST /invoke  - synchronous JSON response
  POST /stream  - server-sent event response

The agent is backed by Microsoft Foundry through a project endpoint rather than
an Azure OpenAI resource endpoint.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from collections import defaultdict, deque
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any, AsyncGenerator

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from sse_starlette.sse import EventSourceResponse

from maf_agent import create_agent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("kong-maf-demo")

PORTAL_FILE = Path(__file__).with_name("demo_portal.html")
LOCAL_GATEWAY_URL = os.getenv("KONG_GATEWAY_URL", "http://127.0.0.1:8000")
AZURE_GATEWAY_URL = os.getenv(
    "AZURE_KONG_GATEWAY_URL",
    "",
).strip()
AZURE_HOSTED_AGENT_NAME = os.getenv("AZURE_HOSTED_AGENT_NAME", "kong-maf-hosted-agent").strip()
DEFAULT_GATEWAY_PROFILE = os.getenv(
    "DEFAULT_GATEWAY_PROFILE",
    "local-maf",
).strip()
FOUNDRY_MODEL = os.getenv("FOUNDRY_MODEL", "gpt-5.4-mini")

app = FastAPI(
    title="Kong + MAF Demo Agent Server",
    description="Microsoft Agent Framework demo server with sync and streaming endpoints.",
    version="1.0.0",
)


class TraceHub:
    def __init__(self, max_history: int = 256) -> None:
        self._history: dict[str, deque[dict[str, Any]]] = defaultdict(
            lambda: deque(maxlen=max_history)
        )
        self._subscribers: dict[str, list[asyncio.Queue[dict[str, Any]]]] = defaultdict(list)
        self._sequence: dict[str, int] = defaultdict(int)
        self._lock = asyncio.Lock()

    async def publish(self, trace_id: str, event: dict[str, Any]) -> dict[str, Any]:
        if not trace_id:
            return event

        async with self._lock:
            self._sequence[trace_id] += 1
            event["index"] = self._sequence[trace_id]
            self._history[trace_id].append(event)
            subscribers = list(self._subscribers.get(trace_id, []))

        for queue in subscribers:
            await queue.put(event)

        return event

    async def subscribe(
        self, trace_id: str
    ) -> tuple[asyncio.Queue[dict[str, Any]], list[dict[str, Any]]]:
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        async with self._lock:
            self._subscribers[trace_id].append(queue)
            history = list(self._history.get(trace_id, []))

        return queue, history

    async def unsubscribe(self, trace_id: str, queue: asyncio.Queue[dict[str, Any]]) -> None:
        async with self._lock:
            subscribers = self._subscribers.get(trace_id)
            if not subscribers:
                return

            if queue in subscribers:
                subscribers.remove(queue)

            if not subscribers:
                self._subscribers.pop(trace_id, None)

    async def snapshot(self, trace_id: str) -> list[dict[str, Any]]:
        async with self._lock:
            return list(self._history.get(trace_id, []))


trace_hub = TraceHub()


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, description="The user message to send to the agent.")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _make_trace_id() -> str:
    return f"trace-{uuid.uuid4().hex[:12]}"


def _extract_trace_id(request: Request) -> str:
    incoming = request.headers.get("x-trace-id", "").strip()
    return incoming or _make_trace_id()


def _trim_text(value: str, limit: int = 160) -> str:
    compact = " ".join(value.split())
    if len(compact) <= limit:
        return compact
    return f"{compact[: limit - 3]}..."


def _stringify_content(item: Any) -> str:
    if item is None:
        return ""

    text = getattr(item, "text", None)
    if isinstance(text, str) and text:
        return text

    contents = getattr(item, "contents", None)
    if contents:
        parts: list[str] = []
        for content in contents:
            content_text = getattr(content, "text", None)
            if isinstance(content_text, str) and content_text:
                parts.append(content_text)
            elif isinstance(content, dict):
                dict_text = content.get("text")
                if isinstance(dict_text, str) and dict_text:
                    parts.append(dict_text)
        if parts:
            return "".join(parts)

    return str(item)


async def _publish_trace(
    trace_id: str,
    *,
    source: str,
    target: str,
    hop: str,
    message: str,
    detail: dict[str, Any] | None = None,
    level: str = "info",
) -> None:
    event = {
        "trace_id": trace_id,
        "ts": _utc_now(),
        "level": level,
        "source": source,
        "target": target,
        "hop": hop,
        "message": message,
        "detail": detail or {},
    }
    await trace_hub.publish(trace_id, event)


@lru_cache
def get_agent():
    return create_agent()


@app.get("/", include_in_schema=False)
async def portal_root() -> FileResponse:
    return FileResponse(PORTAL_FILE)


@app.get("/portal", include_in_schema=False)
async def portal_page() -> FileResponse:
    return FileResponse(PORTAL_FILE)


@app.get("/ui/config")
async def ui_config(request: Request) -> JSONResponse:
    served_from = str(request.base_url).rstrip("/")
    request_port = request.url.port
    direct_preview_mode = request_port not in (80, 443, 8000)
    local_preview_url = served_from if direct_preview_mode else LOCAL_GATEWAY_URL
    use_azure_profile = DEFAULT_GATEWAY_PROFILE == "azure-hosted" and bool(AZURE_GATEWAY_URL)
    default_gateway_url = AZURE_GATEWAY_URL if use_azure_profile else local_preview_url

    try:
        local_agent_name = get_agent().name
        status = "ok"
    except RuntimeError as exc:
        logger.exception("Agent configuration error during UI config fetch")
        local_agent_name = "agent_unavailable"
        status = str(exc)

    return JSONResponse(
        content={
            "agentName": AZURE_HOSTED_AGENT_NAME if use_azure_profile else local_agent_name,
            "localAgentName": local_agent_name,
            "azureHostedAgentName": AZURE_HOSTED_AGENT_NAME,
            "defaultGatewayUrl": default_gateway_url,
            "defaultGatewayProfile": "azure-hosted" if use_azure_profile else "local-maf",
            "localGatewayUrl": local_preview_url,
            "azureGatewayUrl": AZURE_GATEWAY_URL,
            "servedFrom": served_from,
            "traceHeader": "X-Trace-Id",
            "foundryModel": FOUNDRY_MODEL,
            "status": status,
            "portalMode": "direct-preview" if direct_preview_mode else "gateway",
            "kongGatewayUrl": LOCAL_GATEWAY_URL,
        }
    )


@app.get("/ui/logs/{trace_id}/snapshot")
async def trace_snapshot(trace_id: str) -> JSONResponse:
    return JSONResponse(content={"traceId": trace_id, "events": await trace_hub.snapshot(trace_id)})


async def _trace_event_stream(
    request: Request, trace_id: str
) -> AsyncGenerator[dict[str, str], None]:
    queue, history = await trace_hub.subscribe(trace_id)
    try:
        yield {
            "event": "ready",
            "data": json.dumps({"trace_id": trace_id, "replayed_events": len(history)}),
        }
        for event in history:
            yield {"event": "trace", "data": json.dumps(event)}

        while True:
            if await request.is_disconnected():
                break

            try:
                event = await asyncio.wait_for(queue.get(), timeout=15)
            except asyncio.TimeoutError:
                continue

            yield {"event": "trace", "data": json.dumps(event)}
    finally:
        await trace_hub.unsubscribe(trace_id, queue)


@app.get("/ui/logs/{trace_id}")
async def ui_logs(request: Request, trace_id: str) -> EventSourceResponse:
    return EventSourceResponse(
        _trace_event_stream(request, trace_id),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
        ping=15,
    )


@app.get("/health")
async def health() -> JSONResponse:
    try:
        agent = get_agent()
    except RuntimeError as exc:
        logger.exception("Agent configuration error")
        return JSONResponse(
            status_code=500,
            content={"status": "error", "detail": str(exc)},
        )

    return JSONResponse(content={"status": "ok", "agent": agent.name})


@app.post("/invoke")
async def invoke(request: Request, req: ChatRequest) -> JSONResponse:
    trace_id = _extract_trace_id(request)

    await _publish_trace(
        trace_id,
        source="kong",
        target="maf",
        hop="gateway-to-maf",
        message="Kong forwarded POST /invoke to the MAF server.",
        detail={"path": "/invoke", "mode": "non-sse", "prompt": req.message},
    )

    try:
        agent = get_agent()
        logger.info("invoke request received: %s", req.message)
        await _publish_trace(
            trace_id,
            source="maf",
            target="foundry",
            hop="maf-to-foundry",
            message="MAF dispatched a non-streaming prompt to the Foundry project.",
            detail={"model": FOUNDRY_MODEL, "stream": False},
        )
        response = await agent.run(req.message)
        output = _stringify_content(response)
    except RuntimeError as exc:
        await _publish_trace(
            trace_id,
            source="maf",
            target="kong",
            hop="invoke-error",
            message="The MAF server failed before invoking Foundry.",
            detail={"error": str(exc)},
            level="error",
        )
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - demo server fallback
        logger.exception("invoke failed")
        await _publish_trace(
            trace_id,
            source="maf",
            target="kong",
            hop="invoke-error",
            message="The MAF server hit an error while handling /invoke.",
            detail={"error": str(exc)},
            level="error",
        )
        raise HTTPException(status_code=500, detail=f"Agent invocation failed: {exc}") from exc

    await _publish_trace(
        trace_id,
        source="foundry",
        target="maf",
        hop="foundry-to-maf",
        message="Foundry returned the full completion to the MAF agent.",
        detail={"characters": len(output), "preview": _trim_text(output)},
    )
    await _publish_trace(
        trace_id,
        source="maf",
        target="kong",
        hop="maf-to-kong",
        message="FastAPI returned the JSON payload back to Kong.",
        detail={"status_code": 200, "mode": "non-sse"},
    )

    return JSONResponse(
        content={
            "mode": "non-sse",
            "agent": agent.name,
            "input": req.message,
            "output": output,
        },
        headers={"X-Trace-Id": trace_id},
    )


async def stream_generator(
    request: Request, *, agent: Any, message: str, trace_id: str
) -> AsyncGenerator[dict[str, str], None]:
    token_count = 0
    full_text_parts: list[str] = []

    logger.info("stream request received: %s", message)
    await _publish_trace(
        trace_id,
        source="maf",
        target="foundry",
        hop="maf-to-foundry-stream",
        message="MAF opened a streaming request to the Foundry project.",
        detail={"model": FOUNDRY_MODEL, "stream": True},
    )

    try:
        async for update in agent.run(message, stream=True):
            if await request.is_disconnected():
                await _publish_trace(
                    trace_id,
                    source="kong",
                    target="maf",
                    hop="client-disconnect",
                    message="The downstream client disconnected before the stream finished.",
                    detail={"tokens_forwarded": token_count},
                    level="warning",
                )
                break

            chunk = _stringify_content(update)
            if not chunk:
                continue

            token_count += 1
            full_text_parts.append(chunk)
            chunk_detail = {
                "index": token_count,
                "chunk": chunk,
                "preview": _trim_text(chunk, limit=72),
            }
            await _publish_trace(
                trace_id,
                source="foundry",
                target="maf",
                hop="foundry-to-maf-stream",
                message="Foundry streamed a chunk into the MAF server.",
                detail=chunk_detail,
            )
            await _publish_trace(
                trace_id,
                source="maf",
                target="kong",
                hop="maf-to-kong-stream",
                message="FastAPI forwarded the chunk to Kong as SSE.",
                detail=chunk_detail,
            )

            yield {
                "event": "token",
                "data": json.dumps({"chunk": chunk, "index": token_count}),
            }
    except Exception as exc:  # pragma: no cover - demo streaming fallback
        logger.exception("stream failed")
        await _publish_trace(
            trace_id,
            source="maf",
            target="kong",
            hop="stream-error",
            message="The MAF server hit an error while streaming.",
            detail={"error": str(exc), "tokens_forwarded": token_count},
            level="error",
        )
        yield {
            "event": "error",
            "data": json.dumps({"status": "error", "detail": str(exc), "trace_id": trace_id}),
        }
        return

    full_text = "".join(full_text_parts)
    await _publish_trace(
        trace_id,
        source="maf",
        target="kong",
        hop="maf-to-kong-stream-complete",
        message="FastAPI closed the SSE response back to Kong.",
        detail={"total_tokens": token_count, "characters": len(full_text)},
    )
    yield {
        "event": "done",
        "data": json.dumps(
            {
                "status": "complete",
                "total_tokens": token_count,
                "full_text": full_text,
            }
        ),
    }


@app.post("/stream")
async def stream(request: Request, req: ChatRequest) -> EventSourceResponse:
    trace_id = _extract_trace_id(request)

    try:
        agent = get_agent()
    except RuntimeError as exc:
        await _publish_trace(
            trace_id,
            source="maf",
            target="kong",
            hop="stream-error",
            message="The MAF server is not configured correctly for streaming.",
            detail={"error": str(exc)},
            level="error",
        )
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    await _publish_trace(
        trace_id,
        source="kong",
        target="maf",
        hop="gateway-to-maf",
        message="Kong forwarded POST /stream to the MAF server.",
        detail={"path": "/stream", "mode": "sse", "prompt": req.message},
    )

    headers = {
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no",
        "X-Trace-Id": trace_id,
    }
    return EventSourceResponse(
        stream_generator(request, agent=agent, message=req.message, trace_id=trace_id),
        media_type="text/event-stream",
        headers=headers,
        ping=15,
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host="0.0.0.0",
        port=int(os.getenv("AGENT_PORT", "8080")),
        reload=True,
        log_level="info",
    )
