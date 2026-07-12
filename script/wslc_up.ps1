# wslc_up.ps1
# Build and run the Tabbit OpenAI-compatible server with Microsoft WSLC
# (WSL containers), without Docker Compose.
#
# Usage:
#   .\script\wslc_up.ps1
#   .\script\wslc_up.ps1 -Port 8000 -Name tabbit-openai
#   .\script\wslc_up.ps1 -NoBuild          # reuse existing image
#   .\script\wslc_up.ps1 -Foreground       # attach logs (no -d)
#   $env:TABBIT_SERVER_API_KEY = "secret"; .\script\wslc_up.ps1

[CmdletBinding()]
param(
    [string]$Image = "tabbit-openai:latest",
    [string]$Name  = "tabbit-openai",
    [int]$Port     = 8000,
    [string]$ConfigPath = $null,
    [switch]$NoBuild,
    [switch]$Foreground,
    [switch]$Pull
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ProjectRoot "tabbit_config.json"
}

$wslc = Get-Command wslc -ErrorAction SilentlyContinue
if (-not $wslc) {
    Write-Error "wslc not found on PATH. Install/update WSL so C:\Program Files\WSL\wslc.exe is available."
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath`nRun .\script\extract_cookies.ps1 first."
}

$dockerfile = Join-Path $ProjectRoot "Dockerfile"
if (-not (Test-Path $dockerfile)) {
    Write-Error "Dockerfile not found: $dockerfile"
}

# Stop/remove an existing container with the same name (best effort).
$existing = & wslc list --all 2>$null | Select-String -Pattern "\b$([regex]::Escape($Name))\b"
if ($existing) {
    Write-Host "Stopping existing container '$Name' ..."
    & wslc stop $Name 2>$null | Out-Null
    & wslc remove $Name 2>$null | Out-Null
}

if (-not $NoBuild) {
    Write-Host "Building image $Image with wslc ..."
    $buildArgs = @("build", "-t", $Image, "-f", $dockerfile)
    if ($Pull) { $buildArgs += "--pull" }
    $buildArgs += $ProjectRoot
    & wslc @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "wslc build failed (exit $LASTEXITCODE)"
    }
}

$envArgs = @(
    "-e", "TABBIT_CONFIG=/app/tabbit_config.json"
)
if ($env:TABBIT_SERVER_API_KEY) {
    $envArgs += @("-e", "TABBIT_SERVER_API_KEY=$($env:TABBIT_SERVER_API_KEY)")
}

$runArgs = @(
    "run",
    "--name", $Name,
    "-p", "${Port}:8000",
    "-v", "${ConfigPath}:/app/tabbit_config.json"
) + $envArgs

if (-not $Foreground) {
    $runArgs += "-d"
}

$runArgs += $Image

Write-Host "Starting container '$Name' on http://127.0.0.1:$Port ..."
& wslc @runArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "wslc run failed (exit $LASTEXITCODE)"
}

if (-not $Foreground) {
    Write-Host ""
    Write-Host "Up. Useful commands:"
    Write-Host "  wslc logs $Name"
    Write-Host "  wslc list"
    Write-Host "  .\script\wslc_down.ps1"
    Write-Host "  curl http://127.0.0.1:$Port/health"
}
