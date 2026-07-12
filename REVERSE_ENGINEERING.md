# Tabbit — Reverse Engineering Knowledge Base

Complete technical dump of everything reverse-engineered from Tabbit so future
sessions can pick up where we left off without re-discovering it.

**Target product:** Tabbit browser (Chromium PWA wrapper by Meituan)
**App path (local):** `D:\Software\Tabbit\Application\Tabbit.exe`
**App version analyzed:** 1.1.39.0
**Date analyzed:** 2026-06-22

---

## 1. Application architecture

| Layer | What it is | Location |
|------|------------|----------|
| Shell | Stock Chromium runtime (~285 MB) | `Application\1.1.39.0\Tabbit.dll` |
| Launcher | `chrome_proxy.exe`-style stub | `Application\Tabbit.exe` |
| Web frontend | Next.js (App Router) PWA | `https://web.tabbit.ai` (overseas) / `https://web.tabbit.com` (CN) |
| CDN (JS/CSS) | `cdn.tabbit.ai/web-prod/_next/static/...` | public, no auth |
| Backend proxy | Same origin (`web.tabbit.ai`) under `/proxy/...`, `/api/...`, `/chat/...` | requires session cookie |
| Native bridge | Bundled Chrome extension `nmbemfeekdkfhjikjegnegkndcehpfej` | exposes `chrome.tabChatExt`, `chrome.tabContentExtractor` |
| Telemetry | Sentry (`sentry.tabbitbrowser.com/3`), Aegis SDK (`aegis-web-sdk.67d0c988.js`) | |
| Maker | **Meituan** (`km.sankuai.com`, `tabai-test.meituan.com`) | confirmed via env config |

