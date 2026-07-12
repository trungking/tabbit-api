# extract_cookies.ps1
# Launches Tabbit with remote debugging, extracts session cookies via CDP,
# writes cookies.txt, then auto-runs:
#   python tabbit_client.py init-cookies --from-file cookies.txt
# so tabbit_config.json is updated without any manual paste.
#
# Usage:
#   .\extract_cookies.ps1                         # extract + auto init-cookies
#   .\extract_cookies.ps1 -SkipInit               # write cookies.txt only
#   .\extract_cookies.ps1 -BrowserOnly            # just launch Tabbit with CDP
#   .\extract_cookies.ps1 -RemotePort 9222        # connect to an existing CDP port

[CmdletBinding()]
param(
    [string]$TabbitExe = "D:\Software\Tabbit\Application\Tabbit Browser.exe",
    [int]$RemotePort   = 9222,
    [string]$UserdataDir = $null,
    [int]$WaitSeconds   = 25,
    [switch]$BrowserOnly,
    [switch]$SkipInit
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Get-CdpTarget {
    param([int]$Port)
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 3
        return $resp
    } catch {
        return $null
    }
}

function Invoke-Cdp {
    param(
        [int]$Port,
        [hashtable]$Body
    )
    $json = $Body | ConvertTo-Json -Depth 10
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/protocol" `
        -Method Post -Body $json -ContentType "application/json" -TimeoutSec 5 -ErrorAction SilentlyContinue
    # older CDP needs WebSocket; for /json/protocol we use direct HTTP endpoints
    return $resp
}

# ---------------------------------------------------------------------------
# Step 1: launch Tabbit with --remote-debugging-port (if not already running)
# ---------------------------------------------------------------------------

$running = Get-Process -Name "Tabbit" -ErrorAction SilentlyContinue
if (-not $running) {
    if (-not (Test-Path $TabbitExe)) {
        Write-Error "Tabbit.exe not found at: $TabbitExe`nEdit the -TabbitExe parameter."
    }
    if (-not $UserdataDir) {
        $UserdataDir = Join-Path $env:TEMP "tabbit_debug_profile"
    }
    if (-not (Test-Path $UserdataDir)) {
        New-Item -ItemType Directory -Path $UserdataDir -Force | Out-Null
    }

    Write-Host "Launching Tabbit with remote debugging on port $RemotePort ..."
    $args = @(
        "--remote-debugging-port=$RemotePort",
        "--user-data-dir=$UserdataDir",
        "--no-first-run",
        "--no-default-browser-check",
        "https://web.tabbit.ai/chat"
    )
    Start-Process -FilePath $TabbitExe -ArgumentList $args
    Write-Host "Waiting up to $WaitSeconds s for the CDP endpoint..."
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $targets = Get-CdpTarget -Port $RemotePort
        if ($targets) { break }
        Start-Sleep -Milliseconds 800
    }
    if (-not $targets) {
        Write-Error "Tabbit did not expose CDP on port $RemotePort in time."
    }
} else {
    Write-Host "Tabbit already running; trying existing CDP port $RemotePort ..."
    $targets = Get-CdpTarget -Port $RemotePort
    if (-not $targets) {
        Write-Error "Tabbit is running but not with --remote-debugging-port=$RemotePort. Close it first and re-run."
    }
}

if ($BrowserOnly) {
    Write-Host "Tabbit is up. Open DevTools at http://127.0.0.1:$RemotePort in another browser."
    exit 0
}

# ---------------------------------------------------------------------------
# Step 2: prompt user to log in (if needed) and press Enter
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Tabbit is now open. If you are not logged in, log in once."
Write-Host "When you can see the chat interface, come back here and press Enter."
Read-Host "Press Enter to extract cookies"

# ---------------------------------------------------------------------------
# Step 3: drive the Network.getAllCookies CDP command
# ---------------------------------------------------------------------------

# Get the first page target
$page = $targets | Where-Object { $_.type -eq "page" -and $_.url -match "tabbit" } | Select-Object -First 1
if (-not $page) {
    $page = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
}
if (-not $page) {
    Write-Error "No page target found in CDP. Targets were: $($targets | Out-String)"
}

Write-Host "Using page target: $($page.url)"

