import sys, json, uuid, pathlib, requests
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tabbit_client import TabbitClient, _sign_headers

c = TabbitClient.from_config()
sign_key = c.get_sign_key()

body = {
    "device_id": str(uuid.uuid4()),
    "device_name": "DESKTOP",
    "device_type": "desktop",          # was missing
    "platform": "win",
    "os_version": "10.0.0",
    "browser_version": "1.1.39",
    "tabbit_version": "1.1.39",
    "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
    "default_browser": "Tabbit",
    "is_default_browser": True,
    "sparkle_version": 20260608,       # must be int (looks like YYYYMMDD build date)
    "screen_resolution": {"width": 1920, "height": 1080},
    "timezone": "Asia/Shanghai",
    "language": "en-US",
}
body_str = json.dumps(body, separators=(",", ":"))
print("=== POST /api/v0/report/upsert-user-device-info ===")

# Try 1: with signing + version header (same scheme as chat)
sign_key = c.get_sign_key()
hdrs = {
    "Content-Type": "application/json",
    "x-req-ctx": "MS4xLjM5KDEwMTAxMDM5KQ==",
    "unique-uuid": str(uuid.uuid4()),
    "trace-id": str(uuid.uuid4()),
    **_sign_headers(body_str, sign_key),
}
r = c.session.post(f"{c.base_url}/api/v0/report/upsert-user-device-info",
                   data=body_str.encode("utf-8"), headers=hdrs, timeout=15)
print(f"HTTP {r.status_code}")
print(f"Body: {r.text[:800]}")
sc = r.headers.get("set-cookie")
if sc:
    print(f"Set-Cookie: {sc[:300]}")

# If 422/400, the server will tell us which fields are wrong
if r.status_code in (400, 422):
    print("\n=== Server's complaint parsed ===")
    try:
        j = r.json()
        print(json.dumps(j, indent=2))
    except Exception:
        pass
