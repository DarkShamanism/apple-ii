# Shared launcher logic. Loading this file does not start processes or open ports.
Set-StrictMode -Version 2
$script:Project = Split-Path -Parent $PSScriptRoot
$script:Version = (Get-Content (Join-Path $Project 'VERSION') -Raw).Trim()
# The launcher has its own name and version; VERSION above remains the A2MC release.
$script:LauncherName = 'Crowbar Launcher'
$script:LauncherVersion = (Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
if ($LauncherVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'launcher/VERSION must be MAJOR.MINOR.PATCH.' }
$script:Workspace = Split-Path -Parent (Split-Path -Parent $Project)
$script:DataDir = Join-Path $Project "build\$Version\launcher"
$script:PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Python = Join-Path $Workspace 'Toolset\portable\python-3.12.8-embed\python.exe'
$script:AdtDir = Join-Path $Workspace 'Projects\adtpro-v_2_1_0\build\ADTPro-2.1.0'
$script:Javaw = Join-Path $Workspace 'Toolset\portable\jdk8u492-b09\bin\javaw.exe'
$script:AdtJars = @('lib\ADTPro-2.1.0.jar', 'lib\AppleCommander\AppleCommander-1.3.5.13-ac.jar', 'lib\jssc\jssc-2.9.2.jar', 'lib\jssc\slf4j-nop-1.7.9.jar') | ForEach-Object { Join-Path $AdtDir $_ }
# Farglade OS is a sibling project with its own version, build and tools; the launcher only runs them.
$script:FargladeDir = Join-Path $Workspace 'Projects\farglade-os'
$script:Active = $null
$script:History = @()
$script:Profiles = @()

function New-Profile([string]$Name = 'Everyday Minecraft') {
    [pscustomobject][ordered]@{
        Name = $Name; Source = 'Minecraft'; Port = 'COM3'; Baud = 115200; Fps = 10.0
        WindowTitle = 'Minecraft 1'; Image = ''; Mode = 'DlgrC'; Fit = 'Crop'; AuxRotate = 'Left'
        Saturation = 1.35; Contrast = 1.12; Gamma = 1.15; Dither = $false
        NoInput = $false; NoSounds = $false; LookStep = 40; HoldMs = 350; Duration = 0
        HiSource = 'Demo'; HiWindowTitle = ''; HiImage = ''; HiSlot = 2; HiPort = 'COM3'; HiBaud = 115200
        HiDither = 0.9; HiFps = 6.0; HiFit = 'Letterbox'; HiDuration = 0; HiPages = 'Packed'; HiKeys = 'Off'
        CpmTitle = 'Premium SoftCard IIe'; CpmDisk = ''; CpmVersion = 'CP/M 2.2'; CpmCommand = 'A2Z'; CpmNotes = ''
        CpmPort = 'COM3'; CpmBaud = 9600; CpmHandshake = 'None'; CpmSlot = 2
        CpmSource = (Join-Path $Project 'src\z80\example-module.asm'); CpmTarget = 'Module'; CpmBinary = ''
        CpmHex = (Join-Path $Project "build\$Version\A2Z.HEX"); CpmOffset = 0; CpmCount = 16
        VsImage = (Join-Path $AdtDir 'disks\Virtual2.po'); VsSet = 'Receiver only'
        CpmDiskB = ''; CpmBootBaud = 115200; CpmWrites = 'Save to image'
        FgPort = 'COM3'; FgSlot = 5; FgBaud = 115200; FgReduced = $false; FgMute = $false; FgNetHosts = ''; FgRelayHosts = ''
    }
}

function ConvertTo-Profile($InputProfile) {
    # Whitelist all fields, including on disk imports; never accept arbitrary script arguments.
    $p = New-Profile
    foreach ($field in $p.PSObject.Properties.Name) {
        if ($null -ne $InputProfile.PSObject.Properties[$field]) { $p.$field = $InputProfile.$field }
    }
    foreach ($field in @('Name', 'Port', 'WindowTitle', 'Image', 'Source', 'Mode', 'Fit', 'AuxRotate', 'HiSource', 'HiWindowTitle', 'HiImage', 'HiFit', 'HiPort', 'HiPages', 'HiKeys','CpmTitle','CpmDisk','CpmVersion','CpmCommand','CpmNotes','CpmPort','CpmHandshake','CpmSource','CpmTarget','CpmBinary','CpmHex','VsImage','VsSet','CpmDiskB','CpmWrites','FgPort','FgNetHosts','FgRelayHosts')) {
        $p.$field = [string]$p.$field
        if ($p.$field.Length -gt 1024 -or $p.$field -match '[\x00-\x1f]') { throw "Invalid $field text." }
    }
    if ([string]::IsNullOrWhiteSpace($p.Name) -or $p.Name.Length -gt 80) { throw 'Profile name must contain 1-80 characters.' }
    if ($p.Port -notmatch '^COM[1-9][0-9]*$') { throw 'Port must be a name such as COM3.' }
    $p.Port = $p.Port.ToUpperInvariant()
    if($p.CpmPort -notmatch '^COM[1-9][0-9]*$'){throw 'CP/M port must be a name such as COM3.'}
    if($p.CpmTarget -cnotin @('Module','COM') -or $p.CpmHandshake -cnotin @('None','RtsCts')){throw 'Invalid Z80 target or flow control.'}
    if($p.VsSet -cnotin @('Receiver only','All receivers')){throw 'Choose which receivers to deploy to VSDRIVE.'}
    if($p.CpmWrites -cnotin @('Save to image','Read only')){throw 'Choose whether CP/M may write to the disk images.'}
    if($p.CpmBootBaud -notin @(115200,19200)){throw 'Choose 115200 or 19200 baud for booting CP/M from the PC.'}
    if($p.FgPort -notmatch '^COM[1-9][0-9]*$'){throw 'Farglade port must be a name such as COM3.'}
    $p.FgPort = $p.FgPort.ToUpperInvariant()
    if($p.FgBaud -notin @(115200,19200)){throw 'Choose 115200 or 19200 baud for Farglade OS.'}
    foreach($field in @('FgNetHosts','FgRelayHosts')) {
        # Names or addresses only. An entry cannot begin with a dash or hold a space, so it can never read as an option.
        $p.$field = $p.$field.Trim()
        if($p.$field -and $p.$field -cnotmatch '^[A-Za-z0-9\[][A-Za-z0-9.:\[\]-]*(\s*,\s*[A-Za-z0-9\[][A-Za-z0-9.:\[\]-]*)*$'){throw 'Host lists are names or addresses separated by commas.'}
    }
    if($p.CpmBaud -notin @(300,1200,2400,4800,9600,19200)){throw 'Choose a supported CP/M baud rate.'}
    if ($p.HiPort -notmatch '^COM[1-9][0-9]*$') { throw 'Hi-Res port must be a name such as COM3.' }
    if ($p.HiSource -cnotin @('Demo','Window','Desktop','Image') -or $p.HiFit -cnotin @('Crop','Stretch','Letterbox')) { throw 'Invalid Hi-Res source or fit.' }
    if ($p.HiPages -cnotin @('Packed','Raw') -or $p.HiKeys -cnotin @('Off','Log','Minecraft')) { throw 'Invalid Hi-Res pages or keys setting.' }
    foreach ($pair in @(@('Source', @('Minecraft','Demo','Image')), @('Mode', @('Lores','Dlgr','DlgrC')), @('Fit', @('Crop','Stretch','Letterbox')), @('AuxRotate', @('Left','Right','None')))) {
        if ($p.($pair[0]) -cnotin $pair[1]) { throw "Invalid $($pair[0])." }
    }
    $bounds = @{ Baud = @(19200,115200); Fps = @(0.1,60); Saturation = @(0,3); Contrast = @(0.1,3); Gamma = @(0.1,3); LookStep = @(1,500); HoldMs = @(1,2000); Duration = @(0,86400) }
    $bounds.HiBaud=@(19200,115200); $bounds.HiSlot=@(1,7); $bounds.HiDither=@(0,1); $bounds.HiFps=@(.1,15); $bounds.HiDuration=@(0,86400)
    $bounds.CpmBaud=@(300,19200); $bounds.CpmOffset=@(0,4095); $bounds.CpmCount=@(1,32); $bounds.CpmSlot=@(1,7); $bounds.CpmBootBaud=@(19200,115200)
    $bounds.FgSlot=@(1,7); $bounds.FgBaud=@(19200,115200)
    foreach ($field in $bounds.Keys) {
        $number = 0.0
        if (-not [double]::TryParse([string]$p.$field, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $bounds[$field][0] -or $number -gt $bounds[$field][1]) { throw "$field must be between $($bounds[$field][0]) and $($bounds[$field][1]); use a decimal point." }
        $p.$field = $number
    }
    if ($p.Baud -notin @(19200,115200)) { throw 'Baud must be 19200 or 115200.' }
    if ($p.HiBaud -notin @(19200,115200)) { throw 'Hi-Res baud must be 19200 or 115200.' }
    foreach ($field in @('Baud','LookStep','HoldMs','HiBaud','HiSlot','CpmBaud','CpmOffset','CpmCount','CpmSlot','CpmBootBaud','FgSlot','FgBaud')) {
        if ($p.$field -ne [math]::Truncate($p.$field)) { throw "$field must be a whole number." }
        $p.$field = [int]$p.$field
    }
    if($p.CpmOffset+$p.CpmCount -gt 4096){throw 'Memory inspection must stay inside the module area.'}
    foreach ($field in @('Dither','NoInput','NoSounds','FgReduced','FgMute')) {
        if ($p.$field -isnot [bool]) { throw "$field must be a boolean." }
    }
    if ($p.Source -eq 'Minecraft' -and [string]::IsNullOrWhiteSpace($p.WindowTitle)) { throw 'Enter a Minecraft window title fragment.' }
    return $p
}

function Test-FilePath($Path) {
    # Windows PowerShell 5.1 throws, instead of returning false, for an empty -LiteralPath.
    -not [string]::IsNullOrWhiteSpace([string]$Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Get-Sha256([string]$Path) {
    # .NET directly: Get-FileHash comes from a script module that Windows PowerShell does not always load.
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Format-LauncherError($ErrorRecord) {
    # A launcher check (throw 'text') reads as written; any other failure names its script line for reports.
    $message = $ErrorRecord.Exception.Message
    if ($ErrorRecord.Exception.GetType() -eq [Management.Automation.RuntimeException] -and $ErrorRecord.FullyQualifiedErrorId -ceq $message) { return $message }
    $where = $ErrorRecord.InvocationInfo
    if ($null -eq $where -or -not $where.ScriptName) { return $message }
    "$message [$(Split-Path -Leaf $where.ScriptName) line $($where.ScriptLineNumber)]"
}

function Save-JsonAtomic([string]$Path, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 8
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, "$Path.bak") }
    else { [IO.File]::Move($temp, $Path) }
}

function Initialize-Store {
    $null = New-Item -ItemType Directory -Path $DataDir -Force
    $script:StoreWarning = ''
    $profilePath = Join-Path $DataDir 'profiles.json'
    if (-not (Test-Path -LiteralPath $profilePath)) {
        # Carry profiles forward from the latest older release, without writing there.
        $older = Get-ChildItem (Join-Path $Project 'build') -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and [version]$_.Name -lt [version]$Version } | Sort-Object { [version]$_.Name } -Descending
        foreach ($dir in $older) {
            $candidate = Join-Path $dir.FullName 'launcher\profiles.json'
            if (Test-Path -LiteralPath $candidate) { $profilePath = $candidate; break }
        }
    }
    try {
        if (Test-Path -LiteralPath $profilePath) {
            $script:Profiles = @((Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json) | ForEach-Object { ConvertTo-Profile $_ })
            if ($Profiles.Count -eq 0) { throw 'No saved profiles.' }
        } else {
            $slow = New-Profile 'Slow link / 19200'; $slow.Baud = 19200; $slow.Fps = 1.5
            $demo = New-Profile 'Demo / hardware check'; $demo.Source = 'Demo'; $demo.NoInput = $true
            $script:Profiles = @((New-Profile), $slow, $demo)
        }
    } catch {
        $script:StoreWarning = "Could not load profiles: $($_.Exception.Message) Original file preserved at $profilePath."
        $script:Profiles = @((New-Profile))
    }
    $historyPath = Join-Path $DataDir 'history.json'
    try {
        if (Test-Path -LiteralPath $historyPath) {
            $script:History = @((Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
            foreach ($entry in $History) {
                if ($entry.Status -eq 'Running') { $entry.Status = 'Interrupted / outcome unknown' }
            }
        }
    } catch { $script:StoreWarning += " Could not read history; original preserved at $historyPath."; $script:History = @() }
}

function Get-StreamArguments($Profile, [string]$StopFile) {
    $p = ConvertTo-Profile $Profile
    if ($p.Source -eq 'Image' -and -not (Test-FilePath $p.Image)) { throw 'Choose an existing image file.' }
    $argsMap = @{}
    foreach ($field in @('Port','Baud','Fps','Mode','Fit','AuxRotate','Saturation','Contrast','Gamma','Dither','NoInput','NoSounds','LookStep','HoldMs','Duration')) { $argsMap[$field] = $p.$field }
    switch ($p.Source) {
        'Minecraft' { $argsMap.WindowTitle = $p.WindowTitle }
        'Demo' { $argsMap.Demo = $true; $argsMap.NoInput = $true }
        'Image' { $argsMap.Image = $p.Image; $argsMap.NoInput = $true }
    }
    $argsMap.StopFile = $StopFile
    return $argsMap
}

function New-ScriptCommand([string]$Path, [hashtable]$Parameters) {
    $payload = @{ Path = $Path; Parameters = $Parameters } | ConvertTo-Json -Depth 5 -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    # Data is decoded and splatted, never interpolated as executable PowerShell.
    return "`$ErrorActionPreference='Stop'; try { `$d = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')) | ConvertFrom-Json; `$a=@{}; foreach (`$x in `$d.Parameters.PSObject.Properties) { `$a[`$x.Name]=`$x.Value }; & `$d.Path @a; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; exit 0 } catch { Write-Error `$_ -ErrorAction Continue; exit 1 }"
}

function Get-HiArguments($Profile, [string]$Kind, [string]$Directory, [string]$StopFile) {
    $p=ConvertTo-Profile $Profile
    $action=switch($Kind){'HiPreview'{'Preview'} 'HiStream'{'Stream'} 'HiBootstrap'{'Bootstrap'} default{throw 'Unknown Hi-Res action.'}}
    if($action -ne 'Bootstrap') {
        if($p.HiSource -eq 'Window' -and [string]::IsNullOrWhiteSpace($p.HiWindowTitle)){throw 'Choose a Hi-Res capture window.'}
        if($p.HiSource -eq 'Image' -and -not (Test-FilePath $p.HiImage)){throw 'Choose a Hi-Res image file.'}
    }
    # Keys from the IIe are typed only into a captured window, never into whatever else has the keyboard.
    if($action -eq 'Stream' -and $p.HiKeys -eq 'Minecraft' -and $p.HiSource -ne 'Window'){throw 'Minecraft keys go to a captured window: choose the Window source, or set Hi-Res keys to Off or Log.'}
    $keys=if($action -eq 'Stream'){$p.HiKeys}else{'Off'}
    return @{Action=$action; Source=$(if($action -eq 'Bootstrap'){'Demo'}else{$p.HiSource}); WindowTitle=$p.HiWindowTitle; Image=$p.HiImage; Port=$p.HiPort; Baud=$p.HiBaud; Slot=$p.HiSlot; Dither=$p.HiDither; Fit=$p.HiFit; Fps=$p.HiFps; Duration=$p.HiDuration; Pages=$p.HiPages; Keys=$keys; LookStep=$p.LookStep; HoldMs=$p.HoldMs; OutputDir=$Directory; StopFile=$StopFile}
}

function Get-ExternalAdt {
    # Read-only process inventory; unavailable inventory blocks streaming rather than guessing.
    # WMI through .NET: Get-CimInstance needs the CimCmdlets module, which may fail to load.
    Add-Type -AssemblyName System.Management
    $searcher = New-Object Management.ManagementObjectSearcher "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='javaw.exe' OR Name='java.exe'"
    try {
        @($searcher.Get() | Where-Object {
            [string]$_['CommandLine'] -match 'org\.adtpro\.ADTPro|ADTPro[^;]*\.jar' -and ($null -eq $Active -or [int]$_['ProcessId'] -ne $Active.Process.Id)
        })
    } finally { $searcher.Dispose() }
}

function Start-LauncherSession([string]$Kind, $Profile, [string]$Target = '') {
    if ($null -ne $Active) { throw 'Stop the current session before launching another.' }
    $p = ConvertTo-Profile $Profile
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $stop = Join-Path $DataDir "$id.stop"
    $stdout = Join-Path $DataDir "$id.log"
    $stderr = Join-Path $DataDir "$id.error.log"
    $exe = $PowerShell; $working = $Project
    $previewDir=Join-Path $DataDir $id
    switch ($Kind) {
        {$_ -in @('ZBuild','ZEmulate','ZPrepare','ZTerminal','ZProbe','ZUpload','ZInspect','ZRun','ZQuit','ZSendHex','ZCardProbe','ZCpmBoot')} {
            if($Kind -notin @('ZBuild','ZEmulate','ZPrepare')) {
                if(@(Get-ExternalAdt).Count -gt 0){throw 'Close the external ADTPro instance before using CP/M serial.'}
                if($p.CpmPort -notin [IO.Ports.SerialPort]::GetPortNames()){throw "$($p.CpmPort) is not listed by Windows."}
            }
            $config=Get-Z80Config $p $Kind $previewDir $stop
            $null=New-Item -ItemType Directory -Path $previewDir -Force
            $configPath=Join-Path $previewDir 'config.json'
            Save-JsonAtomic $configPath $config
            $command=New-ScriptCommand (Join-Path $Project 'pc\z80.ps1') @{Config=$configPath}
        }
        {$_ -in @('HiPreview','HiStream','HiBootstrap')} {
            if($Kind -ne 'HiPreview') {
                if(@(Get-ExternalAdt).Count -gt 0){throw 'Close the external ADTPro instance before using Hi-Res serial.'}
                if($p.HiPort -notin [IO.Ports.SerialPort]::GetPortNames()){throw "$($p.HiPort) is not listed by Windows."}
            }
            $parameters=Get-HiArguments $p $Kind $previewDir $stop
            $command=New-ScriptCommand (Join-Path $Project 'pc\hires.ps1') $parameters
        }
        {$_ -in @('VsDeploy','VsRestore')} {
            # Rewrites the VSDRIVE image ADTPro serves, so ADTPro must be closed; never opens a serial port.
            if(@(Get-ExternalAdt).Count -gt 0){throw 'Close ADTPro before changing its VSDRIVE image.'}
            $config=Get-VsConfig $p $Kind $previewDir $stop
            $null=New-Item -ItemType Directory -Path $previewDir -Force
            $configPath=Join-Path $previewDir 'config.json'
            Save-JsonAtomic $configPath $config
            $command=New-ScriptCommand (Join-Path $Project 'pc\vsdrive.ps1') @{Config=$configPath}
        }
        {$_ -in @('FgBoot','FgBuild','FgCheck')} {
            # Farglade OS, the sibling project. Only FgBoot opens a serial port.
            if($Kind -eq 'FgBoot') {
                if(@(Get-ExternalAdt).Count -gt 0){throw 'Close the external ADTPro instance before booting Farglade OS.'}
                if($p.FgPort -notin [IO.Ports.SerialPort]::GetPortNames()){throw "$($p.FgPort) is not listed by Windows."}
            }
            $config=Get-FargladeConfig $p $Kind $Target $previewDir $stop
            $null=New-Item -ItemType Directory -Path $previewDir -Force
            $configPath=Join-Path $previewDir 'config.json'
            Save-JsonAtomic $configPath $config
            $command=New-ScriptCommand (Join-Path $Project 'pc\farglade.ps1') @{Config=$configPath}
        }
        {$_ -in @('TapeFetch','TapeImport')} {
            # Tape actions only download or convert audio; they never open a serial port.
            $config=Get-TapeConfig $Kind $Target $previewDir $stop
            $null=New-Item -ItemType Directory -Path $previewDir -Force
            $configPath=Join-Path $previewDir 'config.json'
            Save-JsonAtomic $configPath $config
            $command=New-ScriptCommand (Join-Path $Project 'pc\tape.ps1') @{Config=$configPath}
        }
        'Stream' {
            if (@(Get-ExternalAdt).Count -gt 0) { throw 'An ADTPro instance started outside this launcher is running. Close it or disconnect it and close the application first; this launcher will not terminate it.' }
            if ($p.Port -notin [IO.Ports.SerialPort]::GetPortNames()) { throw "$($p.Port) is not listed by Windows. Connect the adapter and check Device Manager." }
            $parameters = Get-StreamArguments $p $stop
            $command = New-ScriptCommand (Join-Path $Project 'pc\a2mc_stream.ps1') $parameters
        }
        'Offline' { $command = New-ScriptCommand (Join-Path $Project 'pc\a2mc_stream.ps1') @{Demo=$true; DryRun=$true; Mode='DlgrC'} }
        'Diagnostics' { $command = New-ScriptCommand (Join-Path $Project 'launcher\diagnostics.ps1') @{} }
        'ADTPro' {
            if (@(Get-ExternalAdt).Count -gt 0) { throw 'ADTPro is already open outside this launcher. Close it before launching a managed instance.' }
            foreach ($file in (@($Javaw) + $AdtJars)) { if (-not (Test-FilePath $file)) { throw "Missing ADTPro dependency: $file" } }
            $exe = $Javaw; $working = $AdtDir
            $arguments = '-Xms128m -Xmx256m -cp "' + ($AdtJars -join ';') + '" org.adtpro.ADTPro'
        }
        default { throw 'Unknown session action.' }
    }
    if ($Kind -ne 'ADTPro') {
        $runner = Join-Path $DataDir "$id.runner.ps1"
        [IO.File]::WriteAllText($runner, $command, (New-Object Text.UTF8Encoding $false))
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '"'
    }
    $entry = [pscustomobject]@{ Id=$id; Started=(Get-Date).ToString('o'); Ended=''; Kind=$Kind; Profile=$p.Name; Settings=$p; Status='Running'; ExitCode=$null; Log=$stdout; ErrorLog=$stderr; Version=$Version; PreviewDir=$previewDir }
    $job = $null; $proc = $null
    try {
        if ($Kind -ne 'ADTPro') {
            if (-not ('A2mcProcessJob' -as [type])) { Add-Type -Path (Join-Path $Project 'launcher\process-job.cs') }
            $job = New-Object A2mcProcessJob
        }
        $proc = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $working -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        # Retain the native handle so ExitCode remains available after the child exits.
        $null = $proc.Handle
        if ($null -ne $job -and -not $proc.HasExited) { $job.Attach($proc) }
    } catch {
        if ($null -ne $proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
        if ($null -ne $job) { $job.Dispose() }
        throw
    }
    $script:Active = @{Process=$proc; Job=$job; Entry=$entry; StopFile=$stop; StopRequested=$null; Forced=$false}
    $script:History = @($entry) + @($History | Select-Object -First 499)
    Save-JsonAtomic (Join-Path $DataDir 'history.json') @($History)
}

function Request-SessionStop {
    if ($null -eq $Active -or $Active.Process.HasExited) { return }
    if ($null -ne $Active.StopRequested) { return }
    if ($Active.Entry.Kind -eq 'ADTPro') {
        if (-not $Active.Process.CloseMainWindow()) { throw 'ADTPro has no responsive main window yet. Close it in its own window, then retry.' }
    } elseif ($Active.Entry.Kind -in @('Stream','HiPreview','HiStream','HiBootstrap') -or $Active.Entry.Kind -like 'Z*' -or $Active.Entry.Kind -like 'Tape*' -or $Active.Entry.Kind -like 'Fg*') {
        [IO.File]::WriteAllText($Active.StopFile, 'stop')
    } else {
        $Active.Process.Kill()
    }
    $Active.StopRequested = Get-Date
}

function Update-Session {
    if ($null -eq $Active) { return $false }
    $Active.Process.Refresh()
    if (-not $Active.Process.HasExited) {
        # A blocked serial write can take 5s; allow cleanup before terminating our own streamer.
        if (($Active.Entry.Kind -in @('Stream','HiPreview','HiStream','HiBootstrap') -or $Active.Entry.Kind -like 'Z*' -or $Active.Entry.Kind -like 'Tape*' -or $Active.Entry.Kind -like 'Fg*') -and $null -ne $Active.StopRequested -and ((Get-Date) - $Active.StopRequested).TotalSeconds -gt 8) {
            $Active.Process.Kill(); $Active.Forced = $true
        }
        return $false
    }
    $Active.Process.WaitForExit()
    $entry = $Active.Entry
    $entry.Ended = (Get-Date).ToString('o'); $entry.ExitCode = $Active.Process.ExitCode
    $entry.Status = if ($Active.Forced) { 'Force stopped' } elseif ($null -ne $Active.StopRequested) { 'Stopped' } elseif ($entry.ExitCode -eq 0) { 'Completed' } else { 'Failed' }
    Save-JsonAtomic (Join-Path $DataDir 'history.json') @($History)
    if (Test-Path -LiteralPath $Active.StopFile) { Remove-Item -LiteralPath $Active.StopFile }
    $Active.Process.Dispose()
    if ($null -ne $Active.Job) { $Active.Job.Dispose() }
    $script:Active = $null
    return $true
}

function Read-SessionLog($Entry) {
    $result = ''
    foreach ($path in @($Entry.Log, $Entry.ErrorLog)) {
        if (Test-Path -LiteralPath $path) { $result += ((Get-Content -LiteralPath $path -Tail 100 -ErrorAction Stop) -join "`r`n") + "`r`n" }
    }
    if ([string]::IsNullOrWhiteSpace($result)) { return 'Waiting for process output. ADTPro uses its own window for transfer activity.' }
    return $result
}

function Get-Z80Config($Profile,[string]$Kind,[string]$Directory,[string]$StopFile) {
    $p=ConvertTo-Profile $Profile
    $action=$Kind.Substring(1)
    if($action -notin @('Build','Emulate','Prepare','Terminal','Probe','Upload','Inspect','Run','Quit','SendHex','CardProbe','CpmBoot')){throw 'Unknown Z80 action.'}
    $inputField=switch($action){'Build'{'CpmSource'} 'Emulate'{'CpmBinary'} 'Upload'{'CpmBinary'} 'Prepare'{'CpmDisk'} 'CpmBoot'{'CpmDisk'} 'SendHex'{'CpmHex'}}
    if($inputField -and -not (Test-FilePath $p.$inputField)){throw $(switch($inputField){'CpmSource'{'Choose an existing Z80 source file.'} 'CpmBinary'{'Assemble a module or choose a previous build first.'} 'CpmDisk'{'Choose an existing CP/M disk image first.'} 'CpmHex'{'Choose an existing Intel HEX file first.'}})}
    if($action -in @('Emulate','Upload') -and $p.CpmTarget -ne 'Module'){throw 'Select Module and build an ORG 0x4000 program. CP/M COM programs run from disk.'}
    if($action -eq 'CpmBoot' -and $p.CpmDiskB -and -not (Test-FilePath $p.CpmDiskB)){throw 'The B: disk image does not exist. Clear the field or choose another image.'}
    return @{DiskB=$p.CpmDiskB;BootBaud=$p.CpmBootBaud;Writes=$(if($p.CpmWrites -eq 'Read only'){'ReadOnly'}else{'Save'});BackupDir=(Join-Path $DataDir 'cpm-backups');Action=$action;OutputDir=$Directory;StopFile=$StopFile;Source=$p.CpmSource;Target=$p.CpmTarget;Binary=$p.CpmBinary;HexFile=$p.CpmHex;Disk=$p.CpmDisk;CpmVersion=$p.CpmVersion;Command=$p.CpmCommand;Notes=$p.CpmNotes;Port=$p.CpmPort;Baud=$p.CpmBaud;Handshake=$p.CpmHandshake;Offset=$p.CpmOffset;Count=$p.CpmCount;Slot=$p.CpmSlot}
}

function Get-VsConfig($Profile,[string]$Kind,[string]$Directory,[string]$StopFile) {
    $p=ConvertTo-Profile $Profile
    $action=switch($Kind){'VsDeploy'{'Deploy'} 'VsRestore'{'Restore'} default{throw 'Unknown VSDRIVE action.'}}
    if(-not (Test-FilePath $p.VsImage)){throw 'Choose the VSDRIVE image ADTPro serves, such as disks\Virtual2.po.'}
    if([IO.Path]::GetExtension($p.VsImage) -ne '.po'){throw 'Choose a ProDOS-ordered VSDRIVE image (.po).'}
    # The same Java and AppleCommander as build.ps1 and the quick-start's manual deploy.
    $java=Join-Path (Split-Path -Parent $Javaw) 'java.exe'
    return @{Action=$action;Image=[IO.Path]::GetFullPath($p.VsImage);Set=$p.VsSet;BuildDir=(Join-Path $Project "build\$Version");BackupDir=(Join-Path $DataDir 'vsdrive-backups');Java=$java;Jar=(Join-Path $Workspace 'Projects\adtpro-v_2_1_0\build\lib\AppleCommander\AppleCommander-1.3.5.13-ac.jar');OutputDir=$Directory;StopFile=$StopFile}
}

function Get-FargladeVersion {
    # Farglade OS has its own VERSION file. Empty when the sibling project is not there.
    $file=Join-Path $FargladeDir 'VERSION'
    if(-not (Test-FilePath $file) -or -not (Test-FilePath (Join-Path $FargladeDir 'tools\uplink.py'))){return ''}
    $text=(Get-Content -LiteralPath $file -Raw).Trim()
    if($text -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'){return ''}
    return $text
}

function Test-FargladeBuilt {
    $version=Get-FargladeVersion
    if(-not $version){return $false}
    $build=Join-Path $FargladeDir "build\$version"
    (Test-FilePath (Join-Path $build 'FGBOOT.BIN')) -and (Test-FilePath (Join-Path $build 'HEARTH.BIN')) -and (Test-FilePath (Join-Path $build 'pack\glade\sys\glade.bin'))
}

function Get-FargladeConfig($Profile,[string]$Kind,[string]$Target,[string]$Directory,[string]$StopFile) {
    $p=ConvertTo-Profile $Profile
    $action=switch($Kind){'FgBoot'{'Boot'} 'FgBuild'{'Build'} 'FgCheck'{'Check'} default{throw 'Unknown Farglade action.'}}
    if(-not (Get-FargladeVersion)){throw "Farglade OS was not found at $FargladeDir."}
    if($action -ne 'Build' -and -not (Test-FargladeBuilt)){throw 'Farglade OS is not built yet. Use BUILD FARGLADE OS first.'}
    # Opening the far roads to every host is chosen for one boot, on the screen; it is never a profile field.
    if($Target -cnotin @('','OpenRoads')){throw 'Unknown Farglade option.'}
    return @{Action=$action;Root=$FargladeDir;Port=$p.FgPort;Slot=$p.FgSlot;Baud=$p.FgBaud;Reduced=$p.FgReduced;Mute=$p.FgMute;Net=($action -eq 'Boot' -and $Target -ceq 'OpenRoads');NetHosts=$p.FgNetHosts;RelayHosts=$p.FgRelayHosts;OutputDir=$Directory;StopFile=$StopFile}
}

function Initialize-CpmLibrary {
    $script:CpmLibrary=@()
    $path=Join-Path $DataDir 'cpm-library.json'
    if(-not (Test-Path -LiteralPath $path)) {
        $older=Get-ChildItem (Join-Path $Project 'build') -Directory | Where-Object {$_.Name -match '^\d+\.\d+\.\d+$' -and [version]$_.Name -lt [version]$Version} | Sort-Object {[version]$_.Name} -Descending
        foreach($dir in $older){$candidate=Join-Path $dir.FullName 'launcher\cpm-library.json'; if(Test-Path -LiteralPath $candidate){$path=$candidate;break}}
    }
    try {
        if(Test-Path -LiteralPath $path){$script:CpmLibrary=@((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) | ForEach-Object {ConvertTo-Profile $_})}
    } catch {$script:StoreWarning+=" Could not read CP/M library; original preserved at $path."; $script:CpmLibrary=@()}
}

function Save-CpmLibraryEntry($Profile) {
    $p=ConvertTo-Profile $Profile
    if([string]::IsNullOrWhiteSpace($p.CpmTitle)){throw 'Enter a library title.'}
    if(-not (Test-FilePath $p.CpmDisk)){throw 'Choose an existing disk image.'}
    $script:CpmLibrary=@($CpmLibrary | Where-Object {$_.CpmTitle -ne $p.CpmTitle}) + @($p)
    Save-JsonAtomic (Join-Path $DataDir 'cpm-library.json') @($CpmLibrary)
}

function New-TapeEntry {
    [pscustomobject][ordered]@{ Title = ''; File = ''; Sha256 = ''; Source = ''; Format = 'WAV'; Seconds = 0.0; LoadCommand = 'LOAD'; Notes = '' }
}

function ConvertTo-TapeEntry($InputEntry) {
    # Whitelist fields, including library files from disk; a tape entry never carries arguments or scripts.
    $t = New-TapeEntry
    foreach ($field in $t.PSObject.Properties.Name) {
        if ($null -ne $InputEntry.PSObject.Properties[$field]) { $t.$field = $InputEntry.$field }
    }
    foreach ($field in @('Title','File','Sha256','Source','Format','LoadCommand','Notes')) {
        $t.$field = [string]$t.$field
        if ($t.$field.Length -gt 1024 -or $t.$field -match '[\x00-\x1f]') { throw "Invalid tape $field text." }
    }
    $t.Title = $t.Title.Trim()
    if ([string]::IsNullOrWhiteSpace($t.Title) -or $t.Title.Length -gt 80) { throw 'Tape title must contain 1-80 characters.' }
    if ($t.LoadCommand.Length -gt 200) { throw 'Load command must be at most 200 characters.' }
    if ($t.Format -cnotin @('WAV','MP3')) { throw 'Tape format must be WAV or MP3.' }
    $t.Sha256 = $t.Sha256.ToLowerInvariant()
    if ($t.Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Tape SHA-256 is missing or malformed; add the audio file again.' }
    if (-not [IO.Path]::IsPathRooted($t.File) -or [IO.Path]::GetExtension($t.File) -notin @('.wav','.mp3')) { throw 'Tape file must be a full path to a .wav or .mp3 file.' }
    if ($t.File.Contains('#')) { throw 'Rename or move the audio file: Windows media playback cannot open paths containing #.' }
    $seconds = 0.0
    if (-not [double]::TryParse([string]$t.Seconds, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -or [double]::IsNaN($seconds) -or $seconds -lt 0 -or $seconds -gt 86400) { throw 'Tape length must be between 0 and 86400 seconds.' }
    $t.Seconds = $seconds
    return $t
}

function Get-TapeConfig([string]$Kind, [string]$Target, [string]$Directory, [string]$StopFile) {
    $config = @{ OutputDir = $Directory; CacheDir = (Join-Path $DataDir 'tapes'); StopFile = $StopFile }
    switch ($Kind) {
        'TapeFetch' {
            $Target = $Target.Trim()
            if ($Target.Length -gt 2048 -or $Target -cnotmatch '^https://[^\s/?#@]+/\S*$') { throw 'Paste an https:// link to a WAV, AIFF or MP3 file.' }
            $config.Action = 'Fetch'; $config.Url = $Target
        }
        'TapeImport' {
            if (-not (Test-FilePath $Target)) { throw 'Choose an existing audio file.' }
            $config.Action = 'Import'; $config.File = [IO.Path]::GetFullPath($Target)
        }
        default { throw 'Unknown tape action.' }
    }
    return $config
}

function Read-JsonUtf8([string]$Path) {
    # UTF-8 explicitly: Windows PowerShell 5.1 otherwise reads BOM-less files as ANSI.
    [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Read-TapeJson([string]$Path) { Read-JsonUtf8 $Path }

function Initialize-TapeLibrary {
    $script:TapeLibrary = @()
    $path = Join-Path $DataDir 'tape-library.json'
    if (-not (Test-Path -LiteralPath $path)) {
        # Carry the library forward from the latest older release, without writing there.
        $older = Get-ChildItem (Join-Path $Project 'build') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and [version]$_.Name -lt [version]$Version } | Sort-Object { [version]$_.Name } -Descending
        foreach ($dir in $older) {
            $candidate = Join-Path $dir.FullName 'launcher\tape-library.json'
            if (Test-Path -LiteralPath $candidate) { $path = $candidate; break }
        }
    }
    try {
        if (Test-Path -LiteralPath $path) { $script:TapeLibrary = @((Read-TapeJson $path) | ForEach-Object { ConvertTo-TapeEntry $_ }) }
    } catch { $script:StoreWarning += " Could not read the tape library; original preserved at $path."; $script:TapeLibrary = @() }
}

function Get-ReceiverTapes([string]$BuildDir = (Join-Path $Project "build\$Version")) {
    # Generated from this release's build; expected hashes come from build provenance, not from the WAVs.
    $stamp = Join-Path $BuildDir 'build-manifest.json'
    $bin = Join-Path $BuildDir 'A2MC-RX.BIN'
    if (-not (Test-FilePath $stamp) -or -not (Test-FilePath $bin)) { return }
    $artifacts = (Read-TapeJson $stamp).artifacts
    # c2t loads the headerless receiver at $1000; the monitor range ends at its last byte.
    $end = '{0:X}' -f (0x1000 + (Get-Item -LiteralPath $bin).Length - 1)
    $specs = @(
        @('a2mc-rx.wav', 'autoload', 'LOAD', 'No DOS: remove disks, power on, Ctrl-Reset to the ] prompt, type LOAD, press Return, then Play. The receiver starts by itself. Without ProDOS, Esc in the receiver jumps to an unset BASIC re-entry vector; press Ctrl-Reset after quitting.'),
        @('a2mc-rx-manual.wav', 'monitor load', "CALL -151, then 1000.${end}R, Play, then 1000G", 'Use from the ProDOS BASIC prompt so Esc returns to BASIC normally. CALL 4096 restarts the receiver from RAM afterwards.')
    )
    foreach ($spec in $specs) {
        $file = Join-Path $BuildDir $spec[0]
        $hash = $artifacts.PSObject.Properties[$spec[0]]
        if ((Test-FilePath $file) -and $null -ne $hash) {
            ConvertTo-TapeEntry ([pscustomobject]@{ Title = "A2MC receiver $Version / $($spec[1])"; File = $file; Sha256 = [string]$hash.Value; Source = 'This release (build.ps1 / c2t)'; Format = 'WAV'; LoadCommand = $spec[2]; Notes = $spec[3] })
        }
    }
}

function Save-TapeEntry($Entry) {
    $t = ConvertTo-TapeEntry $Entry
    if (@(Get-ReceiverTapes | Where-Object { $_.Title -eq $t.Title }).Count -gt 0) { throw 'Receiver tapes are generated from this release build; save under a different title.' }
    if (-not (Test-FilePath $t.File)) { throw 'The tape audio file no longer exists; add it again.' }
    $script:TapeLibrary = @($TapeLibrary | Where-Object { $_.Title -ne $t.Title }) + @($t)
    Save-JsonAtomic (Join-Path $DataDir 'tape-library.json') @($TapeLibrary)
    return $t
}

function Remove-TapeEntry([string]$Title) {
    if (@(Get-ReceiverTapes | Where-Object { $_.Title -eq $Title }).Count -gt 0) { throw 'Receiver tapes come from this release build and cannot be removed.' }
    if (@($TapeLibrary | Where-Object { $_.Title -eq $Title }).Count -eq 0) { throw 'Select a saved library entry first.' }
    $script:TapeLibrary = @($TapeLibrary | Where-Object { $_.Title -ne $Title })
    Save-JsonAtomic (Join-Path $DataDir 'tape-library.json') @($TapeLibrary)
}

function Test-TapeFile($Entry) {
    # Play only the exact bytes recorded when the tape was added or built.
    $t = ConvertTo-TapeEntry $Entry
    if (-not (Test-FilePath $t.File)) { throw "Tape audio is missing: $($t.File)" }
    $actual = Get-Sha256 $t.File
    if ($actual -cne $t.Sha256) { throw 'Tape audio changed since it was added or built (SHA-256 mismatch). Add it again, or rebuild this release.' }
    return $t
}

$script:ThemeKeys = @('Bg','Fg','Dim','Sel','OnSel','Pri','OnPri','Key','OnKey','Bar','OnBar','Meter','C1','C2','C3','C4','C5','Glow')

function Get-LauncherThemes {
    # Monitor palettes are data; reject a damaged file rather than drawing unreadable colors.
    $table = Read-JsonUtf8 (Join-Path $PSScriptRoot 'themes.json')
    $order = @($table.order)
    if ($order.Count -eq 0) { throw 'themes.json lists no monitor themes.' }
    foreach ($name in $order) {
        $theme = $table.themes.PSObject.Properties[$name]
        if ($null -eq $theme) { throw "themes.json is missing the $name theme." }
        foreach ($key in $ThemeKeys) {
            $value = $theme.Value.PSObject.Properties[$key]
            if ($null -eq $value -or [string]$value.Value -cnotmatch '^#[0-9A-F]{6}$') { throw "themes.json: $name needs $key as #RRGGBB." }
        }
    }
    if (@($table.lores).Count -ne 16) { throw 'themes.json must list the 16 lo-res colors.' }
    return $table
}

function New-LauncherSettings {
    [pscustomobject][ordered]@{ Monitor = 'Green'; Scanlines = $true }
}

function ConvertTo-LauncherSettings($InputSettings) {
    # Launcher-wide display settings; whitelisted like profiles and independent of them.
    $s = New-LauncherSettings
    if ($null -ne $InputSettings) {
        foreach ($field in $s.PSObject.Properties.Name) {
            if ($null -ne $InputSettings.PSObject.Properties[$field]) { $s.$field = $InputSettings.$field }
        }
    }
    $s.Monitor = [string]$s.Monitor
    if ($s.Monitor -cnotin @('Green','Amber','White','Color')) { throw 'Monitor must be Green, Amber, White or Color.' }
    if ($s.Scanlines -isnot [bool]) { throw 'Scanlines must be true or false.' }
    return $s
}

function Initialize-LauncherSettings {
    $path = Join-Path $DataDir 'launcher-settings.json'
    if (-not (Test-Path -LiteralPath $path)) {
        # Carry settings forward from the latest older release, without writing there.
        $older = Get-ChildItem (Join-Path $Project 'build') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and [version]$_.Name -lt [version]$Version } | Sort-Object { [version]$_.Name } -Descending
        foreach ($dir in $older) {
            $candidate = Join-Path $dir.FullName 'launcher\launcher-settings.json'
            if (Test-Path -LiteralPath $candidate) { $path = $candidate; break }
        }
    }
    try {
        $script:LauncherSettings = if (Test-Path -LiteralPath $path) { ConvertTo-LauncherSettings (Read-JsonUtf8 $path) } else { New-LauncherSettings }
    } catch { $script:StoreWarning += " Could not read launcher settings; original preserved at $path."; $script:LauncherSettings = New-LauncherSettings }
}

function Save-LauncherSettings($Settings) {
    $s = ConvertTo-LauncherSettings $Settings
    Save-JsonAtomic (Join-Path $DataDir 'launcher-settings.json') $s
    $script:LauncherSettings = $s
}
