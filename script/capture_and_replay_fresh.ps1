# capture_and_replay_fresh.ps1
# Capture a fresh UI request, then immediately replay the exact bytes from Python.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
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

# Install fresh hook
$hook = @'
(function(){
  window.__cap = null;
  const cur = window.fetch;
  window.fetch = function(input, init){
    const url = typeof input === 'string' ? input : (input && input.url);
    if (url && url.indexOf('/api/v1/chat/completion') !== -1 && init) {
      const h = init.headers || {};
      const flat = {};
      if (h instanceof Headers) h.forEach((v,k)=>flat[k]=v);
      else if (Array.isArray(h)) h.forEach(x=>flat[x[0]]=x[1]);
      else Object.assign(flat, h||{});
      window.__cap = { headers: flat, body: init.body, url };
    }
    return cur.apply(this, arguments);
  };
  return 'fresh';
})()
'@
Eval $hook | Out-Null

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
  document.execCommand('insertText', false, 'test123');
  const opts = {bubbles:true, cancelable:true, key:'Enter', code:'Enter', keyCode:13, which:13, view:window};
  box.dispatchEvent(new KeyboardEvent('keydown', opts));
  box.dispatchEvent(new KeyboardEvent('keypress', opts));
  box.dispatchEvent(new KeyboardEvent('keyup', opts));
})()
'@
Eval $trigger | Out-Null
Start-Sleep -Seconds 4

$cap = Eval "JSON.stringify(window.__cap)"
if (-not $cap -or $cap -eq "null") {
    throw "No chat request was captured. Make sure a logged-in /session page is open."
}
$captured = $cap | ConvertFrom-Json
$required = @("x-timestamp", "x-nonce", "x-signature", "unique-uuid")
foreach ($name in $required) {
    if (-not $captured.headers.PSObject.Properties[$name]) {
        throw "Captured request is missing required header: $name"
    }
}

$capturePath = Join-Path $ProjectRoot "fresh_capture.json"
$configPath = Join-Path $ProjectRoot "tabbit_config.json"
[IO.File]::WriteAllText($capturePath, ($captured | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
$config = if (Test-Path $configPath) {
    [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
} else {
    [pscustomobject]@{ base_url = "https://web.tabbit.ai"; cookies = [pscustomobject]@{}; sign_key = $null }
}
$premiumSignature = [ordered]@{}
foreach ($name in $required) { $premiumSignature[$name] = $captured.headers.$name }
$config | Add-Member -NotePropertyName premium_signature -NotePropertyValue ([pscustomobject]$premiumSignature) -Force
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
Write-Host "Fresh premium token saved to tabbit_config.json."
[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
