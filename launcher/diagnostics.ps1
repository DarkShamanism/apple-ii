$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'core.ps1')
Write-Output "A2MC $Version / read-only diagnostics / $(Get-Date -Format o)"
Write-Output 'Serial ownership is NOT probed. No serial port is opened by these checks.'
& (Join-Path $Project 'start.ps1') -Action Check
$external = @(Get-ExternalAdt)
Write-Output "External ADTPro instances: $($external.Count)"
foreach ($proc in $external) { Write-Output "ADTPro PID $($proc.ProcessId)" }
Write-Output 'Visible Minecraft windows:'
Get-Process | Where-Object { $_.MainWindowTitle -like '*Minecraft*' } | ForEach-Object { Write-Output "PID $($_.Id): $($_.MainWindowTitle)" }
Write-Output 'Release source/artifact integrity:'
if (Test-Path (Join-Path $Project "releases\$Version\manifest.json")) {
    & $Python (Join-Path $Project 'tools\release_guard.py') seal
} else {
    Write-Output 'Current release is not sealed yet; checking source metadata only.'
    & $Python (Join-Path $Project 'tools\release_guard.py') check
}
if ($LASTEXITCODE -ne 0) { throw 'Release integrity check failed.' }
Write-Output 'Diagnostics complete. File presence and compression tests cannot validate Apple II hardware.'
