param([Parameter(Mandatory=$true)][string]$Config)
# One Farglade OS action for the launcher. Farglade OS is the sibling project farglade-os; its own
# tools do the work. Boot opens the serial port and serves the Apple until the stop file appears.
# Build and Check never open a port.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $project)
$python=Join-Path $workspace 'Toolset\portable\python-3.12.8-embed\python.exe'
$c=[IO.File]::ReadAllText($Config,[Text.Encoding]::UTF8) | ConvertFrom-Json
$tool=switch([string]$c.Action){'Boot'{'uplink.py'} 'Build'{'build.py'} 'Check'{'test_tools.py'} default{throw 'Unknown Farglade action.'}}
$script=Join-Path (Join-Path ([string]$c.Root) 'tools') $tool
if(-not (Test-Path -LiteralPath $script -PathType Leaf)){throw "Farglade OS is not at $($c.Root): tools\$tool is missing."}
# Every value was validated by the launcher; each is passed as one literal argument.
$arguments=@('-u',$script)
if($c.Action -eq 'Boot') {
    $arguments+=@('--port',[string]$c.Port,'--slot',[string]$c.Slot,'--baud',[string]$c.Baud,'--stop-file',[string]$c.StopFile)
    if($c.Reduced){$arguments+='--reduced-motion'}
    if($c.Mute){$arguments+='--mute'}
    if($c.Net){$arguments+='--net'}
    if([string]$c.NetHosts){$arguments+=@('--net-hosts',[string]$c.NetHosts)}
    if([string]$c.RelayHosts){$arguments+=@('--relay-hosts',[string]$c.RelayHosts)}
}
& $python @arguments
if($LASTEXITCODE -ne 0){throw "Farglade OS $($c.Action) ended with an error ($LASTEXITCODE); see the journal."}
