# GLM Handoff: Tabbit Premium Model Unlock

## Resolved 2026-06-23

The premium grant is a **four-header token**, not the three-header trio
originally described below. `unique-uuid` is bound to `x-timestamp`,
`x-nonce`, and `x-signature`: changing `trace-id` still works, but changing
`unique-uuid` returns 492. `tabbit_client.py` now uses module-level
`curl_cffi.requests.post(...)`, passes cookies explicitly, and replays all four
captured values. Verified through the normal CLI with Claude-Opus-4.8 and
GPT-5.5, both with `chat_session_id: null`. The same token is therefore
cross-session and cross-model (for those two models).

`script/capture_and_replay_fresh.ps1` now validates and writes all four values directly
to `tabbit_config.json`, so refreshing the token is a single script invocation
while Tabbit is running with CDP enabled.
## TL;DR

We're reverse-engineering Tabbit (a Chromium-based AI browser by Meituan) to
call its AI models directly from Python, **without running the Tabbit app**.
Free models work. **Premium models (Claude-Opus-4.8, GPT-5.5, etc.) are
locked behind a server-side gate we haven't fully cracked.**

There is **one known way in**: a captured `x-signature` from the Tabbit UI
acts as a bearer token. The next agent needs to figure out why my Python
client can't use it reliably, OR find a better way to obtain/refresh it.

---

## The Goal

Write a Python client that can call **any** Tabbit model — including
`premium_only` ones (Claude-Opus-4.8, GPT-5.5, Gemini-3.5-Flash,
Claude-Sonnet-4.6) — without the Tabbit desktop app running. The user has
a valid Tabbit account with premium access (unlocked by setting Tabbit as
the default browser once).

---

## What Works

✅ **17 free models** (Default, GLM-5.2, DeepSeek-V3.2, Claude-Haiku-4.5,
   Qwen3.5-Plus, Doubao-Seed-1.8, etc.) — fully working from Python.

✅ **Endpoint discovered**: `POST https://web.tabbit.ai/api/v1/chat/completion`
   returns SSE stream.

✅ **Signing scheme reverse-engineered** and verified:
   ```
   x-timestamp = ms_epoch
   x-signature = uuid4                      # NOT hex — this is (0,a.l)() in JS
   body_hash   = sha256(body).hex()
   toSign      = f"{x-timestamp}.{x-signature}.{body_hash}"
   x-nonce     = hmac_sha256(sign_key, toSign).hex()
   sign_key    = "f8d0e6a73f8d4b1a9c3d2e1f9a4b7c6d"  (literal in JS bundle)
   ```

✅ **Version gate bypassed**: `x-req-ctx: base64("1.1.39(10101039)")` header
   required or server returns HTTP 493 "browser version outdated".

✅ **Body schema captured** (see `captured_request.json`):
   ```json
   {
     "chat_session_id": null,
     "message_id": null,
     "content": "hi",
     "selected_model": "Claude-Opus-4.8",
     "parallel_group_id": null,
     "task_name": "chat",
     "agent_mode": false,
     "metadatas": {"html_content": "<p>hi</p>"},
     "references": [],
     "entity": {"key": "d41d8cd98f00b204e9800998ecf8427e",
                "extras": {"type": "tab", "url": ""}}
   }
   ```

✅ **Cookies**: 7 needed — `token`, `user_id`, `expires_in`, `next-auth.session-token`,
   `SAPISID`, `managed`, `NEXT_LOCALE`. All in `tabbit_config.json`.

---

## The Problem

**Premium models return HTTP 492** ("premium users only") from Python,
**even with correct cookies, signing, version header, and Chrome TLS
impersonation via `curl_cffi`.**

### What we ruled out

| Hypothesis | Test | Result |
|---|---|---|
| Missing cookie | Refreshed all 7 from browser | ❌ still 492 |
| Missing `x-req-ctx` | Added | ❌ still 492 (493 without it) |
| Wrong signing | Verified HMAC matches captured byte-for-byte | ❌ still 492 |
| TLS fingerprint | Used `curl_cffi` with `impersonate="chrome124"` | ❌ still 492 |
| Session vs request impersonate | Both tried | ❌ both 492 |
| `sec-ch-ua` brand | Tried `"Google Chrome"` vs `"Tabbit"` | ❌ both 492 |
| `x-chrome-id-consistency-request` | Tried with/without | ❌ both 492 |
| Matching `Referer: /session/{id}` | Tried | ❌ still 492 |
| Fresh vs existing session_id | Both | ❌ both 492 |
| Plain `fetch()` from inside Tabbit page | Tested | ❌ 492 (but UI works!) |

