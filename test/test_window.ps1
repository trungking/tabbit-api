# test_window.ps1 - trigger UI send, then immediately fire fresh-signed Python request
$ErrorActionPreference = "Stop"
$page = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) | Where-Object { $_.type -eq "page" -and $_.url -match "session" } | Select-Object -First 1
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(30))
$ws.ConnectAsync($page.webSocketDebuggerUrl, $cts.Token).Wait()
function Eval([string]$expr) {
    $body = @{ id = 1; method = "Runtime.evaluate"; params = @{ expression = $expr; returnByValue = $true } } | ConvertTo-Json -Depth 10 -Compress
    $b = [System.Text.Encoding]::UTF8.GetBytes($body)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($b), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
    $buf = New-Object byte[] 131072
    $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).Result
    return ([System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count) | ConvertFrom-Json).result.result.value
}

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
Write-Host "Triggering UI send..."
[void](Eval $trigger)
Write-Host "Waiting 1s for UI request to land..."
Start-Sleep -Seconds 1

# IMMEDIATELY fire from Python
Write-Host "Firing fresh-signed Python request..."
[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
$env:PYTHONIOENCODING = "utf-8"
python (Join-Path $PSScriptRoot "test_fresh_sign.py")
