#!/usr/bin/env python3
"""Dependency-light OpenAI-compatible HTTP server backed by Tabbit."""

from __future__ import annotations

import argparse
import hmac
import json
import os
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

from tabbit_client import TabbitClient, build_chat_body


class APIError(Exception):
    def __init__(self, message: str, status: int = 400,
                 error_type: str = "invalid_request_error") -> None:
        super().__init__(message)
        self.message = message
        self.status = status
        self.error_type = error_type


def _error_body(message: str, error_type: str = "invalid_request_error") -> dict[str, Any]:
    return {"error": {
        "message": message,
        "type": error_type,
        "param": None,
        "code": None,
    }}


def _content_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        raise APIError("message content must be a string or an array of text parts")
    pieces: list[str] = []
    for part in content:
        if not isinstance(part, dict):
            raise APIError("each message content part must be an object")
        kind = part.get("type")
        if kind in ("text", "input_text"):
            pieces.append(str(part.get("text", "")))
        else:
            raise APIError(
                f"Message content type {kind!r} is not supported; use text only."
            )
    return "\n".join(pieces)


def _flatten_messages(messages: Any) -> str:
    if not isinstance(messages, list) or not messages:
        raise APIError("messages must contain at least one message")
    parsed: list[tuple[str, str]] = []
    for message in messages:
        if not isinstance(message, dict) or not isinstance(message.get("role"), str):
            raise APIError("each message must contain a string role")
        role = message["role"]
        if role not in ("system", "user", "assistant"):
            raise APIError(f"message role {role!r} is not supported")
        parsed.append((role, _content_text(message.get("content"))))
    if len(parsed) == 1 and parsed[0][0] == "user":
        return parsed[0][1]
    labels = {"system": "System", "user": "User", "assistant": "Assistant"}
    turns = [f"{labels[role]}: {content}" for role, content in parsed]
    turns.append("Assistant:")
    return "\n\n".join(turns)


def _usage(payload: Any) -> dict[str, int] | None:
    if not isinstance(payload, dict) or not isinstance(payload.get("usage"), dict):
        return None
    raw = payload["usage"]
    prompt = int(raw.get("prompt_tokens", raw.get("input_tokens", 0)) or 0)
    completion = int(raw.get("completion_tokens", raw.get("output_tokens", 0)) or 0)
    return {
        "prompt_tokens": prompt,
        "completion_tokens": completion,
        "total_tokens": int(raw.get("total_tokens", prompt + completion) or 0),
    }


def _new_id() -> str:
    return "chatcmpl-" + uuid.uuid4().hex


def _sse(data: dict[str, Any] | str) -> bytes:
    payload = data if isinstance(data, str) else json.dumps(
        data, ensure_ascii=False, separators=(",", ":"))
    return f"data: {payload}\n\n".encode("utf-8")


class OpenAIHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TabbitOpenAI/1.0"
    max_body_bytes = 10 * 1024 * 1024

    def _cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _send_json(self, status: int, body: dict[str, Any]) -> None:
        data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(data)

    def _send_api_error(self, error: APIError) -> None:
        self._send_json(error.status, _error_body(error.message, error.error_type))

    def _authorized(self) -> bool:
        expected = os.environ.get("TABBIT_SERVER_API_KEY")
        if not expected:
            return True
        supplied = self.headers.get("Authorization", "")
        valid = hmac.compare_digest(supplied, f"Bearer {expected}")
        if not valid:
            self._send_api_error(APIError("Invalid API key", 401))
        return valid

    def _read_json(self) -> dict[str, Any]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise APIError("Content-Length is required", 411)
        try:
            length = int(raw_length)
        except ValueError:
            raise APIError("Invalid Content-Length") from None
        if length < 0 or length > self.max_body_bytes:
            raise APIError("Request body is too large", 413)
        try:
            value = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise APIError("Request body must be valid JSON") from None
        if not isinstance(value, dict):
            raise APIError("Request body must be a JSON object")
        return value

    def _start_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Transfer-Encoding", "chunked")
        self._cors_headers()
        self.end_headers()

    def _write_chunk(self, data: bytes) -> None:
        self.wfile.write(f"{len(data):X}\r\n".encode("ascii"))
        self.wfile.write(data)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _finish_chunks(self) -> None:
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self._cors_headers()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path.rstrip("/") or "/"
        if path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        if path != "/v1/models":
            self._send_api_error(APIError("Not found", 404, "invalid_request_error"))
            return
        if not self._authorized():
            return
        try:
            result = TabbitClient.from_config().get_models()
            models = result.get("models", result.get("data", []))
            now = int(time.time())
            data = []
            for model in models:
                model_id = model.get("display_name") or model.get("name") or model.get("id")
                if model_id:
                    data.append({
                        "id": model_id,
                        "object": "model",
                        "created": now,
                        "owned_by": "tabbit",
                    })
            self._send_json(200, {"object": "list", "data": data})
        except APIError as exc:
            self._send_api_error(exc)
        except (SystemExit, Exception) as exc:
            self._send_api_error(APIError(str(exc), 502, "upstream_error"))

    def do_POST(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path.rstrip("/")
        if path != "/v1/chat/completions":
            self._send_api_error(APIError("Not found", 404, "invalid_request_error"))
            return
        if not self._authorized():
            return
        try:
            request = self._read_json()
            if request.get("n", 1) != 1:
                raise APIError("Only n=1 is supported")

            model = request.get("model", "Default")
            if not isinstance(model, str) or not model:
                raise APIError("model must be a non-empty string")
            prompt = _flatten_messages(request.get("messages"))
            if request.get("stream", False):
                self._stream_chat(request, model, prompt)
            else:
                self._complete_chat(model, prompt)
        except APIError as exc:
            self._send_api_error(exc)
        except (SystemExit, Exception) as exc:
            self._send_api_error(APIError(str(exc), 502, "upstream_error"))

    def _complete_chat(self, model: str, prompt: str) -> None:
        content: list[str] = []
        usage = None
        body = build_chat_body(text=prompt, model=model)
        for event, payload in TabbitClient.from_config().chat_completion(body):
            if event == "message_chunk" and isinstance(payload, dict):
                content.append(str(payload.get("content", "")))
            elif event == "error":
                message = payload.get("message", "Tabbit upstream error") if isinstance(payload, dict) else str(payload)
                raise APIError(message, 502, "upstream_error")
            elif event == "finish":
                usage = _usage(payload)
        self._send_json(200, {
            "id": _new_id(),
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "".join(content)},
                "finish_reason": "stop",
            }],
            "usage": usage or {
                "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0,
            },
        })

    def _stream_chat(self, request: dict[str, Any], model: str, prompt: str) -> None:
        completion_id = _new_id()
        created = int(time.time())
        base = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
        }
        self._start_sse()
        try:
            body = build_chat_body(text=prompt, model=model)
            client = TabbitClient.from_config()
            self._write_chunk(_sse({**base, "choices": [{
                "index": 0,
                "delta": {"role": "assistant", "content": ""},
                "finish_reason": None,
            }]}))
            usage = None
            for event, payload in client.chat_completion(body):
                if event == "message_chunk" and isinstance(payload, dict):
                    content = payload.get("content")
                    if content:
                        self._write_chunk(_sse({**base, "choices": [{
                            "index": 0,
                            "delta": {"content": content},
                            "finish_reason": None,
                        }]}))
                elif event == "error":
                    message = payload.get("message", "Tabbit upstream error") if isinstance(payload, dict) else str(payload)
                    self._write_chunk(_sse(_error_body(message, "upstream_error")))
                    self._write_chunk(_sse("[DONE]"))
                    self._finish_chunks()
                    return
                elif event == "finish":
                    usage = _usage(payload)
            final: dict[str, Any] = {**base, "choices": [{
                "index": 0, "delta": {}, "finish_reason": "stop",
            }]}
            options = request.get("stream_options")
            if isinstance(options, dict) and options.get("include_usage"):
                final["usage"] = usage or {
                    "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0,
                }
            self._write_chunk(_sse(final))
            self._write_chunk(_sse("[DONE]"))
            self._finish_chunks()
        except (BrokenPipeError, ConnectionResetError):
            return
        except (SystemExit, Exception) as exc:
            try:
                self._write_chunk(_sse(_error_body(str(exc), "upstream_error")))
                self._write_chunk(_sse("[DONE]"))
                self._finish_chunks()
            except (BrokenPipeError, ConnectionResetError):
                pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), OpenAIHandler)
    print(f"Tabbit OpenAI-compatible API listening on http://{args.host}:{args.port}/v1")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()