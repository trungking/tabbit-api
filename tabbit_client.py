#!/usr/bin/env python3
"""
Tabbit API client.

Calls the Tabbit AI backend directly (no app needed) once you provide a valid
session cookie obtained from a logged-in browser or the Tabbit desktop app.

Reverse-engineered from the Next.js PWA at https://web.tabbit.ai.
    - Endpoint:   POST {base}/api/v1/chat/completion  ->  text/event-stream
    - Sign:       hex(HMAC-SHA256(sign_key, "{ts}.{random}.{hex(SHA-256(body))}"))
    - Sign key:   GET /chat/sign-key  (rotates; default literal baked in JS)
    - Version:    x-req-ctx: base64("1.1.39(10101039)")  <- bypasses 493 gate
    - UUID:       unique-uuid header per request

Usage:
    python tabbit_client.py models
    python tabbit_client.py chat "Hello, who are you?"
    python tabbit_client.py chat -m GLM-5.2 "Explain quicksort"
    python tabbit_client.py probe           # sends empty body, prints server's
                                            # validation error so we can refine
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Iterator

# curl_cffi impersonates Chrome's TLS+HTTP/2 fingerprint, which Tabbit's
# server requires for premium_only models. Without it, even with valid
# cookies+signing, Opus/GPT-5.5/etc. return HTTP 492.
try:
    from curl_cffi import requests as _creq
    _REQUESTS_LIB = "curl_cffi"
except ImportError:  # graceful fallback — works for free models only
    import requests as _creq
    _REQUESTS_LIB = "requests"
requests = _creq  # type: ignore

DEFAULT_BASE = "https://web.tabbit.ai"
DEFAULT_SIGN_KEY = "f8d0e6a73f8d4b1a9c3d2e1f9a4b7c6d"  # literal in 7978-...js
# Must match the running Tabbit browser's version, else the server returns
# 493 "browser version outdated". Format: "X.Y.Z(buildnum)" base64-encoded.
TABBIT_VERSION = "1.1.39(10101039)"
X_REQ_CTX = base64.b64encode(TABBIT_VERSION.encode("utf-8")).decode("ascii")
CONFIG_PATH = Path(os.environ.get(
    "TABBIT_CONFIG",
    str(Path(__file__).with_name("tabbit_config.json"))))


# ---------------------------------------------------------------------------
# Signing (translates function y() / p() in 7978-28728a0635c9f673.js)
# ---------------------------------------------------------------------------

def _hex(b: bytes) -> str:
    return b.hex()


def _sign_headers(body_str: str, sign_key: str) -> dict[str, str]:
    """Build x-timestamp / x-nonce / x-signature for a given request body.

    Per chunk 7978-...js: `random = (0,a.l)()` where a.l is the UUID4
    generator in module 67174. So x-signature must be a UUID, not hex.
    """
    timestamp = str(int(time.time() * 1000))
    random_nonce = str(uuid.uuid4())                # (0,a.l)() in JS — UUID4
    body_hash = hashlib.sha256(body_str.encode("utf-8")).hexdigest()
    payload = f"{timestamp}.{random_nonce}.{body_hash}".encode("utf-8")
    nonce = hmac.new(sign_key.encode("utf-8"),
                     payload, hashlib.sha256).hexdigest()
    return {
        "x-timestamp": timestamp,
        "x-nonce": nonce,
        "x-signature": random_nonce,
    }


# ---------------------------------------------------------------------------
# SSE parsing (Server-Sent Events stream from /chat/send)
# ---------------------------------------------------------------------------

def iter_sse(response: Any) -> Iterator[tuple[str, dict | str]]:
    """Yield (event_type, parsed_payload) tuples from an SSE response stream.

    Works with both `requests` and `curl_cffi` responses.
    """
    event_type = ""
    data_buf: list[str] = []

    # Pick the right iteration primitive — curl_cffi uses iter_content,
    # plain requests supports iter_lines directly.
    if hasattr(response, "iter_lines") and _REQUESTS_LIB == "requests":
        line_iter = response.iter_lines(decode_unicode=True)
    else:
        # curl_cffi: stream raw bytes and split on newlines ourselves
        def _line_iter(resp: Any) -> Iterator[str]:
            buf = b""
            for chunk in resp.iter_content(chunk_size=4096):
                if not chunk:
                    continue
                if isinstance(chunk, str):
                    chunk = chunk.encode("utf-8")
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    yield line.decode("utf-8", errors="replace")
            if buf:
                yield buf.decode("utf-8", errors="replace")
        line_iter = _line_iter(response)

    for raw in line_iter:
        if raw is None:
            continue
        line = raw.rstrip("\r\n")
        if line == "":
            if data_buf:
                data_text = "\n".join(data_buf)
                try:
                    payload: Any = json.loads(data_text)
                except json.JSONDecodeError:
                    payload = data_text
                yield event_type or "message", payload
            event_type = ""
            data_buf = []
            continue
        if line.startswith(":"):
            continue
        if line.startswith("event:"):
            event_type = line[6:].strip()
        elif line.startswith("data:"):
            data_buf.append(line[5:].lstrip())
    if data_buf:
        data_text = "\n".join(data_buf)
        try:
            payload = json.loads(data_text)
        except json.JSONDecodeError:
            payload = data_text
        yield event_type or "message", payload


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

class TabbitClient:
    def __init__(self,
                 base_url: str = DEFAULT_BASE,
                 cookies: dict[str, str] | None = None,
                 sign_key: str | None = None,
                 config_path: Path | None = None,
                 client_id: str | None = None,
                 device_id: str | None = None,
                 premium_signature: dict | None = None):
        self.base_url = base_url.rstrip("/")
        self.config_path = config_path or CONFIG_PATH
        # Keep a session for ordinary API calls. Chat requests deliberately use
        # curl_cffi's module-level post() below: Tabbit currently returns 492
        # for premium models when the same request is sent through Session,
        # while the module-level path accepts the captured UI signature.
        if _REQUESTS_LIB == "curl_cffi":
            self.session = requests.Session(impersonate="chrome124")
        else:
            self.session = requests.Session()
        if cookies:
            for k, v in cookies.items():
                self.session.cookies.set(k, v, domain="web.tabbit.ai")
        self.session.headers.update({
            "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                           "AppleWebKit/537.36 (KHTML, like Gecko) "
                           "Chrome/148.0.0.0 Safari/537.36"),
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": self.base_url,
            "Referer": self.base_url + "/",
        })
        self._sign_key = sign_key
        self._client_id = client_id
        self._device_id = device_id
        # Premium unlock: the signed headers plus unique-uuid captured from a
        # real Tabbit UI request. The server treats this set as a bearer token —
        # subsequent requests with these headers (even
        # with a different body) gets premium_only models unlocked. See
        # REVERSE_ENGINEERING.md §12c for the full story.
        self._premium_signature = premium_signature

    def _build_consistency_header(self) -> str:
        """Build the x-chrome-id-consistency-request header.

        Required for premium_only models (Opus, GPT-5.5, ...). The server
        checks device_id against its known-default-browser records.
        """
        # sync_account_id = user_id from cookies (or 'unknown' if absent)
        sync_account_id = (self.session.cookies.get("user_id")
                           or "00000000-0000-0000-0000-000000000000")
        client_id = self._client_id or "e7fa44387b1238ef1f6f"
        device_id = self._device_id or "00000000-0000-0000-0000-000000000000"
        return (f"version=1,client_id={client_id},device_id={device_id},"
                f"sync_account_id={sync_account_id},"
                "signin_mode=all_accounts,signout_mode=show_confirmation")

    # ---- config persistence ----
    @classmethod
    def from_config(cls, path: Path | None = None) -> "TabbitClient":
        path = path or CONFIG_PATH
        cfg: dict[str, Any] = {}
        cookies: dict[str, str] = {}
        base_url = DEFAULT_BASE
        sign_key: str | None = None

        if path.exists():
            cfg = json.loads(path.read_text(encoding="utf-8") or "{}")
            cookies = cfg.get("cookies", {}) or {}
            base_url = cfg.get("base_url", DEFAULT_BASE)
            sign_key = cfg.get("sign_key")

        # Prefer cookies.txt when it is newer than the config (extract_cookies.ps1
        # writes it). Stale tabbit_config.json cookies were a common 401 source.
        cookie_txt = path.parent / "cookies.txt"
        file_cookies = _parse_cookie_string(
            cookie_txt.read_text(encoding="utf-8")
        ) if cookie_txt.exists() else {}
        if file_cookies:
            use_file = False
            if not cookies:
                use_file = True
            else:
                try:
                    use_file = cookie_txt.stat().st_mtime > path.stat().st_mtime
                except OSError:
                    use_file = False
            if use_file:
                cookies = file_cookies
                print(f"[+] Loaded {len(cookies)} cookies from {cookie_txt}")
                print("    (Tip: run `init-cookies --from-file cookies.txt` "
                      "to persist them to tabbit_config.json.)")

        if not cookies:
            raise SystemExit(
                "[!] No cookies found. Either:\n"
                "      a) run script/extract_cookies.ps1, or\n"
                "      b) run: python tabbit_client.py init-cookies "
                "--from-file cookies.txt"
            )
        return cls(base_url=base_url, cookies=cookies,
                   sign_key=sign_key, config_path=path,
                   client_id=cfg.get("client_id"),
                   device_id=cfg.get("device_id"),
                   premium_signature=cfg.get("premium_signature"))

    def save_config(self) -> None:
        cfg = {
            "base_url": self.base_url,
            "cookies": dict(self.session.cookies),
            "sign_key": self._sign_key,
            "client_id": self._client_id,
            "device_id": self._device_id,
            "premium_signature": self._premium_signature,
        }
        self.config_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
        print(f"[+] Saved config -> {self.config_path}")

    # ---- sign key ----
    def get_sign_key(self) -> str:
        if self._sign_key:
            return self._sign_key
        r = self.session.get(f"{self.base_url}/chat/sign-key", timeout=10)
        r.raise_for_status()
        key = r.text.strip()
        if key and key != "null":
            self._sign_key = key
        else:
            self._sign_key = DEFAULT_SIGN_KEY
        return self._sign_key

    # ---- public endpoints ----
    def get_models(self, scene: str = "chat", with_moa: bool = False) -> dict:
        r = self.session.get(
            f"{self.base_url}/proxy/v1/model_config/models",
            params={"scene": scene, "a": "1" if with_moa else "0"},
            timeout=15,
        )
        r.raise_for_status()
        return r.json()

    def _require_auth(self) -> None:
        if not self.session.cookies:
            raise SystemExit(
                "[!] No cookies loaded. Run:\n"
                "      python tabbit_client.py init-cookies \"name=val; ...\"\n"
                "    Then retry. See README.md for how to grab cookies."
            )

    def get_user_info(self) -> dict:
        self._require_auth()
        r = self.session.get(f"{self.base_url}/api/v0/user/base-info",
                             timeout=15)
        if r.status_code == 401:
            raise SystemExit(
                "[!] Session expired. Re-grab cookies and run `init-cookies` again."
            )
        r.raise_for_status()
        return r.json()

    # ---- the main AI call ----
    def chat_completion(self,
                        body: dict,
                        on_event: Callable[[str, Any], None] | None = None,
                        timeout: float | None = None) -> Iterator[tuple[str, Any]]:
        """POST /api/v1/chat/completion and stream SSE events.

        body: full request payload (already built). The function will JSON-
              encode it once for the wire and once for the signature.
        """
        sign_key = self.get_sign_key()
        body_str = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        trace_id = str(uuid.uuid4())
        headers = {
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache",
            "trace-id": trace_id,
            "x-req-ctx": X_REQ_CTX,
            "unique-uuid": str(uuid.uuid4()),
        }
        # If we have a "blessed" premium signature from the Tabbit UI, use it
        # verbatim — it acts as a bearer token and unlocks premium_only models.
        # unique-uuid is part of that token; unlike trace-id, changing it causes
        # a 492 response. Otherwise compute a fresh signature (free models only).
        if self._premium_signature:
            for key in ("x-timestamp", "x-nonce", "x-signature", "unique-uuid"):
                if key in self._premium_signature:
                    headers[key] = self._premium_signature[key]
        else:
            headers.update(_sign_headers(body_str, sign_key))
        kwargs = dict(
            data=body_str.encode("utf-8"),
            headers=headers,
            stream=True,
            timeout=timeout or 30,
        )
        if _REQUESTS_LIB == "curl_cffi":
            # Do not replace this with self.session.post(). curl_cffi's Session
            # path differs enough on the wire that Tabbit's premium gate rejects
            # it, even with the exact same cookies and blessed signature. Passing
            # cookies explicitly mirrors the known-working standalone replay.
            r = requests.post(
                f"{self.base_url}/api/v1/chat/completion",
                cookies=dict(self.session.cookies),
                impersonate="chrome124",
                **kwargs,
            )
        else:
            r = self.session.post(
                f"{self.base_url}/api/v1/chat/completion",
                **kwargs,
            )
        if r.status_code == 499:
            # server signaled bad signature; refresh sign-key and retry once
            print("[i] 499 -> refreshing sign key and retrying", file=sys.stderr)
            self._sign_key = None
            return self.chat_completion(body, on_event, timeout)
        if r.status_code == 401:
            raise SystemExit(
                "[!] 401 Unauthorized. Cookies are missing or expired.\n"
                "    Re-grab them with script/extract_cookies.ps1 and run:\n"
                "      python tabbit_client.py init-cookies \"...\""
            )
        if r.status_code == 493:
            raise SystemExit(
                "[!] 493 browser version outdated. Update TABBIT_VERSION in "
                "tabbit_client.py to match the version Tabbit reports via "
                "chrome://version (e.g. '1.1.39(10101039)')."
            )
        if not r.ok:
            text = r.text[:1000]
            raise SystemExit(f"/api/v1/chat/completion HTTP {r.status_code}: {text}")
        for ev in iter_sse(r):
            if on_event:
                on_event(ev[0], ev[1])
            yield ev


# ---------------------------------------------------------------------------
# Chat body builder
#
# Schema captured live from the Tabbit UI (see captured_request.json).
# Endpoint: POST /api/v1/chat/completion
# ---------------------------------------------------------------------------

def _entity_key(text: str) -> str:
    """The `entity.key` field is an MD5 of... something (probably tab URL).
    Empty Tab matches the constant captured: d41d8cd98f00b204e9800998ecf8427e
    which is also `md5(b"")`. Use that as a safe default."""
    return hashlib.md5(b"").hexdigest()  # empty-content hash


def build_chat_body(
    *,
    text: str,
    model: str = "Default",
    chat_session_id: str | None = None,
    task_name: str = "chat",
    agent_mode: bool = False,
    references: list | None = None,
) -> dict:
    """Build a /api/v1/chat/completion request body matching what Tabbit's UI sends."""
    return {
        "chat_session_id": chat_session_id,
        "message_id": None,
        "content": text,
        "selected_model": model,
        "parallel_group_id": None,
        "task_name": task_name,
        "agent_mode": agent_mode,
        "metadatas": {
            "html_content": f"<p>{text}</p>",
        },
        "references": references or [],
        "entity": {
            "key": _entity_key(text),
            "extras": {"type": "tab", "url": ""},
        },
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _pretty_event(etype: str, payload: Any) -> str:
    if isinstance(payload, dict):
        # short previews for common events
        if etype == "message_chunk" and "content" in payload:
            return f"[chunk] {payload.get('content', '')}"
        if etype == "ready":
            return f"[ready] {json.dumps(payload, ensure_ascii=False)[:120]}"
        if etype == "finish":
            return (f"[finish] model={payload.get('model_name')} "
                    f"tokens={payload.get('usage')}")
        if etype == "error":
            return f"[ERROR] {json.dumps(payload, ensure_ascii=False)[:300]}"
        return f"[{etype}] {json.dumps(payload, ensure_ascii=False)[:200]}"
    return f"[{etype}] {payload}"


def _parse_cookie_string(raw: str) -> dict[str, str]:
    """Parse a Cookie-header style 'name=val; name2=val2' string."""
    cookies: dict[str, str] = {}
    # Strip UTF-8 BOM that PowerShell Out-File sometimes prepends.
    text = (raw or "").lstrip("\ufeff").strip()
    for pair in text.split(";"):
        pair = pair.strip().lstrip("\ufeff")
        if not pair or "=" not in pair:
            continue
        k, v = pair.split("=", 1)
        k, v = k.strip().lstrip("\ufeff"), v.strip()
        if k:
            cookies[k] = v
    return cookies


def cmd_init_cookies(args: argparse.Namespace) -> None:
    """Parse cookies from a string or file and save them as the config.

    Prefer --from-file (or cookies.txt) over a shell-quoted string: values like
    g_state={"i_l":0,...} get mangled by PowerShell when passed as argv.
    """
    raw = ""
    source = ""
    if args.from_file:
        path = Path(args.from_file)
        if not path.is_absolute():
            path = CONFIG_PATH.parent / path
        if not path.exists():
            raise SystemExit(f"[!] Cookie file not found: {path}")
        raw = path.read_text(encoding="utf-8")
        source = str(path)
    elif args.cookie_string:
        raw = args.cookie_string
        source = "<argv>"
    else:
        default_txt = CONFIG_PATH.parent / "cookies.txt"
        if default_txt.exists():
            raw = default_txt.read_text(encoding="utf-8")
            source = str(default_txt)
        else:
            raise SystemExit(
                "[!] Provide a cookie string, --from-file path, or create "
                "cookies.txt via script/extract_cookies.ps1"
            )

    cookies = _parse_cookie_string(raw)
    if not cookies:
        raise SystemExit(f"[!] No cookies parsed from {source}")

    # Preserve non-cookie fields from an existing config when present.
    cfg: dict[str, Any] = {}
    if CONFIG_PATH.exists():
        try:
            cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8") or "{}")
        except json.JSONDecodeError:
            cfg = {}
    cfg["base_url"] = args.base or cfg.get("base_url") or DEFAULT_BASE
    cfg["cookies"] = cookies
    cfg.setdefault("sign_key", None)

    CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    print(f"[+] Wrote {len(cookies)} cookies to {CONFIG_PATH}")
    print(f"    Source: {source}")
    print("    Keys: " + ", ".join(cookies.keys()))
    missing = [k for k in ("token", "user_id", "expires_in") if k not in cookies]
    if missing:
        print(f"[!] Warning: missing expected auth cookies: {', '.join(missing)}")
    if "next-auth.session-token" not in cookies:
        # Older docs required this; current Tabbit sessions often use only `token`.
        print("[i] Note: next-auth.session-token not present "
              "(current sessions may rely on `token` alone).")


def cmd_models(args: argparse.Namespace) -> None:
    c = TabbitClient.from_config()
    data = c.get_models(scene=args.scene, with_moa=args.moa)
    models = data.get("models", [])
    print(f"{len(models)} models (scene={args.scene!r}, moa={args.moa}):")
    print(f"{'NAME':<25} {'ACCESS':<15} {'THINK':<6} {'IMG':<4} FEATURES")
    for m in models:
        print(f"{m.get('display_name',''):<25} "
              f"{m.get('model_access_type',''):<15} "
              f"{'yes' if m.get('support_thinking') else 'no':<6} "
              f"{'yes' if m.get('supports_images') else 'no':<4} "
              f"{m.get('description','')[:80]}")


def cmd_whoami(args: argparse.Namespace) -> None:
    c = TabbitClient.from_config()
    info = c.get_user_info()
    print(json.dumps(info, indent=2, ensure_ascii=False))


def cmd_probe(args: argparse.Namespace) -> None:
    """Send an empty body and print whatever the server says. Use this to
    discover required fields if `chat` returns 422."""
    c = TabbitClient.from_config()
    sign_key = c.get_sign_key()
    print(f"[i] sign_key = {sign_key}")
    print(f"[i] x-req-ctx = {X_REQ_CTX}  (decodes to '{TABBIT_VERSION}')")
    body_str = json.dumps({}, separators=(",", ":"))
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "trace-id": str(uuid.uuid4()),
        "x-req-ctx": X_REQ_CTX,
        "unique-uuid": str(uuid.uuid4()),
        **_sign_headers(body_str, sign_key),
    }
    r = c.session.post(f"{c.base_url}/api/v1/chat/completion",
                       data=body_str.encode("utf-8"),
                       headers=headers, stream=True, timeout=(10, 30))
    print(f"[i] HTTP {r.status_code}")
    print("[i] Response headers:")
    for k, v in r.headers.items():
        print(f"      {k}: {v}")
    print("[i] Response body (first 2000 bytes):")
    n = 0
    for chunk in r.iter_content(chunk_size=2048, decode_unicode=True):
        if chunk:
            sys.stdout.write(chunk)
            n += len(chunk)
            if n >= 2000:
                break
    print()


