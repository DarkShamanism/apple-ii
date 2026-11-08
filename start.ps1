# Default Check action never opens a serial port.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Check', 'Offline', 'AdtPro', 'Demo', 'Minecraft', 'Launcher')]
    [string]$Action = 'Check',
    [string]$Port = 'COM3',
    [ValidateSet(19200, 115200)][int]$Baud = 115200,
    [ValidateRange(0.1, 60)][double]$Fps = 10,
    [ValidateNotNullOrEmpty()][string]$WindowTitle = 'Minecraft 1',
    [switch]$NoInput,
    [switch]$NoSounds
)
$ErrorActionPreference = 'Stop'
$Workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Version = (Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$BuildDir = Join-Path $PSScriptRoot "build\$Version"
$Streamer = Join-Path $PSScriptRoot 'pc\a2mc_stream.ps1'
$WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Adt = Join-Path $Workspace 'Projects\adtpro-v_2_1_0\build\ADTPro-2.1.0'
$Javaw = Join-Path $Workspace 'Toolset\portable\jdk8u492-b09\bin\javaw.exe'
$Jars = @(
    (Join-Path $Adt 'lib\ADTPro-2.1.0.jar'),
    (Join-Path $Adt 'lib\AppleCommander\AppleCommander-1.3.5.13-ac.jar'),
    (Join-Path $Adt 'lib\jssc\jssc-2.9.2.jar'),
    (Join-Path $Adt 'lib\jssc\slf4j-nop-1.7.9.jar')
)
Write-Host "A2MC $Version - $Action"
if ($Action -eq 'Launcher') {
    if ($PSCmdlet.ShouldProcess($PSScriptRoot, 'Open the graphical launcher (no automatic serial connection)')) {
        $Gui = Join-Path $PSScriptRoot 'launcher.ps1'
        Start-Process -FilePath $WindowsPowerShell -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$Gui`"") -WindowStyle Hidden
    }
    return
}
if ($Action -eq 'Check') {
    foreach ($Path in (@($WindowsPowerShell, $Streamer, $Javaw) + $Jars + @(
        (Join-Path $BuildDir 'A2MC-RX.BIN'),
        (Join-Path $BuildDir 'A2MC.DSK'),
        (Join-Path $BuildDir 'A2HR-RX.BIN'),
        (Join-Path $BuildDir 'A2HR.DSK'),
        (Join-Path $PSScriptRoot "releases\$Version\manifest.json")
    ))) {
        $Status = if (Test-Path -LiteralPath $Path -PathType Leaf) { 'OK' } else { 'MISSING' }
        Write-Host "$Status  $Path"
    }
    Write-Host "Serial ports (names only): $([System.IO.Ports.SerialPort]::GetPortNames() -join ', ')"
    Write-Host 'Next: .\start.ps1 -Action Offline; then follow docs\QUICK-START.md.'
    Write-Host 'File presence does not verify release integrity or hardware operation.'
    return
}
if ($Action -eq 'AdtPro') {
    foreach ($Path in (@($Javaw) + $Jars)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required ADTPro file missing: $Path" }
    }
    if ($PSCmdlet.ShouldProcess($Adt, 'Launch ADTPro; choose Serial and the port in its UI')) {
        $Cp = $Jars -join ';'
        Start-Process -FilePath $Javaw -ArgumentList @('-Xms128m', '-Xmx256m', '-cp', "`"$Cp`"", 'org.adtpro.ADTPro') -WorkingDirectory $Adt -WindowStyle Hidden
    }
    return
}
if (-not (Test-Path -LiteralPath $WindowsPowerShell)) { throw 'Windows PowerShell is required.' }
$StreamArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Streamer, '-Mode', 'DlgrC')
if ($Action -eq 'Offline') {
    $StreamArgs += @('-Demo', '-DryRun')
} else {
    if ($Port -notmatch '^COM[1-9][0-9]*$') { throw 'Use a Windows serial port name such as COM3.' }
    if ($Baud -eq 19200 -and -not $PSBoundParameters.ContainsKey('Fps')) { $Fps = 1.5 }
    $StreamArgs += @('-Port', $Port, '-Baud', "$Baud", '-Fps', $Fps.ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($Action -eq 'Demo') { $StreamArgs += '-Demo' } else { $StreamArgs += @('-WindowTitle', $WindowTitle) }
    if ($NoInput) { $StreamArgs += '-NoInput' }
    if ($NoSounds) { $StreamArgs += '-NoSounds' }
    Write-Host "Close ADTPro first. Receiver must show WAITING FOR STREAM at $Baud baud."
    Write-Host "Target: $Port, DlgrC 80x48, $Fps fps. Ctrl+C stops the PC streamer."
}
$Operation = if ($Action -eq 'Offline') { 'Run offline compression checks (no serial)' } else { "Open $Port and stream $Action" }
if ($PSCmdlet.ShouldProcess($Streamer, $Operation)) {
    & $WindowsPowerShell @StreamArgs
    if ($LASTEXITCODE -ne 0) { throw "Streamer failed (exit $LASTEXITCODE). See its error above." }
}
