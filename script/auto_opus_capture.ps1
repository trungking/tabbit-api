# auto_opus_capture.ps1 — fully automated, no manual steps.
# Switches the model to Opus via the UI, types "hi", presses Enter,
# and captures the /api/v1/chat/completion request the app sends.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$b = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(90))
$ws.ConnectAsync($b.webSocketDebuggerUrl, $cts.Token).Wait()

$script:idSeq = 100
function Send-Cdp {
    param([string]$Method, [hashtable]$Params = @{}, [string]$SessionId = "")
    $script:idSeq++
    $payload = @{ id = $script:idSeq; method = $Method; params = $Params }
    if ($SessionId) { $payload.sessionId = $SessionId }
    $json = $payload | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
    return $script:idSeq
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

# Pick chat page & attach
$page = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) |
    Where-Object { $_.type -eq "page" -and $_.url -match "session" } | Select-Object -First 1
Write-Host "Page: $($page.url)"
$id = Send-Cdp -Method "Target.attachToTarget" -Params @{ targetId = $page.id; flatten = $true }
$resp = Wait-Resp -Id $id
$sid = $resp.result.sessionId

# 1) Fresh fetch hook
$patch = @"
(function(){
  window.__cap = [];
  const of = window.fetch;
  window.fetch = function(input, init){
    try {
      const url = (typeof input === 'string') ? input : (input && input.url);
      if (url && url.indexOf('/api/v1/chat/completion') !== -1) {
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
  return 'fresh hook';
})()
"@
$resp = Eval -expr $patch -sid $sid
Write-Host "Patch: $($resp.result.result.value)"

# 2) Open the model selector by clicking the model button ("Default" label)
$openSelector = @"
(function(){
  // Find button containing "Default" or "Claude" or "GPT" text
  const btns = [...document.querySelectorAll('button')];
  const modelBtn = btns.find(b => {
    const t = (b.innerText||'').trim();
    return /^(Default|Claude|GPT|Gemini|GLM|DeepSeek|Kimi|Qwen|Doubao|MiniMax)/i.test(t)
        && b.offsetWidth > 0;
  });
  if (!modelBtn) return 'no model button';
  modelBtn.click();
  return 'clicked: ' + (modelBtn.innerText||'').trim();
})()
"@
$resp = Eval -expr $openSelector -sid $sid
Write-Host "Open selector: $($resp.result.result.value)"
Start-Sleep -Milliseconds 600

# 3) In the dropdown, find "Claude-Opus-4.8" and click it
$pickOpus = @"
(function(){
  const items = [...document.querySelectorAll('[role="option"], [role="menuitem"], li, button, div')]
    .filter(e => {
      const t = (e.innerText||'').trim();
      return t === 'Claude-Opus-4.8' || t.indexOf('Opus-4.8') !== -1;
    });
  if (items.length === 0) {
    // List visible candidates for debugging
    const cands = [...document.querySelectorAll('[role="option"], [role="menuitem"]')]
      .map(e => (e.innerText||'').trim()).filter(Boolean).slice(0, 30);
    return JSON.stringify({error:'no Opus option', candidates: cands});
  }
  items[0].click();
  return 'picked: ' + (items[0].innerText||'').trim();
})()
"@
$resp = Eval -expr $pickOpus -sid $sid
Write-Host "Pick Opus: $($resp.result.result.value)"
Start-Sleep -Milliseconds 500

# 4) Type "hi" into the composer and press Enter
$typeSend = @"
(function(){
  const box = document.querySelector('[role="textbox"]');
  if (!box) return 'no textbox';
  box.focus();
  const sel = window.getSelection();
  sel.removeAllRanges();
  const range = document.createRange();
  range.selectNodeContents(box);
  sel.addRange(range);
  document.execCommand('insertText', false, 'hi');
  // Press Enter
  const opts = {bubbles:true, cancelable:true, key:'Enter', code:'Enter', keyCode:13, which:13, view:window};
  box.dispatchEvent(new KeyboardEvent('keydown', opts));
  box.dispatchEvent(new KeyboardEvent('keypress', opts));
  box.dispatchEvent(new KeyboardEvent('keyup', opts));
  return 'sent';
})()
"@
$resp = Eval -expr $typeSend -sid $sid
Write-Host "Send: $($resp.result.result.value)"

# 5) Wait for the fetch hook to capture the request
Start-Sleep -Seconds 3
$deadline = (Get-Date).AddSeconds(20)
$captured = $null
while ((Get-Date) -lt $deadline) {
    $pollId = Send-Cdp -Method "Runtime.evaluate" -Params @{ expression = "JSON.stringify(window.__cap||[])"; returnByValue = $true } -SessionId $sid
    $resp = Wait-Resp -Id $pollId
    try {
        $reqs = $resp.result.result.value | ConvertFrom-Json
        if ($reqs.Count -gt 0) {
            $captured = $reqs | Select-Object -Last 1
            break
        }
    } catch {}
    Start-Sleep -Milliseconds 500
}

if ($captured) {
    Write-Host ""
    Write-Host "=== CAPTURED ===" -ForegroundColor Green
    Write-Host "URL: $($captured.url)"
    Write-Host "Method: $($captured.method)"
    Write-Host ""
    Write-Host "HEADERS:" -ForegroundColor Yellow
    $captured.headers.PSObject.Properties | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,-32} : {1}" -f $_.Name, $_.Value)
    }
    Write-Host ""
    Write-Host "BODY:" -ForegroundColor Yellow
    if ($captured.body) {
        $captured.body | ConvertTo-Json -Depth 10
    }
    $captured | ConvertTo-Json -Depth 10 | Out-File (Join-Path $ProjectRoot "opus_capture.json")
} else {
    Write-Host "[!] No request captured." -ForegroundColor Red
}

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
