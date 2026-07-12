# capture_opus.ps1
# Switch the Tabbit UI to Opus and capture the actual /api/v1/chat/completion
# request it sends, so we can diff against our Python client's request.

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

# Pick chat page & attach
$page = (Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5) |
    Where-Object { $_.type -eq "page" -and $_.url -match "session" } | Select-Object -First 1
Write-Host "Page: $($page.url)"
$id = Send-Cdp -Method "Target.attachToTarget" -Params @{ targetId = $page.id; flatten = $true }
$resp = Wait-Resp -Id $id
$sid = $resp.result.sessionId

# Patch fetch (force fresh)
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
  return 'fresh install';
})()
"@
$resp = Eval -expr $patch -sid $sid
Write-Host "Patch: $($resp.result.result.value)"

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Yellow
Write-Host "NOW IN TABBIT:" -ForegroundColor Yellow
Write-Host "  1. Switch the model selector to Claude-Opus-4.8" -ForegroundColor Yellow
Write-Host "  2. Type a message (e.g. 'hi') and send it" -ForegroundColor Yellow
Write-Host "We'll wait up to 90s for the request." -ForegroundColor Yellow
Write-Host "=============================================================" -ForegroundColor Yellow

$deadline = (Get-Date).AddSeconds(90)
$captured = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $pollExpr = "JSON.stringify(window.__cap||[])"
    $pollId = Send-Cdp -Method "Runtime.evaluate" -Params @{ expression = $pollExpr; returnByValue = $true } -SessionId $sid
    $resp = Wait-Resp -Id $pollId
    try {
        $reqs = $resp.result.result.value | ConvertFrom-Json
    } catch { continue }
    if ($reqs.Count -gt 0) {
        $captured = $reqs | Select-Object -First 1
        break
    }
    Write-Host "." -NoNewline
}
Write-Host ""

if ($captured) {
    Write-Host ""
    Write-Host "=== CAPTURED Opus REQUEST ===" -ForegroundColor Green
    Write-Host "URL: $($captured.url)"
    Write-Host "Method: $($captured.method)"
    Write-Host ""
    Write-Host "HEADERS (all of them):" -ForegroundColor Yellow
    $captured.headers.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $v = "$($_.Value)"
        Write-Host ("  {0,-32} : {1}" -f $_.Name, $v)
    }
    Write-Host ""
    Write-Host "BODY:" -ForegroundColor Yellow
    $captured.body | ConvertTo-Json -Depth 10
    $captured | ConvertTo-Json -Depth 10 | Out-File (Join-Path $ProjectRoot "opus_capture.json")
    Write-Host "Saved to opus_capture.json"
} else {
    Write-Host "[!] Nothing captured." -ForegroundColor Red
}

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