**Domain family** (from chunk `9219`'s `N2` table):

```
tabbitAi:            tabbit.ai           (overseas apex)
tabbitBrowser:       tabbitbrowser.com
tabbitCn:            tabbit.com          (CN apex)
tabbitCnLegacy:      tabbit-ai.com       (CN legacy - cdn still uses this)
tabbitSkillsCn:      tabbitskills.com
tabbitSkillsOverseas:tabbitskills.ai
meituanTest:         tabai-test.meituan.com
meituanTestSg:       tab-browser-test-sg.meituan.com
localhost:           localhost:3000
```

Geo resolution (`l1()` in chunk `9219`): hostname matches the overseas set →
`"overseas"`, otherwise `"domestic"`. `localhost`/`127.0.0.1` are treated as
overseas.

---

## 2. Backend API surface

All paths are relative to `https://web.tabbit.ai` unless noted. `credentials:
"include"` is set on every call (cookie auth).

### Public (no auth)

| Method | Path | Returns |
|--------|------|---------|
| GET | `/chat/sign-key` | plain-text HMAC key (default literal `f8d0e6a73f8d4b1a9c3d2e1f9a4b7c6d`) |
| GET | `/proxy/v1/model_config/models?scene=chat&a={0\|1}` | model catalog (21 entries) |
| GET | `/api/v1/prompts/plaza/list?...` | public skills/prompts plaza |
| GET | `/api/v1/prompts/{id}` | prompt detail |
| GET | `/api/v1/prompts/plaza/share/{code}` | shared prompt |
| GET | `/api/v1/prompts/plaza/author/{author}` | author's prompts |

### Authenticated (return 401 without valid session)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/v0/user/base-info` | current user info |
| POST | `/api/v0/feedback` | user feedback (405 if GET) |
| GET | `/api/v1/chat/session/...` | chat session metadata |
| POST | `/api/v1/chat/session/fork` | fork a parallel branch |
| POST | **`/chat/send`** | **the AI call — SSE streaming response** |
| POST | `/proxy/v0/chat/stop/` | stop an in-flight turn |
| GET | `/proxy/v1/model_config/models` | (same as public but cookie-aware) |
| POST | `/proxy/v1/prompts/workflow/save` | save a workflow skill |
| * | `/proxy/mcp/...` | MCP server proxying (JSON-RPC) |
| * | `/proxy/v0/docs/...` | collaborative docs API |
| * | `/proxy/v0/bookmarks/create_bookmark_summary` | AI bookmark summary |
| * | `/api/commerce/activity/v1/...` | newbie/invite/lottery activities |
| * | `/api/commerce/activity/v2/invitation/...` | invitation v2 |
| * | `/api/commerce/pet/v1/...` | desktop pet feature |
| * | `/api/commerce/lottery/v1/...` | lottery |
| * | `/api/commerce/reward/v1/card-records` | reward cards |
| POST | `/proxy/v0/oauth/send-verification-code` | SMS code (body: `{uuid,platform:"1",version:"",app:"1000",mobile}`) |
| POST | `/proxy/v0/oauth/login` | SMS login (body: same + `smsCode`) |
| POST | `/proxy/v0/oauth/third-party-login` | OAuth (body: `{id_token,select_by,type:1}`) |

### Auth-identifying cookies (revealed by 401 `Set-Cookie` clear headers)

```
token
user_id
expires_in
next-auth.session-token     <- NextAuth.js session
```

All four are needed for `/chat/send`. `next-auth.session-token` is the primary
auth; the others are derived/user-info.

---

## 3. `/api/v1/chat/completion` — the AI call

### Important correction

**The real chat endpoint is `/api/v1/chat/completion`, NOT `/chat/send`.**

`/chat/send` is referenced in chunk `7978` but the production Tabbit UI no
longer uses it. We discovered this by patching `window.fetch` inside the
running Tabbit page via CDP and capturing a real send.

**Version gate:** the server requires an `x-req-ctx` header that base64-
encodes the Tabbit browser version (e.g. `MS4xLjM5KDEwMTAxMDM5KQ==` decodes
to `1.1.39(10101039)`). Without it the server returns HTTP `493` with body
`{"code":493,"action":"update_version",...}` even when cookies + signing are
valid.

### Real captured request (2026-06-22)

```http
POST /api/v1/chat/completion HTTP/1.1
Host: web.tabbit.ai
Content-Type: application/json
Accept: text/event-stream
Cache-Control: no-cache
trace-id: <uuid4>
x-req-ctx: MS4xLjM5KDEwMTAxMDM5KQ==      # base64("1.1.39(10101039)")
unique-uuid: <uuid4>
x-timestamp: <ms epoch>
x-nonce: <hex hmac>
x-signature: <random16 hex>
Cookie: token=...; user_id=...; expires_in=...; next-auth.session-token=...

{
  "chat_session_id": "60b6968f-f2da-49ee-9136-8413f075e4f1",
  "message_id": null,
  "content": "What is 2+2?",
  "selected_model": "Default",
  "parallel_group_id": null,
  "task_name": "chat",
  "agent_mode": false,
  "metadatas": {"html_content": "<p>What is 2+2?</p>"},
  "references": [],
  "entity": {
    "key": "d41d8cd98f00b204e9800998ecf8427e",   // MD5 of empty bytes
    "extras": {"type": "tab", "url": ""}
  }
}
```

### Request

```http
POST /api/v1/chat/completion HTTP/1.1
Host: web.tabbit.ai
Content-Type: application/json
Accept: text/event-stream
Cache-Control: no-cache
trace-id: <uuid4>
x-req-ctx: <base64 of "X.Y.Z(buildnum)">    # version gate
unique-uuid: <uuid4>
x-timestamp: <ms epoch>
x-nonce: <hex hmac>
x-signature: <random16 hex>
Cookie: token=...; user_id=...; expires_in=...; next-auth.session-token=...

<JSON body>
```

### HMAC signing scheme (verified against server)

**Source:** chunk `7978-28728a0635c9f673.js`, function `y()` + `p()` + `f()`.
The default literal key is exposed in the JS:

```js
let l = "f8d0e6a73f8d4b1a9c3d2e1f9a4b7c6d";
```

**Algorithm** (per request, computed over the exact bytes sent as body):

```text
timestamp   = str(int(time.time() * 1000))           # ms epoch
random      = secrets.token_hex(16)                    # called (0,a.l)() in JS
bodyHash    = sha256(body_bytes).hexdigest()
toSign      = f"{timestamp}.{random}.{bodyHash}"
nonce       = hmac_sha256(key=signKey, msg=toSign).hexdigest()
signKey     = fetched from GET /chat/sign-key (returns plain text)
              OR the literal default if fetch fails

Headers added:
    x-timestamp = timestamp
    x-nonce     = nonce
    x-signature = random
    x-req-ctx   = base64(TABBIT_VERSION)      # version gate
    unique-uuid = uuid4()
```

**Verification:** Python implementation produces signatures the server
accepts. With valid cookies + signing + `x-req-ctx`, the server streams
SSE tokens successfully.

**Retry on key rotation:** if server returns HTTP `499`, the JS client
refetches the sign-key from `/chat/sign-key` and retries the request once.
(Our client does the same.)

### Request body schema (verified)

```js
{
  chat_session_id: string | null,   // null starts a fresh session
  message_id:      null,            // server assigns
  content:         string,          // plain text user message
  selected_model:  string,          // e.g. "Default", "GLM-5.2"
  parallel_group_id: null,          // for multi-model mode
  task_name:       "chat",          // or other task types
  agent_mode:      false,           // true enables tool use
  metadatas: {
    html_content: "<p>...</p>"      // HTML version of content
  },
  references:      [],              // attached tabs/files
  entity: {
    key: "d41d8cd98f00b204e9800998ecf8427e",   // md5(b"")
    extras: { type: "tab", url: "" }
  }
}
```

**Live confirmation:** this body shape produces real streaming replies from
GLM-5.2, DeepSeek-V3.2, and Default models on 2026-06-22.

### Response: SSE event protocol

Each `data:` line is JSON. Dispatched by function `w()` in `7978-...js`. The
set `m` of "durable envelope" event types (from `Object.values({...})`):

| Event | Payload fields (observed/inferred) | Meaning |
|-------|----------|---------|
| `ready` | `{...}` | stream established |
| `title` | `{title}` | conversation title generated |
| `tool_start` | `{tool_id, tool_name, input}` | tool call begins |
| `tool_finish` | `{tool_id, output}` | tool call ends |
| `rag_start` | `{...}` | RAG retrieval begins |
| `rag_finish` | `{references}` | RAG retrieval ends |
| `message_start` | `{message_id}` | LLM message begins |
| **`message_chunk`** | `{content: "..."}` | **token stream delta** |
| `message_tool_call_delta` | `{...}` | streaming tool-call args |
| `message_tool_calls` | `{tool_calls: [...]}` | complete tool calls |
| `message_finish` | `{...}` | LLM message ends |
| `finish` | `{model_name, usage}` | **turn done; reveals routed model** |
| `compress_start`/`compressing`/`compress_end` | | context compression |
| `trigger_retry` | | backend asks client to retry |
| `trigger_fallback` | | backend switched models |
| `usage` | `{total_tokens, ...}` | token usage |
| `ttft` | `{ms}` | time to first token |
| `update` | | generic state update |
| `task_update` | | background task progress |
| `close` | | stream closed cleanly |
| `error` | `{error, details, status, traceId}` | error |
| `cancel` | | user-initiated cancel |

**Durable envelope** events carry an ordering tuple for replay:
`turn_id`, `chat_session_id`, `client_turn_id`, `event_id`, `biz_type`,
`epoch`, `seq`, `created_at`, `status`, `terminal_reason`.

The `finish` event's `model_name` is what reveals which underlying LLM served a
parallel/MOA-routed turn (`onParallelModelFinish`).

---

## 4. Models (snapshot 2026-06-22, scene=chat, no MOA)

21 entries. Categories: `free_unlimited`, `free_metered`, `premium_only`.

| display_name | access | thinking | images |
|---|---|---|---|
| Default | free_unlimited | no | yes |
| GLM-5.2 | free_metered | yes | no |
| MiniMax-M3 | free_metered | yes | yes |
| Claude-Opus-4.8 | premium_only | yes | yes |
| Gemini-3.5-Flash | premium_only | no | yes |
| GPT-5.5 | premium_only | no | yes |
| DeepSeek-V4-Pro | free_metered | yes | no |
| DeepSeek-V4-Flash | free_metered | yes | no |
| Claude-Opus-4.7 | premium_only | yes | yes |
| Kimi-K2.6 | free_metered | yes | yes |
| GLM-5.1 | free_metered | yes | yes |
| GPT-5.4 | premium_only | yes | yes |
| GPT-5.2-Chat | free_metered | yes | yes |
| Gemini-3.1-Pro | premium_only | yes | yes |
| Claude-Sonnet-4.6 | premium_only | yes | yes |
| Claude-Haiku-4.5 | free_metered | yes | yes |
| MiniMax-M2.7 | free_metered | yes | no |
| DeepSeek-V3.2 | free_metered | no | yes |
| Kimi-K2.5 | free_metered | yes | yes |
| Qwen3.5-Plus | free_metered | yes | yes |
| Doubao-Seed-1.8 | free_metered | yes | yes |

The `Default` model (sort_order 1, `free_unlimited`) is the only one usable
without a paid account, and routes server-side to whichever base model Tabbit
has chosen (unknown — possibly rotates).

The model list is **only metadata** — clients reference models by
`display_name`. The actual mapping to vendor API keys lives server-side.

---

## 5. Authentication flows

**Source:** chunk `app/login/page-f5ea128a2a528d03.js`.

### SMS (phone) login — most common in CN

```http
POST /proxy/v0/oauth/send-verification-code
Content-Type: application/json
{"uuid":"<device-uuid>","platform":"1","version":"","app":"1000","mobile":"<phone>"}
```

Response may include `data.verifyUrl` + `data.requestCode` triggering the
**Yoda captcha** (`window.YodaSeed`) — Meituan's anti-bot challenge. Solving
the captcha is required before the SMS is sent.

```http
POST /proxy/v0/oauth/login
Content-Type: application/json
{"uuid":"...","platform":"1","version":"","app":"1000",
 "mobile":"<phone>","smsCode":"<6-digit>"}
```

On success: server sets `next-auth.session-token` + derived cookies.

### Google OAuth (overseas)

```http
POST /proxy/v0/oauth/third-party-login
Content-Type: application/json
{"id_token":"<jwt>","select_by":"...","type":1}
```

`googleClientId` from env: `448526856882-gks4gsvgspqkcdt8jsql5b5en0mk3v15.apps.googleusercontent.com`

### MOA certificate (Meituan employees)

`checkMoaCertificate()` (in `7978`) sends `CHECK_MOA_CERTIFICATE` via the
extension bridge; result cached for 5 minutes. When true, the `a=1` flag in
`/proxy/v1/model_config/models` unlocks the internal Meituan model set.

---

## 6. Chrome extension bridge

The bundled extension ID **`nmbemfeekdkfhjikjegnegkndcehpfej`** is the bridge
between the web UI and Chromium/native capabilities.

**Source:** chunk `9219-...js`, function `n()` (export `mG`) and module
`6262` constants.

```js
chrome.runtime.sendMessage(
  "nmbemfeekdkfhjikjegnegkndcehpfej",
  {type, data, timestamp: Date.now()}
)
```

Known message types (from `Ol` enum, chunk `7978`/`9219`):

- `CHECK_MOA_CERTIFICATE`
- `SCREENSHOT` (used by `takeScreenshotAndUpload`)
- various tab/content extraction messages

Other native APIs hung off `chrome`:

- `chrome.tabChatExt` — sidebar/chat panel control
- `chrome.tabContentExtractor` — extract current page content for context
- `chrome.tabWindowExt.getTabSidePanelWindow`

Channel IDs (constants `c3`, `cS` in module `26830`):

```
c3 = "nmbemfeekdkfhjikjegnegkndcehpfej"   // extension ID
cS = "tab-extension-chat"                   // port name (chrome.runtime.connect)
Q9 = 60000                                  // default timeout (ms)
MN = 1000
aE = 5                                      // max retries
```

---

## 7. Frontend bundle map

Build: Next.js App Router, served from `cdn.tabbit.ai/web-prod/_next/`.

### Chunk index (webpack runtime `webpack-b54a38cd6630df0a.js`)

| File | Role |
|------|------|
| `webpack-b54a38cd6630df0a.js` | runtime, chunk loader |
| `main-app-0179325809bf280d.js` | Next.js App Router bootstrap |
| `polyfills-42372ed130431b0a.js` | browser polyfills |
| `1050-09aa694e37b9cf3f.js` | route table, navigation |
| `8875-833239cca888825b.js` | Next.js core (RSC, routing, fetch) |
| `10077218-63d36fb1e3747921.js` | vendor lib (React/sentry) |
| `9219-dc535079a43b88f9.js` | **extension bridge, env config (`P.U`), domains (`N2`)** |
| `7978-28728a0635c9f673.js` | **`/chat/send` client + signing + SSE decoder + auth/user APIs** |
| `584-88a5c38224152ab2.js` | **chat UI state machine, payload assembly, session fork** |
| `9603-108e6f92d2e0874c.js` | chat composer + skill chips |
| `app/login/page-f5ea128a2a528d03.js` | **login page (SMS, Google, captcha)** |
| `app/skills/page-8624aaf8643699f9.js` | skills marketplace |
| `app/mcp-settings/page-3a5bd8e1a9c01c27.js` | MCP servers config |
| `app/layout-3acdf43c8b30115c.js` | root layout |
| `app/page-b0d0188ae792da70.js` | homepage (newtab) |
| `runtime-scripts/aegis-web-sdk.67d0c988.js` | Meituan telemetry SDK |
| `runtime-scripts/chrome-theme-init.c173e709.js` | theme injection |
| `runtime-scripts/emergency-guard.634a7469.js` | crash/freeze watchdog |

Webpack chunk-id → filename map (from `i.u()` in the runtime) also references
these not-yet-downloaded chunks: `6979-5da355843568946f.js`,
`8441-4e609b2e1054ad42.js`, `6201-279e81a8bd9b0b1f.js`, `6903-f734bda22bef55ee.js`,
`9dc5bde5-81c808db8fc10db3.js`, `2a38b32a-974bff81b3bc2d79.js`,
`2532d1eb-fa73a4b0f7c8ef94.js`, `1610c81e-e4b8ee4053858b85.js`, etc.

**Downloaded copies** of all chunks above live at:
`C:\Users\vhctr\AppData\Local\Temp\opencode\tabbit_chunks\`

### Runtime env (`P.U`)

Inline in chunk `2549-c5c825fc5cec7af6.js` (escaped JSON, key: `P.U`):

```json
{
  "durableChatCurrentTurnRecoveryEnabled": false,
  "googleClientId": "448526856882-gks4gsvgspqkcdt8jsql5b5en0mk3v15.apps.googleusercontent.com",
  "sentryDsn": "https://4a5c74385c227d3ba012317b37a9e6c5@sentry.tabbitbrowser.com/3",
  "sentryOrg": "...",
  "sentryProject": "...",
  "sentryUrl": "...",
  "sentryEnabled": false,
  "aegisIdDomestic": "...",
  "aegisIdOverseas": "...",
  "plazaOrigin": "...",
  "gaiaOrigin": "..."
}
```

---

## 8. What's known vs. unknown

### Known (high confidence)

- ✅ Real endpoint: `/api/v1/chat/completion` (NOT `/chat/send`)
- ✅ **Version gate**: `x-req-ctx: base64("1.1.39(10101039)")` header required
- ✅ **`unique-uuid` header** required per request
- ✅ Sign scheme + key — verified against live server with real chat replies
- ✅ Chat body schema — captured live from running Tabbit UI
- ✅ All endpoints and their auth requirements
- ✅ SSE event names + their semantics
- ✅ Cookie names required for auth
- ✅ Model catalog (21 entries) — multiple models tested working
- ✅ Extension ID and bridge protocol
- ✅ Login flows (SMS, Google OAuth)

### Unknown / TODO for next session

- ❌ Yoda captcha solving (only matters if we script SMS login instead of
  cookie reuse).
- ❌ MCP `/proxy/mcp/...` JSON-RPC envelope shape.
- ❌ Image upload flow (presigned URL → S3-like?).
- ❌ Browser-use agent tool protocol (`tool_start`/`tool_finish` payload
  shapes, `agent_mode: true`).
- ❌ `references` array shape for tab/file attachments.
- ❌ Long-poll/durable-event replay protocol (for resuming an interrupted
  stream — see `replay_start`, `run_queued` events).
- ❌ Multi-model mode: when does `parallel_group_id` get set instead of null?
- ❌ What task_name values exist beyond `"chat"` (e.g. for skills/workflows)?
- ❌ **Why do some `premium_only` models (Gemini-3.5-Flash, Claude-Sonnet-4.6)
  still return 492 even after the default-browser entitlement is flipped,
  while others (Claude-Opus-4.8, GPT-5.5) work?** Possibly a per-model daily
  quota or a higher subscription tier.

## 12b. The default-browser / premium entitlement flow

**Discovery:** the user said "premium only requires setting browser as
default, must be client-side". Correct — Tabbit's C++ code reports
`is_default_browser: true` to `/api/v0/report/upsert-user-device-info` once
daily, and the server flips an account-level entitlement in response.

**Source:** `D:\Software\Tabbit\Application\1.1.39.0\Tabbit.dll` contains
log strings:
```
Reporting device info: device_type= , default_browser= , is_default= , user_id=
Device info already reported today, skipping
Detected Tab Browser became default (changed from ' '), reporting device info
%s://%s/api/v0/report/upsert-user-device-info
tab_device_info.last_report_date
```

**Endpoint:** `POST /api/v0/report/upsert-user-device-info` (authenticated
via session cookies, not signed).

**Body shape (inferred from C++ proto schema, not yet captured live):**
```json
{
  "device_id": "...",
  "device_name": "...",
  "platform": "win",
  "os_version": "...",
  "browser_version": "...",
  "tabbit_version": "1.1.39",
  "user_agent": "...",
  "default_browser": "...",          // current default browser name
  "is_default_browser": true,        // the magic flag
  "sparkle_version": "...",
  "screen_resolution": {"width":..., "height":...},
  "timezone": "...",
  "language": "en-US"
}
```

**Effect on chat client:**
- Once the server receives `is_default_browser: true`, the response sets two
  new cookies: `SAPISID` and `managed`. These (plus the original 5 cookies)
  are what the chat endpoint needs for premium models.
- Without `SAPISID`/`managed`, calling Opus/GPT-5.5 from Python returns HTTP
  `492 premium_only`.
- With them, **Claude-Opus-4.8 and GPT-5.5 work from Python**, but
  Claude-Sonnet-4.6 and Gemini-3.5-Flash still return 492 (likely a higher
  tier or daily quota — TODO).

**To trigger the flow:** the easiest path is to actually click "Set as
default" inside Tabbit once. The C++ code handles the registry check and
fires the device-info report automatically. After that, re-extract cookies
(via `script/extract_cookies.ps1`) and the Python client will have the right tokens.

**TODO for next session:** capture the actual `/upsert-user-device-info`
POST body and response via CDP (we attempted this with
`capture_device_report.ps1` but the CDP listener got disconnected before
the request fired). Once captured, we can write a `claim-premium`
subcommand that replays it from Python without needing the user to click
anything in the Tabbit UI.

---

## 9. Repro: how to re-extract knowledge if the bundle changes

1. **Find the new PWA URL.** Open `D:\Software\Tabbit\Application\Tabbit.exe`
   with `--remote-debugging-port=9222` and check the address bar.
2. **Pull the homepage HTML** to list all current chunk URLs:
   ```powershell
   Invoke-WebRequest https://web.tabbit.ai/ -UseBasicParsing
   ```
3. **Find webpack runtime** (`webpack-<hash>.js`) — it contains the chunk-id →
   filename map (`i.u()` function).
4. **Grep chunks for these anchors:**
   - `/chat/send` → chat client
   - `sign-key` or the literal `f8d0e6a73f8d4b1a9c3d2e1f9a4b7c6d` → signing
   - `sendMessage` / `createChatClient` → chat SDK
   - `EventSource` / `text/event-stream` → SSE
   - `chrome.runtime.sendMessage` → extension bridge
5. **Probe live endpoints** with curl/PowerShell — most return useful errors.

---

## 10. Working artifacts

| Path | What |
|------|------|
| `D:\Software\Tabbit\tabbit_api\tabbit_client.py` | Our working client |
| `D:\Software\Tabbit\tabbit_api\script\extract_cookies.ps1` | CDP cookie extractor |
| `D:\Software\Tabbit\tabbit_api\tabbit_config.json` | Cookies (after `init-cookies`) |
| `C:\Users\vhctr\AppData\Local\Temp\opencode\tabbit_chunks\` | All downloaded JS chunks |
| `C:\Users\vhctr\AppData\Local\Temp\opencode\tabbit_chunks\root\7978-28728a0635c9f673.js` | **Key chunk: chat client + signing** |
| `C:\Users\vhctr\AppData\Local\Temp\opencode\tabbit_chunks\root\584-88a5c38224152ab2.js` | **Chat UI / payload builder** |

---

## 11. Open questions / hypotheses

- Does `/api/v1/chat/completion` accept OpenAI-style `messages` array as a
  fallback, or only the flat `content` field?
- Is `entity.key` always `md5(b"")`, or does it depend on attached tab URL
  content?
- What's the difference between `chat_session_id: null` (fresh) and reusing
  a session? Does the server remember context across calls within a session?
- Does `agent_mode: true` with `task_name: "browser-use"` enable the
  browser-agent flow? Need to capture a real agent-mode request.
- Can we replay a `trigger_retry` or `trigger_fallback` event client-side, or
  are those purely server-internal signals?

---

## 12. How we cracked the 493 gate (debugging diary)

Initial Python client got 401 (no auth) → added cookies → got `401` resolved
but next blocker was HTTP `493`:

```json
{"message":"Your current browser version is outdated...",
 "code":493,"action":"update_version"}
```

This 493 happened **even when we ran `fetch('/chat/send', ...)` from inside
the Tabbit page itself** via CDP — so it wasn't a User-Agent / cookie problem.
Suspected something the SDK adds we hadn't seen.

**The breakthrough:** patched `window.fetch` inside the live Tabbit page with
`script/auto_send_and_capture.ps1`, typed into the contenteditable composer via
`document.execCommand('insertText', ...)`, dispatched Enter, and observed
that the **actual endpoint was `/api/v1/chat/completion`** (not `/chat/send`!)
with two extra headers:

- `x-req-ctx: MS4xLjM5KDEwMTAxMDM5KQ==` → base64 of `1.1.39(10101039)`
- `unique-uuid: <uuid4>`

Adding those + switching endpoint → real streaming replies from GLM-5.2,
DeepSeek-V3.2, and Default. Capture saved at `captured_request.json`.

**Lesson:** when reverse-engineering an app whose bundle has stale code paths
(`7978` references `/chat/send` but the production UI hits
`/api/v1/chat/completion`), there is no substitute for capturing the live
request.

---

*Last updated: 2026-06-22 (post-493 fix). Update this file whenever you
discover new fields, event types, or endpoints.*
