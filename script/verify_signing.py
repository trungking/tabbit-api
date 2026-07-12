import hashlib, hmac, json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

# Load captured request
cap = json.loads((ROOT / "replay_payload.json").read_text(encoding="utf-8"))
body = cap["body"]
sign_key = "f8d0e6a73f8d4b1a9c3d2e1f9a4b7c6d"

# From captured headers
timestamp = cap["headers"]["x-timestamp"]
random = cap["headers"]["x-signature"]
captured_nonce = cap["headers"]["x-nonce"]

# Compute what we think the nonce should be
body_hash = hashlib.sha256(body.encode()).hexdigest()
toSign = f"{timestamp}.{random}.{body_hash}"
computed_nonce = hmac.new(sign_key.encode(), toSign.encode(), hashlib.sha256).hexdigest()

print(f"body_hash:    {body_hash}")
print(f"toSign:       {toSign}")
print(f"captured x-nonce:     {captured_nonce}")
print(f"computed x-nonce:     {computed_nonce}")
print(f"MATCH: {captured_nonce == computed_nonce}")

# Also check the sign key — maybe it's been rotated
print(f"\nNow trying via /chat/sign-key:")
import requests
r = requests.get("https://web.tabbit.ai/chat/sign-key", timeout=10)
current_key = r.text.strip()
print(f"Current sign-key: {current_key}")
print(f"Default literal:  {sign_key}")
print(f"Same: {current_key == sign_key}")
if current_key != sign_key:
    computed2 = hmac.new(current_key.encode(), toSign.encode(), hashlib.sha256).hexdigest()
    print(f"with current key: {computed2}")
    print(f"Match: {captured_nonce == computed2}")
