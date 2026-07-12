# auto_trigger_chat.ps1
# Patches window.fetch, then triggers /chat/send through the UI by
# programmatically typing into the composer and clicking send.
# This bypasses the need for manual interaction.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

$b = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(120))
$ws.ConnectAsync($b.webSocketDebuggerUrl, $cts.Token).Wait()

$script:idSeq = 100
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
        if ($msg.id -eq $Id) { return $msg }
    }
    throw "timeout waiting for id=$Id"
}
function Cdp-Eval {
    param([string]$Expression, [string]$SessionId = "", [int]$TimeoutMs = 20000)
    $id = Send-Cdp -Method "Runtime.evaluate" -Params @{ expression = $Expression; returnByValue = $true; awaitPromise = $true } -SessionId $SessionId
    return Wait-Response -Id $id -TimeoutMs $TimeoutMs
}

# ---- Pick chat page ----
$pages = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) |
    Where-Object { $_.type -eq "page" -and $_.url -match "tabbit.ai" }
$page = $pages | Where-Object { $_.url -match "session" } | Select-Object -First 1
if (-not $page) { $page = $pages | Select-Object -First 1 }
Write-Host "Using page: $($page.url)"

# Attach
$id = Send-Cdp -Method "Target.attachToTarget" -Params @{ targetId = $page.id; flatten = $true }
$resp = Wait-Response -Id $id
$sessionId = $resp.result.sessionId
Write-Host "Attached. sessionId=$sessionId"

# Enable Page so we can use Input events
$id = Send-Cdp -Method "Page.enable" -SessionId $sessionId
Wait-Response -Id $id | Out-Null

# Step 1: patch window.fetch
$patch = @"
(function(){
  if (window.__realChatHook) return 'already';
  window.__capturedRequests = [];
  const origFetch = window.fetch;
  window.fetch = function(input, init){
    try {
      const url = (typeof input === 'string') ? input : (input && input.url);
      if (url) {
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
  return 'installed';
})()
"@
$resp = Cdp-Eval -Expression $patch -SessionId $sessionId
Write-Host "Patch: $($resp.result.result.value)"

# Step 2: Inspect the composer DOM
Write-Host "`n=== Inspecting chat composer DOM ==="
$inspect = @"
(function(){
  const out = {textareas:[], contentEditables:[], buttons:[], chatInputs:[]};
  document.querySelectorAll('textarea').forEach((t,i)=>{
    out.textareas.push({i, placeholder:t.placeholder, className:t.className.slice(0,80), rect: t.getBoundingClientRect().toJSON()});
  });
  document.querySelectorAll('[contenteditable="true"]').forEach((e,i)=>{
    out.contentEditables.push({i, className:e.className.slice(0,80), tag:e.tagName, rect: e.getBoundingClientRect().toJSON()});
  });
  document.querySelectorAll('button').forEach((b,i)=>{
    const aria = b.getAttribute('aria-label') || '';
    if (b.getBoundingClientRect().width > 0 && (aria.match(/send|submit/i) || b.className.match(/send|submit/i))) {
      out.buttons.push({i, aria, className:b.className.slice(0,80), rect: b.getBoundingClientRect().toJSON()});
    }
  });
  out.chatInputs = document.querySelectorAll('[class*="chatInput"],[class*="composer"],[class*="messageInput"],[data-testid*="chat"]').length;
  return JSON.stringify(out);
})()
"@
$resp = Cdp-Eval -Expression $inspect -SessionId $sessionId
$domInfo = $resp.result.result.value | ConvertFrom-Json
Write-Host "textareas: $($domInfo.textareas.Count)"
$domInfo.textareas | ForEach-Object { Write-Host "  [#$($_.i)] placeholder='$($_.placeholder)' class='$($_.className)'" }
Write-Host "contentEditables: $($domInfo.contentEditables.Count)"
$domInfo.contentEditables | ForEach-Object { Write-Host "  [#$($_.i)] tag=$($_.tag) class='$($_.className)'" }
Write-Host "send/submit buttons: $($domInfo.buttons.Count)"
$domInfo.buttons | ForEach-Object { Write-Host "  [#$($_.i)] aria='$($_.aria)' class='$($_.className)'" }
Write-Host "chatInput-like elements: $($domInfo.chatInputs)"

# Save DOM inspection for later
$domInfo | ConvertTo-Json -Depth 6 | Out-File (Join-Path $ProjectRoot "dom_inspection.json")

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
Write-Host "`nDone. DOM saved to dom_inspection.json"
