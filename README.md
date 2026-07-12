# Tabbit API client

Direct Python client for the Tabbit AI backend (`https://web.tabbit.ai`).
Reconstructed from the Next.js PWA bundle. Bypasses the desktop app entirely.

> **Continuing the reverse-engineering work?** Full technical dump of every
> endpoint, signing scheme, SSE event, chunk reference, and TODO item lives in
> **[REVERSE_ENGINEERING.md](./REVERSE_ENGINEERING.md)**. Start there.

## Setup

```powershell
python -m pip install curl-cffi
```

## 1. Get a session cookie

Tabbit's `/chat/send` returns `401` without a logged-in session. You only need
to grab cookies **once** (until they expire).

### Option A - automated (recommended)

```powershell
.\script\extract_cookies.ps1
```

This launches `Tabbit.exe` with `--remote-debugging-port=9222`, asks you to
log in, then pulls cookies via the Chrome DevTools Protocol. It writes
`cookies.txt` and prints the ready-to-paste cookie string.

### Option B - manual

1. Open `https://web.tabbit.ai` in your normal browser, log in.
2. Open DevTools → Application → Cookies → `https://web.tabbit.ai`.
3. Copy all cookie `name=value` pairs, joined by `; `.

## 2. Save the cookie

```powershell
python tabbit_client.py init-cookies "name1=val1; name2=val2; ..."
```

Writes `tabbit_config.json` next to the script. Re-run whenever cookies expire.

## 3. List models

```powershell
python tabbit_client.py models
```

```
21 models (scene='chat', moa=False):
NAME                      ACCESS           THINK  IMG  FEATURES
Default                   free_unlimited   no     yes  Default mode, no model usage...
GLM-5.2                   free_metered     yes    no   zAI's latest text model...
Claude-Opus-4.8           premium_only     yes    yes  Anthropic's latest flagship...
GPT-5.5                   premium_only     no     yes  OpenAI's latest flagship...
...
```

## 4. Check who the session belongs to

```powershell
python tabbit_client.py whoami
```

If this returns 401, your cookies have expired — re-grab them.

## 4b. Premium model access

Premium models require a request token issued to the real Tabbit UI. The token
consists of `x-timestamp`, `x-nonce`, `x-signature`, and `unique-uuid`; changing
`unique-uuid` invalidates it. A captured token can be reused across request
bodies, fresh chat sessions, and premium models (verified with Claude-Opus-4.8
and GPT-5.5).

After setting Tabbit as the default browser and logging in:

1. Launch Tabbit with remote debugging enabled and open a chat session:

   ```powershell
   & "D:\Software\Tabbit\Application\Tabbit.exe" `
     --remote-debugging-port=9222 `
     --user-data-dir="$env:TEMP\tabbit_debug_profile" `
     "https://web.tabbit.ai/chat"
   ```

2. Select a premium model in the UI, then run:

   ```powershell
   .\script\capture_and_replay_fresh.ps1
   ```

   The script sends a small UI message and saves the complete premium token to
   `tabbit_config.json` without printing its values.

3. The desktop app can now be closed. Test the standalone client:

   ```powershell
   python tabbit_client.py chat -m Claude-Opus-4.8 "Reply with exactly: OK"
   ```

Refresh the captured token by repeating step 2 if premium requests begin
returning `492`. Cookies and the premium token are credentials; do not commit
`tabbit_config.json` or `fresh_capture.json`.
## 5. Send a chat message (streaming)

```powershell
python tabbit_client.py chat "Explain quicksort in two sentences"
python tabbit_client.py chat -m GLM-5.2 "Write a Python fibonacci"
python tabbit_client.py chat -m "Claude-Haiku-4.5" --thinking "Prove sqrt(2) is irrational"
python tabbit_client.py chat -v "Hi"               # print every SSE event
python tabbit_client.py chat --dump-body "Hi"      # show request body, don't send
```

## 6. OpenAI-compatible server

Start a local server (binds to localhost by default):

```powershell
python openai_server.py --port 8000
```

It implements `GET /v1/models` and `POST /v1/chat/completions`, including
OpenAI-style SSE streaming. Text system/user/assistant history is supported.
Tool definitions are currently accepted and silently ignored; image inputs and
`n` values other than `1` return an explicit OpenAI-shaped error.

Use it with the OpenAI Python client:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8000/v1", api_key="unused")
response = client.chat.completions.create(
    model="Claude-Opus-4.8",
    messages=[{"role": "user", "content": "Hello"}],
)
print(response.choices[0].message.content)
```

Or with streaming:

```python
stream = client.chat.completions.create(
    model="GPT-5.5",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="")
```

Authentication is disabled for localhost use unless `TABBIT_SERVER_API_KEY`
is set. When set, clients must send that value as a bearer API key:

```powershell
$env:TABBIT_SERVER_API_KEY = "choose-a-local-secret"
python openai_server.py --host 0.0.0.0 --port 8000
```

Do not expose the server to a network without setting this key. Unsupported
OpenAI parameters such as `temperature` and `max_tokens` are accepted for
client compatibility but currently ignored by Tabbit's adapter.
### Docker Compose

The image contains only the server code. `tabbit_config.json` is excluded from
the build context and mounted read-only at runtime.

```powershell
docker compose up --build -d
docker compose logs -f
```