# CDP requires WebSocket for most commands.
# Do not pin an assembly version — that fails across .NET Framework / .NET Core runtimes.
# ClientWebSocket is available on both Windows PowerShell 5.1 and PowerShell 7+.
try {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
} catch {
    # Fallback for older hosts where the type isn't preloaded
    $loaded = $false
    foreach ($name in @(
            "System.Net.WebSockets",
            "System"
        )) {
        try {
            Add-Type -AssemblyName $name -ErrorAction Stop
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $loaded = $true
            break
        } catch {
            continue
        }
    }
    if (-not $loaded) {
        Write-Error "System.Net.WebSockets.ClientWebSocket is unavailable in this PowerShell host: $_"
    }
}

$ct = [System.Threading.CancellationTokenSource]::new()
$ct.CancelAfter([TimeSpan]::FromSeconds(15))
$wsUri = [Uri]$page.webSocketDebuggerUrl
Write-Host "Connecting to $wsUri ..."
try {
    [void]$ws.ConnectAsync($wsUri, $ct.Token).GetAwaiter().GetResult()
} catch {
    Write-Error "WebSocket connect failed: $_"
}
if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
    Write-Error "WebSocket failed to open: $($ws.State)"
}

# send command
$msg = @{ id = 1; method = "Network.getAllCookies"; params = @{} } | ConvertTo-Json -Compress
$sendBytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
$sendSeg = [ArraySegment[byte]]::new($sendBytes)
[void]$ws.SendAsync(
    $sendSeg,
    [System.Net.WebSockets.WebSocketMessageType]::Text,
    $true,
    $ct.Token
).GetAwaiter().GetResult()

# receive response (may need multiple reads)
$buf = New-Object byte[] 65536
$recvSeg = [ArraySegment[byte]]::new($buf)
$complete = $false
$resultJson = ""
while (-not $complete) {
    $recv = $ws.ReceiveAsync($recvSeg, $ct.Token).GetAwaiter().GetResult()
    $resultJson += [System.Text.Encoding]::UTF8.GetString($buf, 0, $recv.Count)
    $complete = $recv.EndOfMessage
}
try {
    [void]$ws.CloseAsync(
        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
        "done",
        $ct.Token
    ).GetAwaiter().GetResult()
} catch {
    # ignore close errors
} finally {
    $ws.Dispose()
    $ct.Dispose()
}

$resp = $resultJson | ConvertFrom-Json
if (-not $resp.result -or -not $resp.result.cookies) {
    Write-Error "No cookies in CDP response: $resultJson"
}

# ---------------------------------------------------------------------------
# Step 4: filter to tabbit.ai cookies and format
# ---------------------------------------------------------------------------

$tabbitCookies = $resp.result.cookies | Where-Object {
    $_.domain -match "tabbit" -and $_.value -ne ""
} | Sort-Object -Property name -Unique

Write-Host ""
Write-Host "Found $($tabbitCookies.Count) Tabbit cookies:"
$tabbitCookies | Format-Table domain, name, @{Name="value";Expression={$_.value.Substring(0,[Math]::Min(40,$_.value.Length)) + "..."}} -AutoSize

$cookieString = ($tabbitCookies | ForEach-Object { "$($_.name)=$($_.value)" }) -join "; "

$outFile = Join-Path $ProjectRoot "cookies.txt"
# UTF-8 without BOM so Python reads cleanly
[System.IO.File]::WriteAllText($outFile, $cookieString, [System.Text.UTF8Encoding]::new($false))
Write-Host ""
Write-Host "Cookie string written to: $outFile"

$clientPy = Join-Path $ProjectRoot "tabbit_client.py"
if ($SkipInit) {
    Write-Host ""
    Write-Host "SkipInit set — not updating tabbit_config.json."
    Write-Host "Init later with:"
    Write-Host "  python `"$clientPy`" init-cookies --from-file `"$outFile`""
    exit 0
}

# Auto-persist into tabbit_config.json via the Python client.
# IMPORTANT: pass a file path, never the raw cookie string as a shell arg —
# PowerShell mangles JSON-looking values like g_state={"i_l":0,...}.
if (-not (Test-Path $clientPy)) {
    Write-Error "tabbit_client.py not found at: $clientPy"
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $python) {
    Write-Error "python/py not found on PATH. cookies.txt was written; init manually later."
}

Write-Host ""
Write-Host "Auto init-cookies -> tabbit_config.json ..."
& $python.Source $clientPy init-cookies --from-file $outFile
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Auto-init failed. cookies.txt is ready; run:"
    Write-Host "  python `"$clientPy`" init-cookies --from-file `"$outFile`""
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Done. Cookies extracted and initialized."
Write-Host "Test with:"
Write-Host "  python `"$clientPy`" whoami"
Write-Host "  python `"$clientPy`" chat `"Hello`""
