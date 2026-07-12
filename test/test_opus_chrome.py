import sys, json, uuid, pathlib, requests
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tabbit_client import TabbitClient

c = TabbitClient.from_config()
c.session.headers["User-Agent"] = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36")

body = {
    "chat_session_id": None, "message_id": None, "content": "hi",
    "selected_model": "Claude-Opus-4.8", "parallel_group_id": None,
    "task_name": "chat", "agent_mode": False,
    "metadatas": {"html_content": "<p>hi</p>"}, "references": [],
    "entity": {"key": "d41d8cd98f00b204e9800998ecf8427e", "extras": {"type": "tab", "url": ""}},
}
body_str = json.dumps(body, separators=(",", ":"))

r = c.session.post(
    f"{c.base_url}/api/v1/chat/completion",
    data=body_str.encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "Cache-Control": "no-cache",
        "x-req-ctx": "MS4xLjM5KDEwMTAxMDM5KQ==",
        "unique-uuid": str(uuid.uuid4()),
        "trace-id": str(uuid.uuid4()),
        # The exact sec-ch-ua Tabbit's UI sends (brands = Google Chrome, Chromium, Not/A)Brand)
        "sec-ch-ua": '"Google Chrome";v="148", "Chromium";v="148", "Not/A)Brand";v="99"',
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '"Windows"',
        "Sec-Fetch-Site": "same-origin",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Dest": "empty",
    },
    stream=True, timeout=(10, 30),
)
print(f"HTTP {r.status_code}")
for i, line in enumerate(r.iter_lines(decode_unicode=True)):
    print(line)
    if i > 12:
        break
