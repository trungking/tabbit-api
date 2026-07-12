# wslc_down.ps1
# Stop and remove the Tabbit WSLC container.
#
# Usage:
#   .\script\wslc_down.ps1
#   .\script\wslc_down.ps1 -Name tabbit-openai -RemoveImage

[CmdletBinding()]
param(
    [string]$Name  = "tabbit-openai",
    [string]$Image = "tabbit-openai:latest",
    [switch]$RemoveImage
)

$ErrorActionPreference = "Stop"

$wslc = Get-Command wslc -ErrorAction SilentlyContinue
if (-not $wslc) {
    Write-Error "wslc not found on PATH."
}

Write-Host "Stopping container '$Name' ..."
& wslc stop $Name 2>$null | Out-Null
& wslc remove $Name 2>$null | Out-Null

if ($RemoveImage) {
    Write-Host "Removing image '$Image' ..."
    & wslc rmi $Image 2>$null | Out-Null
}

Write-Host "Done."