def cmd_chat(args: argparse.Namespace) -> None:
    c = TabbitClient.from_config()
    # chat_session_id is optional — pass None to start a fresh session
    body = build_chat_body(
        text=args.prompt,
        model=args.model or "Default",
        chat_session_id=args.session,
        agent_mode=args.agent,
    )
    if args.dump_body:
        print("[i] Request body:")
        print(json.dumps(body, indent=2, ensure_ascii=False))
        return
    print(f"[i] POST /api/v1/chat/completion (model={args.model or 'Default'})\n")

    def on_event(etype: str, payload: Any) -> None:
        if args.verbose:
            line = _pretty_event(etype, payload)
            if etype == "message_chunk" and isinstance(payload, dict):
                # inline token stream
                sys.stdout.write(payload.get("content", ""))
                sys.stdout.flush()
            elif etype in ("ready", "title", "finish", "error", "close",
                           "tool_start", "tool_finish", "message_start",
                           "message_finish"):
                sys.stdout.write("\n" + line + "\n")
        else:
            if etype == "message_chunk" and isinstance(payload, dict):
                sys.stdout.write(payload.get("content", ""))
                sys.stdout.flush()
            elif etype == "error":
                # Common server-side errors: 492 (premium only), 493 (version),
                # 494 (quota), etc. Surface a clean message.
                msg = (payload.get("message") or payload.get("error")
                       or json.dumps(payload, ensure_ascii=False))
                code = payload.get("code", "?")
                sys.stdout.write(f"\n[!] error {code}: {msg}\n")
            elif etype == "finish":
                info = f"\n[finish] model={payload.get('model_name')}"
                if payload.get("usage"):
                    info += f" usage={payload.get('usage')}"
                sys.stdout.write(info + "\n")

    try:
        for _ in c.chat_completion(body, on_event=on_event):
            pass
    except KeyboardInterrupt:
        print("\n[i] interrupted", file=sys.stderr)
    print()