### The key discovery (this is the lever)

**A captured `x-signature` from the Tabbit UI works as a BEARER TOKEN.**

When Tabbit's React UI sends a request, the server "blesses" that
`{x-timestamp, x-nonce, x-signature}` trio. **Replaying those exact three
headers with a DIFFERENT body still works** — the server doesn't re-validate
the HMAC against the new body. Example:

```python
# This WORKS (Opus answers correctly):
captured_headers = {
    "x-timestamp": "1782148261919",        # from UI
    "x-nonce": "d45b9bc490a25...",          # from UI
    "x-signature": "491651cd-9437-...",     # from UI
}
requests.post(url, headers={**other, **captured_headers},
              data=different_body, impersonate="chrome124")
# → HTTP 200, Opus streams tokens
```

```python
# This FAILS (492) — same body, freshly computed signature:
fresh = sign_body(body)  # produces valid HMAC, verified identical to JS
requests.post(url, headers={**other, **fresh},
              data=body, impersonate="chrome124")
# → HTTP 492
```

**So the server is caching "blessed" signatures** from real UI requests
and accepting them as proof of premium entitlement. Fresh signatures — even
cryptographically correct ones — don't unlock premium.

### The current mystery (unsolved)

The captured signature **does** work when called via module-level
`curl_cffi.requests.post(...)` but **does NOT** work when called via a
`curl_cffi.requests.Session()` — even with `impersonate="chrome124"` set
on the Session. The last test comparing these two paths hung without
output. **This is the immediate blocker.**

Possible explanations to investigate:
1. `Session()` might not actually apply `impersonate` correctly (curl_cffi bug?)
2. `Session()` might merge headers differently (case sensitivity? ordering?)
3. `Session()` cookie jar might serialize differently than `cookies=dict`
4. HTTP/2 connection reuse in Session changes something

---

## What the Next Agent Should Do

### Step 1: Diagnose the Session vs module-level difference

The known-working call pattern is:
```python
from curl_cffi import requests as cureq
r = cureq.post(url, data=body, headers=headers,
               cookies=cfg["cookies"], impersonate="chrome124",
               stream=True, timeout=30)
# Works for Opus
```

The failing pattern (in `tabbit_client.py`):
```python
s = cureq.Session(impersonate="chrome124")
for k,v in cookies.items(): s.cookies.set(k, v, domain="web.tabbit.ai")
r = s.post(url, data=body, headers=headers, stream=True, timeout=30)
# 492
```

**Fix this and the client works.** Compare:
- TLS handshake (JA3) — use Wireshark or a JA3-reporting endpoint
- HTTP/2 frame ordering
- Header capitalization (curl_cffi may lowercase in Session mode)
- Cookie header format (`name=val; name2=val2` vs Cookie jar serialization)

### Step 2: If Session can't be fixed, restructure the client

Use module-level `cureq.post()` for the chat call, passing `cookies=dict`
explicitly. This sacrifices connection reuse but works. The `chat_completion`
method in `tabbit_client.py` is the only place that needs this — other
endpoints (models, whoami, sign-key) work fine with regular `requests`.

### Step 3: Automate premium signature capture

Currently the signature is captured manually via CDP (see
`script/capture_and_replay_fresh.ps1`). Build a `capture-premium` subcommand that:

1. Connects to the running Tabbit via CDP (`http://127.0.0.1:9222`)
2. Patches `window.fetch` in the chat page to save the next
   `/api/v1/chat/completion` request's `{x-timestamp, x-nonce, x-signature}`
3. Triggers a UI send (types into `[role="textbox"]`, dispatches Enter)
4. Reads the captured signature and saves it to `tabbit_config.json`

The captured signature appears to be long-lived (we reused it across many
requests over 30+ minutes). It may eventually expire — test the TTL.

### Step 4: Test signature scope

We confirmed the captured Opus signature works for Opus with any body on
the same `chat_session_id`. We did NOT test:
- Does it work for a DIFFERENT `chat_session_id`?
- Does it work for a DIFFERENT model (GPT-5.5, Gemini)?
- Does it work with `chat_session_id: null`?
- How long does it stay valid?

