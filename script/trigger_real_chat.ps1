# trigger_real_chat.ps1
# Patches the chat UI inside Tabbit to capture the next /chat/send request
# that the app itself sends, then prompts you to send a message.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

$b = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(120))
$ws.ConnectAsync($b.webSocketDebuggerUrl, $cts.Token).Wait()

$script:idSeq = 100
$pending = @{}   # id -> Hashtable Result

function Send-Cdp {
    param([string]$Method, [hashtable]$Params = @{}, [string]$SessionId = "")
    $script:idSeq++
    $myId = $script:idSeq
    $payload = @{ id = $myId; method = $Method; params = $Params }
    if ($SessionId) { $payload.sessionId = $SessionId }
    $json = $payload | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    [void]$ws.SendAsync(
        [ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true, $cts.Token)
    return $myId
}

function Recv-RawMessage {
    # Read one complete JSON message (CDP frames are self-contained).
    $buf = New-Object byte[] 524288
    $seg = [ArraySegment[byte]]::new($buf)
    $r = $ws.ReceiveAsync($seg, $cts.Token).Result
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count) | ConvertFrom-Json
}

function Wait-Response {
    param([int]$Id, [int]$TimeoutMs = 20000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $msg = Recv-RawMessage
        # store any response in pending; if it's ours, return it
        if ($msg.id) {
            if ($msg.id -eq $Id) { return $msg }
            # not ours; keep going
        }
        # ignore events for now
    }
    throw "timeout waiting for id=$Id"
}

# ---- Pick the chat page ----
$pages = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) |
    Where-Object { $_.type -eq "page" -and $_.url -match "tabbit.ai" }
$page = $pages | Where-Object { $_.url -match "session" } | Select-Object -First 1
if (-not $page) { $page = $pages | Select-Object -First 1 }
Write-Host "Using page: $($page.url)"

# ---- Attach to the page ----
$attachId = Send-Cdp -Method "Target.attachToTarget" -Params @{ targetId = $page.id; flatten = $true }
$resp = Wait-Response -Id $attachId
$sessionId = $resp.result.sessionId
Write-Host "Attached. sessionId=$sessionId"

# ---- Patch window.fetch ----
$patch = @"
(function(){
  if (window.__realChatHook) return 'already';
  window.__capturedRequests = [];
  const origFetch = window.fetch;
  window.fetch = function(input, init){
    try {
      const url = (typeof input === 'string') ? input : (input && input.url);
      if (url && url.indexOf('/chat/') !== -1) {
        const headers = {};
        const h = (init && init.headers) || (input && input.headers) || {};
        if (h instanceof Headers) h.forEach((v,k)=>headers[k]=v);
        else if (Array.isArray(h)) h.forEach(x=>headers[x[0]]=x[1]);
        else Object.assign(headers, h || {});
        let body = (init && init.body) || '';
        if (body && typeof body === 'string') {
          try { body = JSON.parse(body); } catch(e){}
        }
        window.__capturedRequests.push({
          kind:'fetch', url, method:(init&&init.method)||'GET',
          headers, body, ts: Date.now()
        });
      }
    } catch(e){}
    return origFetch.apply(this, arguments);
  };
  window.__realChatHook = true;
  return 'installed at ' + new Date().toISOString();
})()
"@

$evalId = Send-Cdp -Method "Runtime.evaluate" -Params @{ expression = $patch; returnByValue = $true } -SessionId $sessionId
$resp = Wait-Response -Id $evalId
Write-Host "Patch: $($resp.result.result.value)"

# ---- Prompt the user ----
Write-Host ""
Write-Host "=============================================================" -ForegroundColor Yellow
Write-Host "GO TO TABBIT NOW AND SEND A MESSAGE IN THE CHAT." -ForegroundColor Yellow
Write-Host "We'll poll for 60 seconds." -ForegroundColor Yellow
Write-Host "=============================================================" -ForegroundColor Yellow
Write-Host ""

$deadline = (Get-Date).AddSeconds(60)
$captured = $null
$lastCount = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $pollId = Send-Cdp -Method "Runtime.evaluate" -Params @{ expression = "JSON.stringify(window.__capturedRequests||[])"; returnByValue = $true } -SessionId $sessionId
    $resp = Wait-Response -Id $pollId
    try {
        $reqs = $resp.result.result.value | ConvertFrom-Json
    } catch {
        Write-Host "  (parse error, retrying)"
        continue
    }
    $chatSend = $reqs | Where-Object { $_.url -match "/chat/send" } | Select-Object -First 1
    if ($chatSend) {
        $captured = $chatSend
        break
    }
    if ($reqs.Count -gt $lastCount) {
        Write-Host "[i] Captured $($reqs.Count) /chat/* request(s) so far (urls:" ($reqs.url -join ', ') ")"
        $lastCount = $reqs.Count
    }
    Write-Host "." -NoNewline
}
Write-Host ""

if (-not $captured) {
    Write-Host "[!] No /chat/send was captured in 60s." -ForegroundColor Red
    Write-Host "Dumping all captured requests:"
    $pollId = Send-Cdp -Method "Runtime.evaluate" -Params @{ expression = "JSON.stringify(window.__capturedRequests||[], null, 2)"; returnByValue = $true } -SessionId $sessionId
    $resp = Wait-Response -Id $pollId
    Write-Host $resp.result.result.value
} else {
    Write-Host ""
    Write-Host "=== /chat/send CAPTURED ===" -ForegroundColor Green
    Write-Host "URL: $($captured.url)"
    Write-Host "Method: $($captured.method)"
    Write-Host ""
    Write-Host "HEADERS:" -ForegroundColor Yellow
    $captured.headers.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $v = "$($_.Value)"
        if ($_.Name -match "cookie|authorization" -and $v.Length -gt 80) {
            $v = $v.Substring(0,40) + " ...[" + $v.Length + " chars]"
        }
        Write-Host ("  {0,-32} : {1}" -f $_.Name, $v)
    }
    Write-Host ""
    Write-Host "BODY:" -ForegroundColor Yellow
    if ($captured.body) {
        $captured.body | ConvertTo-Json -Depth 10
    } else {
        Write-Host "  (no body)"
    }
}

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
