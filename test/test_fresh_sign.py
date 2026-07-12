import json, uuid, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tabbit_client import _sign_headers, DEFAULT_SIGN_KEY
cfg = json.loads((ROOT / "tabbit_config.json").read_text(encoding="utf-8"))
from curl_cffi import requests as cureq

# Reuse captured body but with FRESH signature (new timestamp/uuid/nonce)
cap = json.loads((ROOT / "replay_payload.json").read_text(encoding="utf-8"))
body_str = cap["body"]
sign_hdrs = _sign_headers(body_str, DEFAULT_SIGN_KEY)

print(f"Using body (first 80): {body_str[:80]}...")
print(f"Fresh x-timestamp: {sign_hdrs['x-timestamp']}")
print(f"Fresh x-signature: {sign_hdrs['x-signature']}")
print()

r = cureq.post(
    "https://web.tabbit.ai/api/v1/chat/completion",
    data=body_str.encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "x-req-ctx": "MS4xLjM5KDEwMTAxMDM5KQ==",
        "unique-uuid": str(uuid.uuid4()),
        "Accept": "text/event-stream",
        "Cache-Control": "no-cache",
        "trace-id": str(uuid.uuid4()),
        **sign_hdrs,
    },
    cookies=cfg["cookies"],
    impersonate="chrome124",
    stream=True, timeout=30,
)
print(f"HTTP {r.status_code}")
for i, line in enumerate(r.iter_lines()):
    if isinstance(line, bytes):
        line = line.decode("utf-8", errors="replace")
    print(line)
    if i > 10:
        break