Run these tests — they determine whether we need one signature per model
or just one signature total.

---

## How to Interact with Tabbit

### Launch Tabbit with CDP

```powershell
$exe = "D:\Software\Tabbit\Application\Tabbit.exe"
$ud = "$env:TEMP\tabbit_debug_profile"
Start-Process -FilePath $exe -ArgumentList @(
    "--remote-debugging-port=9222",
    "--user-data-dir=$ud",
    "https://web.tabbit.ai/chat"
)
```

Wait ~10 seconds, then CDP is at `http://127.0.0.1:9222`.

### CDP endpoints

| URL | Purpose |
|---|---|
| `GET /json/version` | Browser info + `webSocketDebuggerUrl` |
| `GET /json` | List page/service_worker targets |
| `GET /json/list` | Same, more detail |
| `ws://.../devtools/page/{id}` | Page-level CDP (Runtime.evaluate works) |
| `ws://.../devtools/browser/{id}` | Browser-level CDP (Target.attachToTarget) |

### Connect via PowerShell + .NET WebSocket

```powershell
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, ..."
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(30))
$ws.ConnectAsync($page.webSocketDebuggerUrl, $cts.Token).Wait()
```

### Evaluate JS in the page

```powershell
function Eval([string]$expr) {
    $body = @{ id = 1; method = "Runtime.evaluate";
               params = @{ expression = $expr; returnByValue = $true }
             } | ConvertTo-Json -Depth 10 -Compress
    $b = [System.Text.Encoding]::UTF8.GetBytes($body)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($b), "Text", $true, $cts.Token)
    $buf = New-Object byte[] 131072
    $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).Result
    return ([System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
            | ConvertFrom-Json).result.result.value
}
```

### Read cookies

```powershell
$msg = @{ id = 1; method = "Network.getAllCookies" } | ConvertTo-Json -Compress
# send via ws, receive, parse resp.result.cookies
```

### Hook fetch in the page

```javascript
(function(){
  window.__cap = null;
  const of = window.fetch;
  window.fetch = function(input, init){
    const url = typeof input === 'string' ? input : input.url;
    if (url && url.indexOf('/api/v1/chat/completion') !== -1 && init) {
      const h = init.headers || {};
      const flat = {};
      if (h instanceof Headers) h.forEach((v,k)=>flat[k]=v);
      else Object.assign(flat, h||{});
      window.__cap = { headers: flat, body: init.body };
    }
    return of.apply(this, arguments);
  };
})()
```

### Trigger a UI send (type + Enter)

```javascript
(function(){
  const box = document.querySelector('[role="textbox"]');
  box.focus();
  const sel = window.getSelection();
  sel.removeAllRanges();
  const range = document.createRange();
  range.selectNodeContents(box);
  sel.addRange(range);
  document.execCommand('insertText', false, 'hi');
  const opts = {bubbles:true, cancelable:true, key:'Enter',
                code:'Enter', keyCode:13, which:13, view:window};
  box.dispatchEvent(new KeyboardEvent('keydown', opts));
  box.dispatchEvent(new KeyboardEvent('keypress', opts));
  box.dispatchEvent(new KeyboardEvent('keyup', opts));
})()
```

### Switch model in the UI

```javascript
// Click the model selector button (shows current model name)
[...document.querySelectorAll('button')].find(b =>
  /^(Default|Claude|GPT|Gemini|GLM|DeepSeek)/i.test((b.innerText||'').trim())
  && b.offsetWidth > 0
).click();

// Then click the option
[...document.querySelectorAll('[role="option"],[role="menuitem"],li,button,div')]
  .find(e => (e.innerText||'').trim() === 'Claude-Opus-4.8').click();
```

---

## Files & Artifacts

