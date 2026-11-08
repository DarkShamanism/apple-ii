param([Parameter(Mandatory=$true)][string]$Config)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $project)
$python=Join-Path $workspace 'Toolset\portable\python-3.12.8-embed\python.exe'
& $python -u (Join-Path $project 'tools\vsdrive_lab.py') $Config
if($LASTEXITCODE -ne 0){throw "VSDRIVE deploy failed ($LASTEXITCODE); see session log. The image is only replaced after a verified copy."}
