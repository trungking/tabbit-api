# capture_chat_send.ps1
# Patches window.fetch in the running Tabbit page so that the next /chat/send
# call is logged (URL, headers, body) to window.__capturedChatSend, then
# triggers a minimal chat from within the page so the request goes out with
# Tabbit's real cookies/headers.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Get-TabbitPage {
    return (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) |
        Where-Object { $_.url -match "web.tabbit.ai/session" -or $_.url -match "web.tabbit.ai/chat" -or $_.url -match "web.tabbit.ai/panel" } |
        Select-Object -First 1
}

Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

function Invoke-Cdp {
    param(
        [Parameter(Mandatory)] $Page,
        [Parameter(Mandatory)] [string]$Method,
        [hashtable]$Params = @{},
        [int]$Id = 1,
        [int]$TimeoutSec = 15
    )
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))
    $ws.ConnectAsync($Page.webSocketDebuggerUrl, $cts.Token).Wait()
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw "WebSocket failed to open"
    }
    $body = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    [void]$ws.SendAsync(
        [ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true, $cts.Token)
    $buf = New-Object byte[] 131072
    $seg = [ArraySegment[byte]]::new($buf)
    $json = ""
    $end = $false
    while (-not $end) {
        $r = $ws.ReceiveAsync($seg, $cts.Token).Result
        $json += [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
        $end = $r.EndOfMessage
    }
    [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
    return $json | ConvertFrom-Json
}

$page = Get-TabbitPage
if (-not $page) { Write-Error "No tabbit.ai page open." }
Write-Host "Using page: $($page.url)"

# Step 1: install a fetch sniffer that records chat/send calls
$install = @"
(function(){
  if (window.__chatSendHooked) return 'already hooked';
  window.__capturedChatSend = null;
  const origFetch = window.fetch;
  window.fetch = function(input, init){
    try {
      const url = (typeof input === 'string') ? input : (input && input.url);
      if (url && url.indexOf('/chat/send') !== -1) {
        const headers = {};
        const h = (init && init.headers) || (input && input.headers) || {};
        if (h instanceof Headers) h.forEach((v,k)=>headers[k]=v);
        else if (Array.isArray(h)) h.forEach(([k,v])=>headers[k]=v);
        else Object.assign(headers, h || {});
        let body = (init && init.body) || (input && input.body);
        if (body && typeof body === 'string') {
          try { body = JSON.parse(body); } catch(e){}
        }
        window.__capturedChatSend = { url, method: (init && init.method) || 'GET', headers, body };
      }
    } catch(e){}
    return origFetch.apply(this, arguments);
  };
  window.__chatSendHooked = true;
  return 'installed';
})()
"@

$r1 = Invoke-Cdp -Page $page -Method "Runtime.evaluate" -Params @{ expression = $install; returnByValue = $true } -Id 1
Write-Host "Hook install: $($r1.result.result.value)"

# Step 2: trigger a minimal /chat/send from the page itself (inherits cookies + UA + headers)
$trigger = @"
(async function(){
  try {
    const r = await fetch('/chat/send', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache'
      },
      body: JSON.stringify({input: 'hi'}),
      credentials: 'include'
    });
    const text = await r.text();
    return JSON.stringify({status: r.status, headers: Object.fromEntries(r.headers.entries()), bodyPreview: text.slice(0, 500)});
  } catch(e) {
    return JSON.stringify({error: String(e)});
  }
})()
"@

Write-Host "`nTriggering /chat/send from inside the page (with real cookies)..."
$r2 = Invoke-Cdp -Page $page -Method "Runtime.evaluate" -Params @{ expression = $trigger; awaitPromise = $true; returnByValue = $true } -Id 2 -TimeoutSec 30
Write-Host "Trigger result:"
$r2.result.result.value | ConvertFrom-Json | ConvertTo-Json -Depth 5

# Step 3: pull the captured request
Start-Sleep -Milliseconds 500
$r3 = Invoke-Cdp -Page $page -Method "Runtime.evaluate" -Params @{ expression = "JSON.stringify(window.__capturedChatSend||null)"; returnByValue = $true } -Id 3
Write-Host "`n=== CAPTURED REQUEST ===" -ForegroundColor Green
if ($r3.result.result.value -eq "null") {
    Write-Host "No capture (the request may not have gone through fetch)."
} else {
    $cap = $r3.result.result.value | ConvertFrom-Json
    Write-Host "URL: $($cap.url)"
    Write-Host "Method: $($cap.method)"
    Write-Host "`nHEADERS:" -ForegroundColor Yellow
    $cap.headers.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $v = "$($_.Value)"
        if ($_.Name -match "cookie|authorization" -and $v.Length -gt 80) {
            $v = $v.Substring(0,40) + " ...[" + $v.Length + " chars]"
        }
        Write-Host ("  {0,-30} : {1}" -f $_.Name, $v)
    }
    Write-Host "`nBODY:" -ForegroundColor Yellow
    $cap.body | ConvertTo-Json -Depth 10
}