All in `D:\Software\Tabbit\tabbit_api\`:

| File | Purpose |
|---|---|
| `tabbit_client.py` | The Python client (works for free models) |
| `tabbit_config.json` | Cookies + premium_signature + client_id/device_id |
| `cookies.txt` | Raw cookie string (fallback for config) |
| `script/extract_cookies.ps1` | CDP cookie extractor |
| `script/capture_and_replay_fresh.ps1` | Captures a UI request via CDP |
| `fresh_capture.json` | A captured UI request (Opus, blessed signature) |
| `replay_payload.json` | Earlier captured UI request |
| `test/test_reuse_sig.py` | Proof that captured signature works for any body |
| `script/verify_signing.py` | Proof that our HMAC matches the JS byte-for-byte |
| `README.md` | User-facing docs |
| `REVERSE_ENGINEERING.md` | Full RE knowledge base (read this!) |

Downloaded JS chunks at `C:\Users\vhctr\AppData\Local\Temp\opencode\tabbit_chunks\`:
- `root\7978-28728a0635c9f673.js` — chat client + signing logic
- `root\584-88a5c38224152ab2.js` — chat UI state machine
- `root\9219-dc535079a43b88f9.js` — extension bridge, env config

App binaries at `D:\Software\Tabbit\Application\1.1.39.0\`:
- `Tabbit.dll` — 285MB Chromium runtime (search with `[regex]::Matches` on UTF8 bytes)
- Extension `nmbemfeekdkfhjikjegnegkndcehpfej` embedded in DLL at path `tab_chat/`

---

## Key Facts Reference

- **Tabbit version**: `1.1.39` (build `10101039`)
- **`x-req-ctx`**: `base64("1.1.39(10101039)")` = `MS4xLjM5KDEwMTAxMDM5KQ==`
- **Sign key**: `f8d0e6a73f8d4b1a9c3d2e1f9a4b7c6d` (refreshable via `GET /chat/sign-key`)
- **Extension ID**: `nmbemfeekdkfhjikjegnegkndcehpfej`
- **Chrome UA**: `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36`
- **Client ID**: `e7fa44387b1238ef1f6f` (from `azp` in JWT)
- **Device ID**: `ff0666ec-7f01-400c-b98c-4b592152acd5` (from captured header)
- **User ID**: `ba7b2f78-47a2-48d0-82a0-cb8862563170`
- **CDP port**: `9222` (when launched with `--remote-debugging-port=9222`)
- **Python lib**: `curl_cffi` (`pip install curl-cffi`) — impersonates Chrome TLS

---

## Open Questions

1. **Why does `curl_cffi.Session(impersonate=...)` fail but module-level
   `cureq.post(impersonate=...)` works?** This is THE blocker.
2. **How long does a blessed signature stay valid?** We saw 30+ min. TTL?
3. **Is the signature per-model or universal?** Only tested Opus.
4. **Does the server track "active session" state?** The UI works because
   it's the real client; maybe there's a websocket or heartbeat we missed.
5. **Is there a `/api/v0/report/upsert-user-device-info` body that actually
   grants premium?** We got HTTP 200 but it didn't unlock anything.

---

## Last Known Working Command

This Python snippet **successfully calls Claude-Opus-4.8** (as of
2026-06-22):

```python
import json, pathlib
from curl_cffi import requests as cureq

cfg = json.loads(pathlib.Path(r"D:\Software\Tabbit\tabbit_api\tabbit_config.json").read_text())
cap = json.loads(pathlib.Path(r"D:\Software\Tabbit\tabbit_api\fresh_capture.json").read_text())

body = json.dumps({
    "chat_session_id": "a37d55c4-aecf-47bc-a386-14a0a1078df8",
    "message_id": None, "content": "Hello",
    "selected_model": "Claude-Opus-4.8", "parallel_group_id": None,
    "task_name": "chat", "agent_mode": False,
    "metadatas": {"html_content": "<p>Hello</p>"}, "references": [],
    "entity": {"key": "d41d8cd98f00b204e9800998ecf8427e",
               "extras": {"type": "tab", "url": ""}},
}, separators=(",", ":"))

r = cureq.post(
    "https://web.tabbit.ai/api/v1/chat/completion",
    data=body.encode("utf-8"),
    headers=dict(cap["headers"]),           # the blessed signature
    cookies=cfg["cookies"],
    impersonate="chrome124",
    stream=True, timeout=30,
)
# r streams Opus's reply
```

The task: make this work **without** the manual capture step, OR make it
work through `tabbit_client.py`'s `chat_completion` method (which currently
uses `Session()` and fails).

---

*Written 2026-06-22. All artifacts in `D:\Software\Tabbit\tabbit_api\`.
Start by reading `REVERSE_ENGINEERING.md` for full context.*
