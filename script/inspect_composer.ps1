# inspect_composer.ps1
# Find the chat composer element in detail so we can trigger a real send.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$b = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5
Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

$page = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) |
    Where-Object { $_.type -eq "page" -and $_.url -match "session" } | Select-Object -First 1
Write-Host "Page: $($page.url)"

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromSeconds(20))
$ws.ConnectAsync($page.webSocketDebuggerUrl, $cts.Token).Wait()

function Eval([string]$expr) {
    $body = @{ id = 1; method = "Runtime.evaluate"; params = @{ expression = $expr; returnByValue = $true } } | ConvertTo-Json -Depth 10 -Compress
    $b = [System.Text.Encoding]::UTF8.GetBytes($body)
    [void]$ws.SendAsync([ArraySegment[byte]]::new($b), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
    $buf = New-Object byte[] 524288
    $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).Result
    $resp = [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count) | ConvertFrom-Json
    return $resp.result.result.value
}

# Comprehensive composer search
$inspect = @"
(function(){
  const out = {};
  // List ALL input-like elements regardless of visibility
  out.textareas = [...document.querySelectorAll('textarea')].map((t,i)=>({
    i, placeholder:t.placeholder, className:t.className.slice(0,120),
    parent: t.parentElement?.className?.slice(0,80),
    isVisible: t.offsetWidth>0||t.offsetHeight>0,
    rect: (()=>{const r=t.getBoundingClientRect();return {w:r.width,h:r.height,top:r.top};})()
  }));
  out.contentEditables = [...document.querySelectorAll('[contenteditable="true"]')].map((e,i)=>({
    i, tag:e.tagName, className:e.className.slice(0,120),
    isVisible: e.offsetWidth>0||e.offsetHeight>0,
    text: e.innerText.slice(0,50)
  }));
  // All role=textbox
  out.textboxes = [...document.querySelectorAll('[role="textbox"]')].map((e,i)=>({
    i, tag:e.tagName, className:e.className.slice(0,120),
    isVisible: e.offsetWidth>0||e.offsetHeight>0
  }));
  // All buttons with text
  out.allButtons = [...document.querySelectorAll('button')].map((b,i)=>({
    i, aria: b.getAttribute('aria-label')||'',
    text: (b.innerText||'').slice(0,30),
    className:b.className.slice(0,80),
    isVisible: b.offsetWidth>0||b.offsetHeight>0
  })).filter(b => b.isVisible);
  // Look for any element that might be the chat input by class name
  out.chatishElements = [...document.querySelectorAll('[class*="hatInput"],[class*="omposer"],[class*="itorContent"],[class*="iewInput"],[class*="essageInput"]')]
    .map((e,i)=>({i, tag:e.tagName, className:e.className.slice(0,120)}));
  // Tabbit uses Lexical/BlockNote editor - look for those
  out.lexical = document.querySelectorAll('[data-lexical-editor],[data-block-note]').length;
  out.prosemirror = document.querySelectorAll('.ProseMirror').length;
  out.contentEditableDivs = [...document.querySelectorAll('div[contenteditable="true"]')].length;
  return JSON.stringify(out, null, 2);
})()
"@
$result = Eval $inspect
Write-Host $result

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
