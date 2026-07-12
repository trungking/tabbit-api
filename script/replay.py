"""Replay the UI's exact captured request from Python (curl_cffi Chrome TLS)."""
import json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

cap = json.loads((ROOT / "replay_payload.json").read_text(encoding="utf-8"))
cfg = json.loads((ROOT / "tabbit_config.json").read_text(encoding="utf-8"))

from curl_cffi import requests as cureq

# Use the EXACT headers from the captured UI request (no modification)
headers = dict(cap["headers"])
body = cap["body"]

print("=== Replay with curl_cffi (chrome124 TLS), exact captured headers ===")
r = cureq.post(
    "https://web.tabbit.ai/api/v1/chat/completion",
    data=body.encode("utf-8"),
    headers=headers,
    cookies=cfg["cookies"],
    impersonate="chrome124",
    stream=True,
    timeout=30,
)
print(f"HTTP {r.status_code}")
for i, line in enumerate(r.iter_lines()):
    if isinstance(line, bytes):
        line = line.decode("utf-8", errors="replace")
    print(line)
    if i > 10:
        break

# Also try with vanilla requests for comparison
print("\n=== Replay with vanilla requests ===")
import requests
c = requests.Session()
for k, v in cfg["cookies"].items():
    c.cookies.set(k, v, domain="web.tabbit.ai")
c.headers.update({
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
    "Accept-Language": "en-US,en;q=0.9",
    "Origin": "https://web.tabbit.ai",
    "Referer": "https://web.tabbit.ai/session/a37d55c4-aecf-47bc-a386-14a0a1078df8",
})
r = c.post(
    "https://web.tabbit.ai/api/v1/chat/completion",
    data=body.encode("utf-8"),
    headers=headers,
    stream=True,
    timeout=(10, 30),
)
print(f"HTTP {r.status_code}")
for i, line in enumerate(r.iter_lines(decode_unicode=True)):
    print(line)
    if i > 10:
        break
