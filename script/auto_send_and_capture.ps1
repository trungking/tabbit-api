# auto_send_and_capture.ps1
# Patches window.fetch, types a message into the Tabbit composer, clicks send,
# and captures the /chat/send request.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$b = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(60))
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
    [void]$ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
    return $myId
}
function Recv-Raw {
    $buf = New-Object byte[] 524288
    $seg = [ArraySegment[byte]]::new($buf)
    $r = $ws.ReceiveAsync($seg, $cts.Token).Result
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count) | ConvertFrom-Json
}
function Wait-Resp([int]$Id, [int]$Ms = 20000) {
    $dl = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $dl) {
        $m = Recv-Raw
        if ($m.id -eq $Id) { return $m }
    }
    throw "timeout id=$Id"
}
function Eval([string]$expr, [string]$sid = "", [int]$ms = 20000) {
    $id = Send-Cdp -Method "Runtime.evaluate" -Params @{ expression = $expr; returnByValue = $true; awaitPromise = $true } -SessionId $sid
    return Wait-Resp -Id $id -Ms $ms
}

# Pick page & attach
$page = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) |
    Where-Object { $_.type -eq "page" -and $_.url -match "session" } | Select-Object -First 1
Write-Host "Page: $($page.url)"
$id = Send-Cdp -Method "Target.attachToTarget" -Params @{ targetId = $page.id; flatten = $true }
$resp = Wait-Resp -Id $id
$sid = $resp.result.sessionId
Write-Host "Attached. sid=$sid"

$id = Send-Cdp -Method "Page.enable" -SessionId $sid; Wait-Resp -Id $id | Out-Null

# 1) Patch fetch
$patch = @"
(function(){
  if (window.__hook) return 'already';
  window.__cap = [];
  const of = window.fetch;
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
        window.__cap.push({ url, method:(init&&init.method)||'GET', headers, body, ts: Date.now() });
      }
    } catch(e){}
    return of.apply(this, arguments);
  };
  window.__hook = true;
  return 'ok';
})()
"@
$resp = Eval -expr $patch -sid $sid
Write-Host "Patch: $($resp.result.result.value)"

# 2) Focus the composer (role=textbox), clear it, type via execCommand
$typeScript = @"
(function(){
  const box = document.querySelector('[role="textbox"]');
  if (!box) return 'no textbox';
  box.focus();
  // clear existing content
  const sel = window.getSelection();
  sel.removeAllRanges();
  const range = document.createRange();
  range.selectNodeContents(box);
  sel.addRange(range);
  // execCommand insertText triggers React's onChange via input event
  const ok = document.execCommand('insertText', false, 'What is 2+2?');
  return JSON.stringify({focused:document.activeElement===box, text:box.innerText, execOk:ok});
})()
"@
$resp = Eval -expr $typeScript -sid $sid
Write-Host "Type result: $($resp.result.result.value)"

Start-Sleep -Milliseconds 500

# 3) Press Enter inside the contenteditable to submit (Tabbit's send shortcut)
# Method A: dispatch a real keydown Enter via the React event system
$enterScript = @"
(function(){
  const box = document.querySelector('[role="textbox"]');
  if (!box) return 'no textbox';
  box.focus();
  const opts = {bubbles:true, cancelable:true, key:'Enter', code:'Enter', keyCode:13, which:13, view:window};
  const kd = new KeyboardEvent('keydown', opts);
  const kp = new KeyboardEvent('keypress', opts);
  const ku = new KeyboardEvent('keyup', opts);
  const a = box.dispatchEvent(kd);
  const b = box.dispatchEvent(kp);
  const c = box.dispatchEvent(ku);
  return JSON.stringify({keydownNotCanceled:a, keypressNotCanceled:b, keyupNotCanceled:c, text:box.innerText});
})()
"@
$resp = Eval -expr $enterScript -sid $sid
Write-Host "Enter result: $($resp.result.result.value)"

Start-Sleep -Seconds 3

# 4) Read captured requests
$resp = Eval -expr "JSON.stringify(window.__cap||[])" -sid $sid
$cap = $resp.result.result.value | ConvertFrom-Json
Write-Host "`n=== Captured /chat/* requests ($($cap.Count)) ==="
$cap | ForEach-Object {
    Write-Host "  - $($_.method) $($_.url)"
    if ($_.body) {
        Write-Host "    body keys: $($_.body.PSObject.Properties.Name -join ', ')"
    }
}

# Show full /chat/send details if captured
$cs = $cap | Where-Object { $_.url -match "/chat/send" } | Select-Object -First 1
if ($cs) {
    Write-Host ""
    Write-Host "=== /chat/send details ===" -ForegroundColor Green
    Write-Host "URL: $($cs.url)"
    Write-Host "Method: $($cs.method)"
    Write-Host ""
    Write-Host "HEADERS:" -ForegroundColor Yellow
    $cs.headers.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $v = "$($_.Value)"
        if ($_.Name -match "cookie|authorization" -and $v.Length -gt 80) {
            $v = $v.Substring(0,40) + " ...[" + $v.Length + " chars]"
        }
        Write-Host ("  {0,-32} : {1}" -f $_.Name, $v)
    }
    Write-Host ""
    Write-Host "BODY:" -ForegroundColor Yellow
    if ($cs.body) {
        $cs.body | ConvertTo-Json -Depth 10
    } else {
        Write-Host "  (no body)"
    }
} else {
    Write-Host "`n[!] No /chat/send captured. Enter may not have submitted." -ForegroundColor Red
    # Try clicking send button
    Write-Host "Trying to find and click a send button..."
}

# Save full capture for later analysis
$cap | ConvertTo-Json -Depth 10 | Out-File (Join-Path $ProjectRoot "captured_request.json")

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
