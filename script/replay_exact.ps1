# replay_exact.ps1
# 1. Hook fetch in the UI to save the EXACT body+headers of the next /completion request
# 2. Trigger an Opus send in the UI
# 3. Wait for it to succeed
# 4. Immediately replay the SAME headers+body from Python (requests lib)
# 5. Compare results

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$b = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(60))
$ws.ConnectAsync($b.webSocketDebuggerUrl, $cts.Token).Wait()

$seq = 1
function Send([string]$m, $p = @{}) {
    $script:seq++
    $body = @{ id = $script:seq; method = $m; params = $p } | ConvertTo-Json -Depth 20 -Compress
    $b = [System.Text.Encoding]::UTF8.GetBytes($body)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($b), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
    return $script:seq
}
function Recv() {
    $buf = New-Object byte[] 524288
    $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).Result
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count) | ConvertFrom-Json
}
function WaitId($id, $ms = 10000) {
    $dl = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $dl) { $m = Recv; if ($m.id -eq $id) { return $m } }
}

$page = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) | Where-Object { $_.type -eq "page" -and $_.url -match "session" } | Select-Object -First 1
$id = Send "Target.attachToTarget" @{ targetId = $page.id; flatten = $true }
$resp = WaitId $id
$sid = $resp.result.sessionId

# Install hook that saves the EXACT init object
$hook = @'
(function(){
  window.__lastInit = null;
  const cur = window.fetch;
  window.fetch = function(input, init){
    const url = typeof input === 'string' ? input : (input && input.url);
    if (url && url.indexOf('/api/v1/chat/completion') !== -1 && init) {
      const h = init.headers || {};
      const flat = {};
      if (h instanceof Headers) h.forEach((v,k)=>flat[k]=v);
      else if (Array.isArray(h)) h.forEach(x=>flat[x[0]]=x[1]);
      else Object.assign(flat, h||{});
      window.__lastInit = { headers: flat, body: init.body };
    }
    return cur.apply(this, arguments);
  };
  return 'ready';
})()
'@
$id = Send "Runtime.evaluate" @{ expression = $hook; returnByValue = $true; sessionId = $sid }
WaitId $id | Out-Null

# Trigger UI send
$trigger = @'
(function(){
  const box = document.querySelector('[role="textbox"]');
  box.focus();
  const sel = window.getSelection();
  sel.removeAllRanges();
  const range = document.createRange();
  range.selectNodeContents(box);
  sel.addRange(range);
  document.execCommand('insertText', false, 'hi');
  const opts = {bubbles:true, cancelable:true, key:'Enter', code:'Enter', keyCode:13, which:13, view:window};
  box.dispatchEvent(new KeyboardEvent('keydown', opts));
  box.dispatchEvent(new KeyboardEvent('keypress', opts));
  box.dispatchEvent(new KeyboardEvent('keyup', opts));
})()
'@
$id = Send "Runtime.evaluate" @{ expression = $trigger; sessionId = $sid }
WaitId $id 3000 | Out-Null
Start-Sleep -Seconds 3

# Read the captured init
$id = Send "Runtime.evaluate" @{ expression = "JSON.stringify(window.__lastInit)"; returnByValue = $true; sessionId = $sid }
$resp = WaitId $id
$captured = $resp.result.result.value | ConvertFrom-Json

if (-not $captured) {
    Write-Host "No request captured." -ForegroundColor Red
    exit 1
}

Write-Host "=== Captured UI request ===" -ForegroundColor Green
Write-Host "Headers:"
$captured.headers.PSObject.Properties | ForEach-Object { Write-Host "  $($_.Name): $($_.Value)" }
Write-Host "Body: $($captured.body)"

# Save to file for Python replay
$captured | ConvertTo-Json -Depth 5 | Out-File (Join-Path $ProjectRoot "replay_payload.json")

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)

# Now replay from Python IMMEDIATELY
Write-Host "`n=== Replaying from Python (curl_cffi with Chrome TLS) ===" -ForegroundColor Yellow
$env:PYTHONIOENCODING = "utf-8"
python (Join-Path $PSScriptRoot "replay.py")
