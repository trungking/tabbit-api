"""Definitive test: impersonate Chrome's TLS fingerprint."""
import json, uuid, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
import sys; sys.path.insert(0, str(ROOT))

# Load cookies from tabbit_config.json
cfg = json.loads((ROOT / "tabbit_config.json").read_text(encoding="utf-8"))
cookies = cfg["cookies"]

from curl_cffi import requests as cureq

body = {
    "chat_session_id": None, "message_id": None, "content": "hi",
    "selected_model": "Claude-Opus-4.8", "parallel_group_id": None,
    "task_name": "chat", "agent_mode": False,
    "metadatas": {"html_content": "<p>hi</p>"}, "references": [],
    "entity": {"key": "d41d8cd98f00b204e9800998ecf8427e", "extras": {"type": "tab", "url": ""}},
}
body_str = json.dumps(body, separators=(",", ":"))

# Try with Chrome 124 impersonation (TLS + HTTP/2 fingerprint)
r = cureq.post(
    "https://web.tabbit.ai/api/v1/chat/completion",
    data=body_str.encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "Cache-Control": "no-cache",
        "x-req-ctx": "MS4xLjM5KDEwMTAxMDM5KQ==",
        "unique-uuid": str(uuid.uuid4()),
        "trace-id": str(uuid.uuid4()),
        "Origin": "https://web.tabbit.ai",
        "Referer": "https://web.tabbit.ai/",
    },
    cookies=cookies,
    impersonate="chrome124",
    stream=True,
    timeout=30,
)
print(f"HTTP {r.status_code}")
for i, line in enumerate(r.iter_lines()):
    print(line)
    if i > 15:
        break
