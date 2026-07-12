# capture_device_report.ps1
# Listens at the browser level (CDP) for the device-info report request.
# Trigger it by switching the Windows default browser AWAY from Tabbit,
# then BACK to Tabbit — that fires the "became default" detection event.

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

$b = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5
Write-Host "Browser WS: $($b.webSocketDebuggerUrl)"

Add-Type -AssemblyName "System.Net.WebSockets, Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" -ErrorAction SilentlyContinue

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter([TimeSpan]::FromMinutes(10))
$ws.ConnectAsync($b.webSocketDebuggerUrl, $cts.Token).Wait()

$script:idSeq = 1
function Send-Cdp {
    param([string]$Method, [hashtable]$Params = @{})
    $script:idSeq++
    $payload = @{ id = $script:idSeq; method = $Method; params = $Params }
    $json = $payload | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    [void]$ws.SendAsync(
        [ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true, $cts.Token)
    return $script:idSeq
}

# Enable both Network and Fetch at browser level. Fetch intercept lets us
# read the POST body of ANY request (even browser-process ones).
$netId = Send-Cdp -Method "Network.enable" -Params @{ maxTotalBufferSize = 20000000; maxResourceBufferSize = 10000000; maxPostDataSize = 65536 }
Write-Host "Network.enable id=$netId"
$fetchId = Send-Cdp -Method "Fetch.enable" -Params @{
    patterns = @(
        @{ urlPattern = "*upsert-user-device-info*"; requestStage = "Request" },
        @{ urlPattern = "*report*"; requestStage = "Request" }
    )
}
Write-Host "Fetch.enable id=$fetchId"

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Yellow
Write-Host "LISTENER READY. Now:" -ForegroundColor Yellow
Write-Host "  1. Open Windows Settings > Apps > Default apps" -ForegroundColor Yellow
Write-Host "  2. Set default browser to Chrome or Edge (away from Tabbit)" -ForegroundColor Yellow
Write-Host "  3. Then set it back to Tabbit" -ForegroundColor Yellow
Write-Host "The 'became default' detection fires the report immediately." -ForegroundColor Yellow
Write-Host "Listening for up to 10 minutes." -ForegroundColor Yellow
Write-Host "=============================================================" -ForegroundColor Yellow
Write-Host ""

$deadline = (Get-Date).AddMinutes(10)
$allRequests = New-Object System.Collections.ArrayList
$gotUpsert = $false

while ((Get-Date) -lt $deadline -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
    $seg = [ArraySegment[byte]]::new((New-Object byte[] 262144))
    $r = $ws.ReceiveAsync($seg, $cts.Token)
    while (-not $r.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not $r.IsCompleted) { break }
    if ($r.Result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }

    $text = [System.Text.Encoding]::UTF8.GetString($seg.Array, 0, $r.Result.Count)
    try { $msg = $text | ConvertFrom-Json } catch { continue }

    # Handle Fetch.requestPaused — this is where we get the body
    if ($msg.method -eq "Fetch.requestPaused") {
        $req = $msg.params.request
        $url = $req.url
        # Always continue first so we don't block
        Send-Cdp -Method "Fetch.continueRequest" -Params @{ requestId = $msg.params.requestId } | Out-Null

        # Try to get post data
        $bodyData = $req.postData
        if (-not $bodyData -and $msg.params.requestId) {
            # requestPaused doesn't include body; we'd need Fetch.fulfillRequest or
            # the Network domain. Try to get it via the requestId linkage.
        }

        Write-Host "[FETCH] $($req.method) $url" -ForegroundColor Cyan
        if ($url -match "upsert") {
            Write-Host "  >>> HIT! Capturing." -ForegroundColor Green
            # Capture headers and whatever body we have
            $capture = @{
                source = "Fetch.requestPaused"
                url = $url
                method = $req.method
                headers = $req.headers
                body = $bodyData
                postDataEntries = $req.postDataEntries
                hasPostData = $msg.params.hasPostData
                ts = (Get-Date).ToString("o")
            }
            $allRequests.Add($capture) | Out-Null
            $gotUpsert = $true
        }
    }

    # Network events give us the body via getRequestPostData
    if ($msg.method -eq "Network.requestWillBeSent") {
        $req = $msg.params.request
        $url = $req.url
        if ($url -match "upsert-user-device-info") {
            Write-Host "[NET] $($req.method) $url" -ForegroundColor Cyan
            $bodyData = $req.postData
            # If body is too big, fetch it separately
            if (-not $bodyData -and $req.hasPostData) {
                $postId = Send-Cdp -Method "Network.getRequestPostData" -Params @{ requestId = $msg.params.requestId }
                # read next message
                $seg2 = [ArraySegment[byte]]::new((New-Object byte[] 131072))
                $deadline2 = (Get-Date).AddSeconds(5)
                while ((Get-Date) -lt $deadline2) {
                    $r2 = $ws.ReceiveAsync($seg2, $cts.Token)
                    while (-not $r2.IsCompleted -and (Get-Date) -lt $deadline2) { Start-Sleep -Milliseconds 30 }
                    if (-not $r2.IsCompleted) { break }
                    $text2 = [System.Text.Encoding]::UTF8.GetString($seg2.Array, 0, $r2.Count)
                    try {
                        $msg2 = $text2 | ConvertFrom-Json
                        if ($msg2.id -eq $postId) {
                            $bodyData = $msg2.result.postData
                            break
                        }
                    } catch {}
                }
            }
            $capture = @{
                source = "Network.requestWillBeSent"
                url = $url
                method = $req.method
                headers = $req.headers
                body = $bodyData
                ts = (Get-Date).ToString("o")
            }
            $allRequests.Add($capture) | Out-Null
            $gotUpsert = $true
            Write-Host "  >>> HIT! body length: $($bodyData.Length)" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "Captured $($allRequests.Count) upsert request(s)." -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green

$allRequests | ConvertTo-Json -Depth 10 | Out-File (Join-Path $ProjectRoot "captured_device_report.json") -Encoding utf8

foreach ($u in $allRequests) {
    Write-Host ""
    Write-Host "=== $($u.method) $($u.url) ==="
    Write-Host "HEADERS:" -ForegroundColor Yellow
    if ($u.headers -is [string]) {
        try { $h = $u.headers | ConvertFrom-Json } catch { $h = @{raw = $u.headers} }
    } else { $h = $u.headers }
    if ($h) {
        $h.PSObject.Properties | Sort-Object Name | ForEach-Object {
            $v = "$($_.Value)"
            if ($_.Name -match "cookie|authorization" -and $v.Length -gt 80) {
                $v = $v.Substring(0,40) + " ...[" + $v.Length + " chars]"
            }
            Write-Host ("  {0,-32} : {1}" -f $_.Name, $v)
        }
    }
    Write-Host ""
    Write-Host "BODY:" -ForegroundColor Yellow
    if ($u.body) {
        Write-Host $u.body
        try {
            Write-Host ""
            Write-Host "Parsed:" -ForegroundColor DarkGray
            ($u.body | ConvertFrom-Json) | ConvertTo-Json -Depth 8
        } catch {}
    } else {
        Write-Host "  (no body — requestPaused often doesn't include it; check hasPostData=$($u.hasPostData))"
    }
}

[void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cts.Token)
Write-Host "`nDone."