The API is then available at `http://127.0.0.1:8000/v1`. Stop any native server
already using port 8000 before starting Compose. To stop the container:

```powershell
docker compose down
```

### WSLC (WSL containers)

`wslc` is the native WSL container CLI (`C:\Program Files\WSL\wslc.exe`). It
supports Docker-style `build` / `run` / `stop`, but **not** Compose. Use the
helper scripts (or the raw commands below).

Prerequisite: valid `tabbit_config.json` (from `.\script\extract_cookies.ps1`).

```powershell
# build + run detached on :8000, mounts tabbit_config.json
.\script\wslc_up.ps1

# logs / stop
wslc logs tabbit-openai
.\script\wslc_down.ps1
```

Equivalent raw `wslc` commands:

```powershell
wslc build -t tabbit-openai:latest -f Dockerfile .
wslc run -d --name tabbit-openai -p 8000:8000 `
  -e TABBIT_CONFIG=/app/tabbit_config.json `
  -v "${PWD}\tabbit_config.json:/app/tabbit_config.json" `
  tabbit-openai:latest

wslc logs tabbit-openai
wslc stop tabbit-openai
wslc remove tabbit-openai
```

Optional API key:

```powershell
$env:TABBIT_SERVER_API_KEY = "choose-a-local-secret"
.\script\wslc_up.ps1
```
## How it works (reverse-engineered)

The chat endpoint discovered via CDP capture of the running Tabbit UI:

| Piece                       | Source                                          |
|----------------------------|--------------------------------------------------|
| Real chat endpoint          | `POST /api/v1/chat/completion` (NOT `/chat/send`) |
| HMAC signing scheme         | chunk `7978-...js` (`y()`, `p()`, `f()`)        |
| Sign-key default + refresh  | same chunk (`/chat/sign-key`, literal fallback)  |
| `x-req-ctx` version header  | **Required or server returns 493 "outdated"**. Base64 of `"1.1.39(10101039)"` |
| `unique-uuid` per-request   | UUID v4                                         |
| Chat body schema            | captured live via CDP `fetch` hook from Tabbit UI |
| Login endpoints             | `app/login/page-f5ea128a2a528d03.js`             |
| Chrome-extension bridge ID  | `nmbemfeekdkfhjikjegnegkndcehpfej`               |

### Request signing

Every `POST /api/v1/chat/completion` carries these three headers, computed
from the JSON body:

```text
bodyHash  = hex(SHA-256(body))
toSign    = "{timestamp}.{random16}.{bodyHash}"
x-timestamp = timestamp
x-nonce     = hex(HMAC-SHA256(sign_key, toSign))
x-signature = uuid4()
trace-id    = uuid4()
x-req-ctx   = base64("1.1.39(10101039)")   # the version gate!
unique-uuid = uuid4()
```

`sign_key` is refreshed via `GET /chat/sign-key` (returns plain text). If the
server returns HTTP `499` (bad signature), the client re-fetches the key and
retries the request once. If it returns `493`, your `TABBIT_VERSION` constant
is stale — bump it to match the running Tabbit.

### Server-Sent Events

Each `data:` line is JSON. The events are dispatched by `w()`:

`ready` · `title` · `tool_start` · `tool_finish` · `rag_start` · `rag_finish`
· `message_start` · **`message_chunk`** (token stream, `content` field) ·
`message_tool_call_delta` · `message_tool_calls` · `message_finish` · `finish`
(includes `model_name` for routing) · `compress_start/end` · `trigger_retry` ·
`trigger_fallback` · `usage` · `ttft` · `close` · `error` · `cancel`.

## Troubleshooting

- **`HTTP 401`** — cookies missing or expired. Re-run `script/extract_cookies.ps1`
  and `init-cookies`.
- **`HTTP 493`** — server's version gate. Edit `TABBIT_VERSION` in
  `tabbit_client.py` to match the running Tabbit's version
  (e.g. `1.1.39(10101039)`). Get the build number from
  `D:\Software\Tabbit\Application\1.1.39.0\1.1.39.0.manifest` or run Tabbit
  with `--remote-debugging-port=9222` and check `chrome://version`.
- **`HTTP 499`** — sign-key rotated server-side. The client auto-refreshes
  and retries; if it still fails, the literal key in the source may be
  outdated — run `python tabbit_client.py probe` to fetch the current key.
- **`HTTP 422`** — the request body schema has changed between Tabbit
  versions. Run `python tabbit_client.py probe` to see the server's
  validation error, then adjust `build_chat_body()`.

## Files

| File                  | Purpose                                              |
|----------------------|------------------------------------------------------|
| `tabbit_client.py`   | The client (`models`, `whoami`, `chat`, `probe`).    |
| `script/extract_cookies.ps1`| CDP-based cookie extractor (launches Tabbit for you).|
| `tabbit_config.json` | Cookies + base URL. Created by `init-cookies`.       |
| `cookies.txt`        | Raw cookie string written by `script/extract_cookies.ps1`.  |
| `REVERSE_ENGINEERING.md` | Full RE knowledge base — **read this next**.     |
| `captured_request.json` | The real `/api/v1/chat/completion` request captured via CDP. |
| `script/auto_send_and_capture.ps1` | Script that drove the Tabbit UI to capture that request. |