def main() -> None:
    p = argparse.ArgumentParser(
        prog="tabbit_client",
        description="Direct API client for the Tabbit AI backend.",
    )
    p.add_argument("--base", default=DEFAULT_BASE,
                   help=f"Base URL (default: {DEFAULT_BASE})")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser(
        "init-cookies",
        help="Save session cookies to config file. Prefer --from-file on "
             "PowerShell (inline JSON cookie values get mangled by the shell).",
    )
    sp.add_argument(
        "cookie_string",
        nargs="?",
        default=None,
        help='Cookie header value, e.g. "SID=abc; user_id=123". '
             "Optional if --from-file or cookies.txt is used.",
    )
    sp.add_argument(
        "--from-file",
        metavar="PATH",
        default=None,
        help="Read cookie string from a file (recommended). "
             "Defaults to cookies.txt when cookie_string is omitted.",
    )
    sp.set_defaults(func=cmd_init_cookies)

    sp = sub.add_parser("models", help="List available models")
    sp.add_argument("--scene", default="chat")
    sp.add_argument("--moa", action="store_true",
                    help="Include Meituan-internal models (requires cert).")
    sp.set_defaults(func=cmd_models)

    sp = sub.add_parser("whoami", help="Show current user info")
    sp.set_defaults(func=cmd_whoami)

    sp = sub.add_parser("probe",
                        help="Send empty body to /api/v1/chat/completion and "
                             "print response (use to discover required fields).")
    sp.set_defaults(func=cmd_probe)

    sp = sub.add_parser("chat", help="Send a chat message and stream tokens")
    sp.add_argument("prompt", help="The user message")
    sp.add_argument("-m", "--model", default="Default",
                    help='Model display_name (e.g. "GLM-5.2"). '
                         'Default: "Default" (free unlimited).')
    sp.add_argument("--session", default=None,
                    help="Existing chat_session_id. Omit to start a fresh session.")
    sp.add_argument("--agent", action="store_true",
                    help="Enable agent mode (tool use / browser actions).")
    sp.add_argument("-v", "--verbose", action="store_true",
                    help="Print all SSE events, not just the token stream.")
    sp.add_argument("--dump-body", action="store_true",
                    help="Print the request body and exit (no send).")
    sp.set_defaults(func=cmd_chat)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
