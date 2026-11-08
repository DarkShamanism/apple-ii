[CmdletBinding()]
param([switch]$RenderPreview, [switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
. (Join-Path $PSScriptRoot 'launcher\core.ps1')

# One supervisor per checkout, including launches from another working directory.
$hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Project.ToLowerInvariant()))).Replace('-', '')
if($SmokeTest -or $RenderPreview){$hash+='-Test'}
$mutex = New-Object Threading.Mutex($false, "Local\A2MC-$hash")
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'This launcher is already running for this project.' }
    if ($SmokeTest) { $script:DataDir = Join-Path $Project "build\$Version\launcher-smoke" }
    Initialize-Store
    [xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'launcher\launcher.xaml') -Raw
    $reader = New-Object Xml.XmlNodeReader $xaml
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)
    $script:UI = @{}
    foreach ($node in $xaml.SelectNodes('//*[@Name]')) { $UI[$node.Name] = $Window.FindName($node.Name) }
    $script:NextAction = $null
    $script:Closing = $false
    $script:LoadingProfile = $false
    $script:ElapsedStart = $null
    $script:LastHiDir = $null
    $script:LastHiStamp = ''
    $UI.VersionText.Text = "V$LauncherVersion"
    $Window.Title = "$LauncherName $LauncherVersion"

    foreach ($field in @('Source','Baud','Mode','Fit','AuxRotate')) {
        $choices = switch ($field) { 'Source' { @('Minecraft','Demo','Image') } 'Baud' { @('115200','19200') } 'Mode' { @('DlgrC','Dlgr','Lores') } 'Fit' { @('Crop','Stretch','Letterbox') } 'AuxRotate' { @('Left','Right','None') } }
        foreach ($choice in $choices) { $null = $UI["${field}Field"].Items.Add($choice) }
    }
    foreach($choice in @('Receiver only','All receivers')){$null=$UI.VsSetField.Items.Add($choice)}
    foreach($field in @('HiSource','HiBaud','HiSlot','HiFit','HiPages','HiKeys')) {
        $choices=switch($field){'HiSource'{@('Demo','Window','Desktop','Image')} 'HiBaud'{@('115200','19200')} 'HiSlot'{@('1','2','3','4','5','6','7')} 'HiFit'{@('Letterbox','Crop','Stretch')} 'HiPages'{@('Packed','Raw')} 'HiKeys'{@('Off','Log','Minecraft')}}
        foreach($choice in $choices){$null=$UI["${field}Field"].Items.Add($choice)}
    }
    function Set-Status([string]$Text) { $UI.Status.Text = $Text; $UI.Status.ToolTip = $Text }
    function Show-Error($Problem) {
        Set-Status "Error: $Problem"
        $UI.LiveLog.Text = "ERROR: $Problem`r`n" + $UI.LiveLog.Text
        if (-not $SmokeTest -and -not $RenderPreview) { $null = [Windows.MessageBox]::Show($Window, [string]$Problem, $LauncherName, 'OK', 'Warning') }
    }
    function Show-Profile($p) {
        $script:LoadingProfile = $true
        try {
            foreach ($field in $p.PSObject.Properties.Name) {
                $control = $UI["${field}Field"]
                if ($control -is [Windows.Controls.ComboBox] -and $control.IsEditable) { $control.Text = [string]$p.$field }
                elseif ($control -is [Windows.Controls.ComboBox]) { $control.SelectedItem = [string]$p.$field }
                elseif ($control -is [Windows.Controls.CheckBox]) { $control.IsChecked = [bool]$p.$field }
                elseif ($null -ne $control) { $control.Text = [Convert]::ToString($p.$field, [Globalization.CultureInfo]::InvariantCulture) }
            }
            Update-Summary $p
        } finally { $script:LoadingProfile = $false }
    }
    function Read-Profile {
        $p = New-Profile
        foreach ($field in $p.PSObject.Properties.Name) {
            $control = $UI["${field}Field"]
            if ($control -is [Windows.Controls.ComboBox] -and $control.IsEditable) { $p.$field = $control.Text }
            elseif ($control -is [Windows.Controls.ComboBox]) { $p.$field = [string]$control.SelectedItem }
            elseif ($control -is [Windows.Controls.CheckBox]) { $p.$field = [bool]$control.IsChecked }
            else { $p.$field = $control.Text }
        }
        ConvertTo-Profile $p
    }
    function Update-Summary($p) {
        $UI.ProfileSummary.Text = "PROFILE: $($p.Name.ToUpperInvariant())"
        $UI.PortSummary.Text = if($null -ne $Active -and $Active.Entry.Kind -like 'Z*'){"CP/M: $($p.CpmPort) / $($p.CpmBaud)"}elseif($null -ne $Active -and $Active.Entry.Kind -like 'Fg*'){"FARGLADE: $($p.FgPort) / $($p.FgBaud)"}else{"PORT: $($p.Port) / $($p.Baud)"}
        $UI.VideoSummary.Text = "$($p.Mode) / $($p.Fps) FPS"
        $UI.LinkSummary.Text = "$($p.Port) / $($p.Baud)"
        $UI.SourceSummary.Text = $p.Source
    }
    function Refresh-Profiles([string]$SelectedName) {
        $UI.ProfileList.ItemsSource = $null
        $UI.ProfileList.ItemsSource = @($Profiles)
        $selected = $Profiles | Where-Object { $_.Name -eq $SelectedName } | Select-Object -First 1
        if ($null -eq $selected) { $selected = $Profiles[0] }
        $UI.ProfileList.SelectedItem = $selected
        Show-Profile $selected
    }
    function Refresh-History {
        $rows = @($History | ForEach-Object { [pscustomobject]@{Label = "$($_.Started.Substring(0,19).Replace('T',' '))  |  $($_.Kind)  |  $($_.Profile)  |  $($_.Status)"; Entry = $_} })
        $UI.HistoryList.ItemsSource = $rows
    }
    function Refresh-Ports {
        $ports = [IO.Ports.SerialPort]::GetPortNames() | Sort-Object
        $UI.DiagnosticsPorts.Text = 'Windows port names: ' + $(if ($ports) { $ports -join ', ' } else { '(none found)' }) + '. Ownership: not probed.'
    }
    function Invoke-Launch([string]$Kind, $p, [string]$Target = '') {
        Start-LauncherSession $Kind $p $Target
        $script:ElapsedStart = Get-Date
        Update-Summary $p
        Refresh-History
        if($Kind -like 'Hi*') {
            $UI.Tabs.SelectedItem=$UI.HiTab; $script:LastHiDir=$Active.Entry.PreviewDir; $script:LastHiStamp=''
            $UI.HiStatus.Text="$Kind started / $($p.HiPort) / $($p.HiBaud) baud"
        } elseif($Kind -like 'Z*') {$UI.Tabs.SelectedItem=$UI.CpmTab} elseif($Kind -like 'Tape*') {$UI.Tabs.SelectedItem=$UI.TapeTab} elseif($Kind -like 'Fg*') {$UI.Tabs.SelectedItem=$UI.FgTab} else { $UI.Tabs.SelectedIndex = 0 }
        Set-Status "$Kind started. Settings are captured in session history."
    }
    function Invoke-Handoff([string]$Kind) {
        $p = Read-Profile
        if ($null -eq $Active) { Invoke-Launch $Kind $p; return }
        if (($Kind -in @('Stream','HiStream','ZTerminal') -and $Active.Entry.Kind -ne 'ADTPro') -or ($Kind -eq 'ADTPro' -and $Active.Entry.Kind -notin @('Stream','HiStream','HiPreview') -and $Active.Entry.Kind -notlike 'Z*')) { throw 'This handoff requires an active ADTPro, stream or CP/M session.' }
        Request-SessionStop
        $script:NextAction = @{Kind=$Kind; Profile=$p}
        Set-Status 'Waiting for the current process to exit before handoff. Finish or dismiss any ADTPro dialog.'
    }
    function Choose-JsonFile([bool]$Save, [string]$Name) {
        $dialog = if ($Save) { New-Object Microsoft.Win32.SaveFileDialog } else { New-Object Microsoft.Win32.OpenFileDialog }
        $dialog.Filter = 'JSON files (*.json)|*.json'; $dialog.InitialDirectory = $DataDir; $dialog.FileName = $Name
        if ($dialog.ShowDialog($Window)) { return $dialog.FileName }
        return $null
    }
    function Add-Click([string]$Name, [scriptblock]$Handler) {
        # Keep the callback in a closure; report errors instead of crashing the dispatcher.
        $callback = { try { & $Handler } catch { Show-Error (Format-LauncherError $_) } }.GetNewClosure()
        $UI[$Name].Add_Click($callback)
    }
    $UI.ProfileList.Add_SelectionChanged({ if ($null -ne $UI.ProfileList.SelectedItem) { Show-Profile $UI.ProfileList.SelectedItem } })
    $UI.BaudField.Add_SelectionChanged({ if (-not $LoadingProfile) { $UI.FpsField.Text = if ([string]$UI.BaudField.SelectedItem -eq '19200') { '1.5' } else { '10' } } })
    $UI.HiBaudField.Add_SelectionChanged({if(-not $LoadingProfile){$UI.HiFpsField.Text=if([string]$UI.HiBaudField.SelectedItem -eq '19200'){'1'}else{'6'}}})
    Add-Click 'HiPreview' {Invoke-Launch 'HiPreview' (Read-Profile)}
    Add-Click 'HiStream' {Invoke-Launch 'HiStream' (Read-Profile)}
    Add-Click 'HiBootstrap' {Invoke-Launch 'HiBootstrap' (Read-Profile)}
    Add-Click 'HiStop' {$script:NextAction=$null; Request-SessionStop; Set-Status 'Stopping the managed session before releasing its port.'}
    Add-Click 'HiFromAdt' {Invoke-Handoff 'HiStream'}
    Add-Click 'HiToAdt' {Invoke-Handoff 'ADTPro'}
    Add-Click 'HiSave' {$UI.SaveProfile.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))}
    Add-Click 'HiGuide' {Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $Project 'docs\HIRES.md')+'"')}
    Add-Click 'HiWindows' {
        $old=$UI.HiWindowTitleField.Text; $UI.HiWindowTitleField.Items.Clear()
        Get-Process | Where-Object {$_.MainWindowHandle -ne 0 -and $_.Id -ne $PID} | Sort-Object MainWindowTitle | ForEach-Object {$null=$UI.HiWindowTitleField.Items.Add($_.MainWindowTitle)}
        $UI.HiWindowTitleField.Text=$old; $UI.HiSourceField.SelectedItem='Window'
        Set-Status 'Select a title from the refreshed list; keep that window uncovered during capture.'
    }
    Add-Click 'HiBrowse' {$dialog=New-Object Microsoft.Win32.OpenFileDialog; $dialog.Filter='Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif'; if($dialog.ShowDialog($Window)){$UI.HiImageField.Text=$dialog.FileName; $UI.HiSourceField.SelectedItem='Image'}}
    Add-Click 'HiExport' {
        if($null -eq $LastHiDir -or -not (Test-Path (Join-Path $LastHiDir 'frame.bin'))){throw 'Generate a preview frame first.'}
        if($null -ne $Active){throw 'Stop the current session before exporting a consistent HGR/PNG pair.'}
        $dest=Join-Path $DataDir ('export-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')); $null=New-Item -ItemType Directory -Path $dest
        Copy-Item -LiteralPath (Join-Path $LastHiDir 'frame.bin'),(Join-Path $LastHiDir 'preview.png') -Destination $dest
        Set-Status "Saved HGR and PNG: $dest"
        Start-Process explorer.exe -ArgumentList ('"'+$dest+'"')
    }
    Add-Click 'QuickLaunch' { Invoke-Launch 'Stream' (Read-Profile) }
    Add-Click 'QuickDemo' { $p = Read-Profile; $p.Source='Demo'; Invoke-Launch 'Stream' $p }
    Add-Click 'LaunchAdt' { Invoke-Launch 'ADTPro' (Read-Profile) }
    Add-Click 'HandoffStream' { Invoke-Handoff 'Stream' }
    Add-Click 'HandoffAdt' { Invoke-Handoff 'ADTPro' }
    Add-Click 'Stop' { $script:NextAction=$null; Request-SessionStop; Set-Status 'Stop requested. Waiting for process exit; no port availability probe is performed.' }
    Add-Click 'VsDeploy' { Invoke-Launch 'VsDeploy' (Read-Profile) }
    Add-Click 'VsRestore' { Invoke-Launch 'VsRestore' (Read-Profile) }
    Add-Click 'VsBrowse' { $dialog=New-Object Microsoft.Win32.OpenFileDialog; $dialog.Filter='ProDOS VSDRIVE images (*.po)|*.po'; if ($dialog.ShowDialog($Window)) { $UI.VsImageField.Text=$dialog.FileName } }
    Add-Click 'RunDiagnostics' { Invoke-Launch 'Diagnostics' (Read-Profile) }
    Add-Click 'RunOffline' { Invoke-Launch 'Offline' (Read-Profile) }
    Add-Click 'RefreshPorts' { Refresh-Ports; Set-Status 'Refreshed port names without opening them.' }
    Add-Click 'OpenLogs' { Start-Process explorer.exe -ArgumentList ('"' + $DataDir + '"') }
    Add-Click 'OpenBuild' { Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $Project "build\$Version") + '"') }
    Add-Click 'OpenGuide' { Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $Project 'docs\QUICK-START.md') + '"') }
    Add-Click 'SaveProfile' {
        $p = Read-Profile
        $script:Profiles = @($Profiles | Where-Object { $_.Name -ne $p.Name }) + @($p)
        Save-JsonAtomic (Join-Path $DataDir 'profiles.json') @($Profiles)
        Refresh-Profiles $p.Name; Set-Status "Saved profile: $($p.Name)"
    }
    Add-Click 'NewProfile' { $UI.ProfileList.SelectedItem=$null; Show-Profile (New-Profile 'New profile'); Set-Status 'Edit the new profile, then save it.' }
    Add-Click 'DeleteProfile' {
        if ($Profiles.Count -le 1) { throw 'Keep at least one profile.' }
        if ($null -eq $UI.ProfileList.SelectedItem) { throw 'Select a saved profile first.' }
        $name = $UI.ProfileList.SelectedItem.Name
        $script:Profiles = @($Profiles | Where-Object { $_.Name -ne $name })
        Save-JsonAtomic (Join-Path $DataDir 'profiles.json') @($Profiles)
        Refresh-Profiles ''; Set-Status "Deleted $name. The previous profiles file is retained as profiles.json.bak."
    }
    Add-Click 'ImportProfiles' {
        $path = Choose-JsonFile $false ''
        if ($path) {
            $imported = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) | ForEach-Object { ConvertTo-Profile $_ })
            if ($imported.Count -eq 0 -or $imported.Count -gt 100) { throw 'Import requires 1-100 profiles.' }
            foreach ($p in $imported) { $script:Profiles = @($Profiles | Where-Object { $_.Name -ne $p.Name }) + @($p) }
            Save-JsonAtomic (Join-Path $DataDir 'profiles.json') @($Profiles)
            Refresh-Profiles $imported[0].Name; Set-Status 'Imported profiles. Matching names were replaced; the previous file is backed up.'
        }
    }
    Add-Click 'ExportProfiles' { $path = Choose-JsonFile $true 'profiles-export.json'; if ($path) { Save-JsonAtomic $path @($Profiles); Set-Status "Exported profiles: $path" } }
    Add-Click 'ExportHistory' { $path = Choose-JsonFile $true 'history-export.json'; if ($path) { Save-JsonAtomic $path @($History); Set-Status "Exported history: $path" } }
    Add-Click 'BrowseImage' { $dialog=New-Object Microsoft.Win32.OpenFileDialog; $dialog.Filter='Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files|*.*'; if ($dialog.ShowDialog($Window)) { $UI.ImageField.Text=$dialog.FileName; $UI.SourceField.SelectedItem='Image' } }
    Add-Click 'DetectWindow' {
        $games = @(Get-Process | Where-Object { $_.ProcessName -in @('java','javaw','Minecraft.Windows') -and $_.MainWindowTitle -like '*Minecraft*' -and $_.MainWindowTitle -notlike '*Launcher*' })
        if ($games.Count -eq 0) { throw 'No running Minecraft game window was found. Open a world, or enter its title manually.' }
        if ($games.Count -gt 1) { throw ('Multiple Minecraft windows are open. Enter a unique title manually: ' + (($games | ForEach-Object { $_.MainWindowTitle }) -join '; ')) }
        $UI.WindowTitleField.Text=$games[0].MainWindowTitle; $UI.SourceField.SelectedItem='Minecraft'
        Set-Status 'Using the running game window title. Save the profile to keep it.'
    }
    Add-Click 'Preview' { $p=Read-Profile; $params=Get-StreamArguments $p '(managed stop signal)'; $UI.CommandPreview.Text="pc\a2mc_stream.ps1`r`n" + ($params | ConvertTo-Json); Update-Summary $p; Set-Status 'Preview only. No process launched and no serial port opened.' }
    $UI.HistoryList.Add_SelectionChanged({
        try {
            if ($null -ne $UI.HistoryList.SelectedItem) {
                $entry = $UI.HistoryList.SelectedItem.Entry
                $UI.HistoryDetail.Text = ($entry | ConvertTo-Json -Depth 5) + "`r`n`r`n--- JOURNAL (last 100 lines per log) ---`r`n" + (Read-SessionLog $entry)
            }
        } catch { Show-Error (Format-LauncherError $_) }
    })
    Add-Click 'RestoreSession' {
        if ($null -eq $UI.HistoryList.SelectedItem) { throw 'Select a session first.' }
        $p = ConvertTo-Profile $UI.HistoryList.SelectedItem.Entry.Settings
        $UI.ProfileList.SelectedItem=$null; Show-Profile $p
        if($UI.HistoryList.SelectedItem.Entry.Kind -like 'Hi*'){$UI.Tabs.SelectedItem=$UI.HiTab}elseif($UI.HistoryList.SelectedItem.Entry.Kind -like 'Z*'){$UI.Tabs.SelectedItem=$UI.CpmTab}elseif($UI.HistoryList.SelectedItem.Entry.Kind -like 'Tape*'){$UI.Tabs.SelectedItem=$UI.TapeTab}elseif($UI.HistoryList.SelectedItem.Entry.Kind -like 'Fg*'){$UI.Tabs.SelectedItem=$UI.FgTab}elseif($UI.HistoryList.SelectedItem.Entry.Kind -like 'Vs*'){$UI.Tabs.SelectedIndex=0}else{$UI.Tabs.SelectedIndex=1}
        Set-Status 'Restored session settings. Save them as a profile or launch directly.'
    }
    . (Join-Path $PSScriptRoot 'launcher\cpm-ui.ps1')
    . (Join-Path $PSScriptRoot 'launcher\cassette-ui.ps1')
    . (Join-Path $PSScriptRoot 'launcher\farglade-ui.ps1')
    . (Join-Path $PSScriptRoot 'launcher\theme-ui.ps1')
    Refresh-Profiles ''; Refresh-History; Refresh-Ports
    if ($StoreWarning) { Show-Error $StoreWarning }
    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $Timer.Interval = [timespan]::FromMilliseconds(500)
    $Timer.Add_Tick({
        try {
            $wasActive = $null -ne $Active
            if ($wasActive) {
                $entry = $Active.Entry
                $UI.LiveLog.Text = Read-SessionLog $entry
                if($entry.Kind -like 'Hi*'){$UI.HiStatus.Text=($UI.LiveLog.Text.Trim() -split "`r?`n" | Select-Object -Last 2) -join "`n"}
                $done = Update-Session
                Update-CpmUi $entry $done
                Update-TapeUi $entry $done
                Update-FgUi $entry $done
                if ($done) {
                    Refresh-History
                    Set-Status "$($entry.Kind): $($entry.Status). Process exited; any port handle it owned is closed. Other programs may still own the port."
                    if ($Closing) { $Window.Close(); return }
                    if ($null -ne $NextAction) {
                        $next = $NextAction; $script:NextAction=$null
                        Invoke-Launch $next.Kind $next.Profile
                    }
                }
            }
            $busy = $null -ne $Active
            foreach ($name in @('QuickLaunch','QuickDemo','LaunchAdt','RunDiagnostics','RunOffline','HiPreview','HiStream','HiBootstrap','CpmPrepare','CpmBuild','CpmEmulate','CpmProbe','CpmUpload','CpmRun','CpmQuit','CpmInspect','CpmTerminal','CpmSendHex','CpmCardProbe','CpmBootPc','TapeDownload','TapeAddFile','VsDeploy','VsRestore','FgBoot','FgBuild','FgCheck')) { $UI[$name].IsEnabled = -not $busy -and -not $Closing }
            $UI.TapeCancel.IsEnabled=$busy -and $Active.Entry.Kind -eq 'TapeFetch' -and $null -eq $Active.StopRequested
            $UI.CpmStop.IsEnabled=$busy
            $UI.CpmFromAdt.IsEnabled=$busy -and $Active.Entry.Kind -eq 'ADTPro' -and $null -eq $NextAction
            foreach($name in @('CpmSend','CpmSendCommand','CpmCtrlC')){$UI[$name].IsEnabled=$busy -and $Active.Entry.Kind -eq 'ZTerminal' -and $null -eq $Active.StopRequested}
            $UI.Stop.IsEnabled = $busy
            $UI.HiStop.IsEnabled=$busy
            $UI.FgStop.IsEnabled=$busy
            $UI.HiExport.IsEnabled=(-not $busy -and $null -ne $LastHiDir)
            $UI.HiFromAdt.IsEnabled=$busy -and $Active.Entry.Kind -eq 'ADTPro' -and $null -eq $NextAction
            $UI.HiToAdt.IsEnabled=$busy -and $Active.Entry.Kind -in @('HiStream','HiPreview') -and $null -eq $NextAction
            if($null -ne $LastHiDir){
                $path=Join-Path $LastHiDir 'preview.png'
                if(Test-Path -LiteralPath $path){
                    $stamp=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks.ToString()
                    if($stamp -ne $LastHiStamp){
                        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                        try{$bmp=New-Object Windows.Media.Imaging.BitmapImage; $bmp.BeginInit(); $bmp.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bmp.StreamSource=$stream; $bmp.EndInit(); $bmp.Freeze()}finally{$stream.Dispose()}
                        $UI.HiPicture.Source=$bmp; $UI.HiEmpty.Visibility='Collapsed'; $script:LastHiStamp=$stamp
                    }
                }
            }
            $UI.HandoffStream.IsEnabled = $busy -and $Active.Entry.Kind -eq 'ADTPro' -and $null -eq $NextAction
            $UI.HandoffAdt.IsEnabled = $busy -and $Active.Entry.Kind -eq 'Stream' -and $null -eq $NextAction
            $UI.ReadyCursor.Visibility = if ($busy) { 'Collapsed' } else { 'Visible' }
            $UI.SessionState.Text = if ($busy) { "$($Active.Entry.Kind.ToUpperInvariant()) RUNNING" } else { 'NO MANAGED SESSION' }
            if ($busy) {
                $elapsed = [timespan]((Get-Date) - [datetime]$Active.Entry.Started)
                $UI.SessionTitle.Text = "$($Active.Entry.Kind) / $($elapsed.ToString('hh\:mm\:ss'))"
                $UI.SessionDetail.Text = if ($null -ne $Active.StopRequested) { 'Stopping. Waiting for process exit before releasing the session.' } else { "$($Active.Entry.Profile) / PID $($Active.Process.Id). Process running; see journal for connection and frame activity." }
            } else {
                $UI.SessionTitle.Text='READY.'
                $UI.SessionDetail.Text='No managed process is running. Load the receiver and check serial ownership, then launch a profile.'
            }
        } catch { $script:NextAction=$null; Show-Error (Format-LauncherError $_) }
    })
    $Window.Add_Closing({
        param($sender, $eventArgs)
        if ($null -ne $Active) {
            $eventArgs.Cancel=$true; $script:NextAction=$null
            try { Request-SessionStop; $script:Closing=$true; Set-Status 'Closing after the managed process exits. Finish or dismiss any ADTPro dialog.' }
            catch { $script:Closing=$false; Show-Error (Format-LauncherError $_) }
        }
    })
    if ($RenderPreview -or $SmokeTest) {
        # Exercise the real XAML and bindings without showing a window or launching a process.
        $UI.Preview.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        if ($UI.CommandPreview.Text -notmatch 'DlgrC') { throw 'Preview button failed.' }
        $UI.BaudField.SelectedItem='19200'
        if ($UI.FpsField.Text -ne '1.5') { throw 'Baud selection did not update FPS.' }
        $UI.BaudField.SelectedItem='115200'
        if ($SmokeTest) {
            $detected = @(Get-Process | Where-Object { $_.ProcessName -in @('java','javaw','Minecraft.Windows') -and $_.MainWindowTitle -like '*Minecraft*' -and $_.MainWindowTitle -notlike '*Launcher*' })
            if ($detected.Count -eq 1) {
                $UI.DetectWindow.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                if ($UI.WindowTitleField.Text -cne $detected[0].MainWindowTitle) { throw 'Game window detection callback failed.' }
                Write-Output 'PASS: Running Minecraft window title detected without capturing or opening serial.'
            }
            $UI.NameField.Text='UI smoke profile'
            $UI.SaveProfile.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if (-not (Test-Path (Join-Path $DataDir 'profiles.json'))) { throw 'Save profile callback failed.' }
            $UI.RunOffline.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if ($null -eq $Active) { throw 'Offline launch callback failed.' }
            $Timer.Start()
            $script:SmokeFrame = New-Object Windows.Threading.DispatcherFrame
            $smokeWatch = [Diagnostics.Stopwatch]::StartNew()
            $smokeTimer = New-Object Windows.Threading.DispatcherTimer
            $smokeTimer.Interval = [timespan]::FromMilliseconds(100)
            $script:SmokeLimit = 45
            $smokeTimer.Add_Tick({ if ($null -eq $Active -or $smokeWatch.Elapsed.TotalSeconds -gt $SmokeLimit) { $SmokeFrame.Continue=$false } })
            $smokeTimer.Start()
            [Windows.Threading.Dispatcher]::PushFrame($SmokeFrame)
            $smokeTimer.Stop(); $Timer.Stop()
            if ($null -ne $Active -or $History[0].Status -ne 'Completed') { throw 'UI offline session did not complete successfully.' }
            $UI.HistoryList.SelectedIndex=0
            if ($UI.HistoryDetail.Text -notmatch 'RLE self-test') { throw 'History selection callback failed.' }
            $UI.RestoreSession.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if ($UI.NameField.Text -ne 'UI smoke profile') { throw 'Restore settings callback failed.' }
            $UI.HiSourceField.SelectedItem='Demo'; $UI.HiDurationField.Text='1'
            $UI.HiBaudField.SelectedItem='19200'
            if($UI.HiFpsField.Text -ne '1'){throw 'Hi-Res baud/fps callback failed.'}
            $UI.HiBaudField.SelectedItem='115200'
            if($UI.HiFpsField.Text -ne '6'){throw 'Hi-Res baud/fps callback failed.'}
            if([string]$UI.HiPagesField.SelectedItem -ne 'Packed' -or [string]$UI.HiKeysField.SelectedItem -ne 'Off'){throw 'Hi-Res pages/keys defaults are not bound.'}
            if($UI.HiPagesField.Items.Count -ne 2 -or $UI.HiKeysField.Items.Count -ne 3){throw 'Hi-Res pages/keys choices are missing.'}
            $UI.HiPreview.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if($null -eq $Active){throw 'Hi-Res preview callback failed.'}
            $script:SmokeFrame=New-Object Windows.Threading.DispatcherFrame
            $smokeWatch.Restart(); $Timer.Start(); $smokeTimer.Start()
            [Windows.Threading.Dispatcher]::PushFrame($SmokeFrame)
            $smokeTimer.Stop(); $Timer.Stop()
            if($null -ne $Active -or $History[0].Status -ne 'Completed'){throw 'Hi-Res preview session failed.'}
            if($null -eq $UI.HiPicture.Source -or (Get-Item (Join-Path $LastHiDir 'frame.bin')).Length -ne 8192){throw 'Hi-Res image preview did not load.'}
            Write-Output 'PASS: Hi-Res preview process, duration stop, baud/fps suggestion, HGR output and live WPF image loading.'
            foreach($button in @('CpmBuild','CpmEmulate')) {
                $UI[$button].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                if($null -eq $Active){throw "$button callback did not start a session."}
                $script:SmokeFrame=New-Object Windows.Threading.DispatcherFrame
                $smokeWatch.Restart(); $Timer.Start(); $smokeTimer.Start()
                [Windows.Threading.Dispatcher]::PushFrame($SmokeFrame)
                $smokeTimer.Stop(); $Timer.Stop()
                if($null -ne $Active -or $History[0].Status -ne 'Completed'){throw "$button did not complete: $($UI.CpmLog.Text)"}
            }
            if($UI.CpmLog.Text -notmatch '5050'){throw 'Z80 sample did not return 5050.'}
            Write-Output 'PASS: Z80 source build, result binding, emulator execution and workbench journal.'
            # Cassette: import a generated WAV through the managed tape tool. No audio is played.
            $pcm=New-Object byte[] 2206
            for($i=0;$i -lt $pcm.Length;$i++){$pcm[$i]=if(($i % 20) -lt 10){0xC0}else{0x40}}
            $wav=New-Object IO.MemoryStream; $writer=New-Object IO.BinaryWriter $wav
            $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([uint32](36+$pcm.Length)); $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
            $writer.Write([uint32]16); $writer.Write([uint16]1); $writer.Write([uint16]1); $writer.Write([uint32]11025); $writer.Write([uint32]11025); $writer.Write([uint16]1); $writer.Write([uint16]8)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([uint32]$pcm.Length); $writer.Write($pcm); $writer.Flush()
            $tapeFixture=Join-Path $DataDir 'smoke tape.wav'
            [IO.File]::WriteAllBytes($tapeFixture,$wav.ToArray())
            Invoke-Launch 'TapeImport' (Read-Profile) $tapeFixture
            if($null -eq $Active){throw 'Tape import callback did not start a session.'}
            $script:SmokeFrame=New-Object Windows.Threading.DispatcherFrame
            $smokeWatch.Restart(); $Timer.Start(); $smokeTimer.Start()
            [Windows.Threading.Dispatcher]::PushFrame($SmokeFrame)
            $smokeTimer.Stop(); $Timer.Stop()
            if($null -ne $Active -or $History[0].Status -ne 'Completed'){throw "Tape import did not complete: $($UI.TapeLog.Text)"}
            if($UI.TapeTitleField.Text -ne 'smoke tape' -or $TapeCurrent.Seconds -ne 0.2 -or $TapeCurrent.Format -ne 'WAV'){throw 'Tape import result was not bound to the editor.'}
            $UI.TapeSave.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if(@($TapeLibrary | Where-Object {$_.Title -eq 'smoke tape'}).Count -ne 1 -or -not (Test-Path (Join-Path $DataDir 'tape-library.json'))){throw "Tape save callback failed: $($UI.Status.Text)"}
            $null=Test-TapeFile ($TapeLibrary | Where-Object {$_.Title -eq 'smoke tape'})
            foreach($tape in $ReceiverTapes){$null=Test-TapeFile $tape}
            if(-not $UI.TapePlay.IsEnabled -or $UI.TapeStop.IsEnabled){throw 'Tape playback buttons are in the wrong state.'}
            Write-Output "PASS: Tape import process, editor binding, library save and SHA-256 checks; $(@($ReceiverTapes).Count) receiver tapes match build provenance. No audio played."
            # VSDRIVE: deploy every receiver into a fresh ProDOS volume, then restore it. ADTPro's own image is not touched.
            $vsJava=Join-Path (Split-Path -Parent $Javaw) 'java.exe'
            $vsJar=Join-Path $Workspace 'Projects\adtpro-v_2_1_0\build\lib\AppleCommander\AppleCommander-1.3.5.13-ac.jar'
            if(-not (Test-FilePath $vsJava) -or -not (Test-FilePath $vsJar) -or @(Get-ExternalAdt).Count -gt 0){
                Write-Output 'SKIP: VSDRIVE deploy needs Java and AppleCommander, with ADTPro closed.'
            } else {
                $vsImage=Join-Path $DataDir 'smoke-vsdrive.po'
                if(Test-Path -LiteralPath $vsImage){Remove-Item -LiteralPath $vsImage -Force}
                $null=& $vsJava -jar $vsJar -pro140 $vsImage SMOKE
                if(-not (Test-FilePath $vsImage)){throw 'AppleCommander did not create the VSDRIVE test volume.'}
                $vsBefore=Get-Sha256 $vsImage
                $UI.VsImageField.Text=$vsImage; $UI.VsSetField.SelectedItem='All receivers'
                foreach($button in @('VsDeploy','VsRestore')) {
                    $UI[$button].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                    if($null -eq $Active){throw "$button callback did not start a session: $($UI.Status.Text)"}
                    $script:SmokeFrame=New-Object Windows.Threading.DispatcherFrame
                    $smokeWatch.Restart(); $Timer.Start(); $smokeTimer.Start()
                    [Windows.Threading.Dispatcher]::PushFrame($SmokeFrame)
                    $smokeTimer.Stop(); $Timer.Stop()
                    if($null -ne $Active -or $History[0].Status -ne 'Completed'){throw "$button did not complete: $($UI.LiveLog.Text)"}
                    if($button -eq 'VsDeploy') {
                        $vsReport=Read-JsonUtf8 (Join-Path $History[0].PreviewDir 'results.json')
                        if((Get-Sha256 $vsImage) -eq $vsBefore -or @($vsReport.files).Count -ne 3 -or $vsReport.sha256_after -ne (Get-Sha256 $vsImage)){throw 'VSDRIVE deploy did not write the receivers.'}
                    }
                }
                if((Get-Sha256 $vsImage) -ne $vsBefore){throw 'VSDRIVE restore did not return the original image.'}
                Write-Output 'PASS: VSDRIVE deploy of all three receivers into a fresh ProDOS volume, read back and restored through managed sessions.'
            }
            # Farglade OS: the sibling project's own PC checks through a managed session. No serial port is opened.
            if([string]$UI.FgSlotField.SelectedItem -ne '5' -or [string]$UI.FgBaudField.SelectedItem -ne '115200' -or $UI.FgPortField.Text -ne 'COM3' -or [bool]$UI.FgOpenRoads.IsChecked){throw 'Farglade defaults were not bound to screen 8.'}
            if(-not (Test-FargladeBuilt)) {
                if($UI.FgVersionText.Text -notmatch 'NOT FOUND|NOT BUILT YET'){throw 'Screen 8 does not say that Farglade OS is missing.'}
                Write-Output 'SKIP: Farglade OS is not built beside this project; screen 8 was bound and is rendered below.'
            } else {
                if($UI.FgVersionText.Text -ne "FARGLADE OS $(Get-FargladeVersion) / BUILT"){throw 'Screen 8 does not name the built Farglade OS version.'}
                $UI.FgCheck.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                if($null -eq $Active -or $Active.Entry.Kind -ne 'FgCheck' -or $UI.Tabs.SelectedItem -ne $UI.FgTab){throw "FgCheck callback did not start a session: $($UI.Status.Text)"}
                $script:SmokeFrame=New-Object Windows.Threading.DispatcherFrame
                $script:SmokeLimit=240
                $smokeWatch.Restart(); $Timer.Start(); $smokeTimer.Start()
                [Windows.Threading.Dispatcher]::PushFrame($SmokeFrame)
                $smokeTimer.Stop(); $Timer.Stop()
                $script:SmokeLimit=45
                if($null -ne $Active -or $History[0].Status -ne 'Completed'){throw "Farglade checks did not complete: $($UI.FgLog.Text)"}
                if($UI.FgLog.Text -notmatch '(?m)^OK\s*$'){throw 'Farglade checks did not report OK in the journal.'}
                Write-Output "PASS: Farglade OS $(Get-FargladeVersion) PC checks through a managed session and the screen 8 journal. No serial port opened."
            }
            if ($UI.VideoSummary.Foreground.Color -ne $Window.Resources['Fg'].Color) { throw 'Framed content does not use the readable monitor foreground.' }
            $startMonitor=$CurrentMonitor
            foreach($i in 1..@($ThemeTable.order).Count){$UI.MonitorCycle.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))}
            if($CurrentMonitor -ne $startMonitor -or $LauncherSettings.Monitor -ne $startMonitor){throw 'Monitor cycling did not return to the starting theme.'}
            $UI.MonitorColor.IsChecked=$true
            if($CurrentMonitor -ne 'Color' -or $Window.Resources['Sel'].Color.ToString() -ne '#FF402CB8' -or $UI.ColorBand.Visibility -ne 'Visible' -or (Read-JsonUtf8 (Join-Path $DataDir 'launcher-settings.json')).Monitor -ne 'Color'){throw '16-color monitor was not applied and saved.'}
            $UI.CrtToggle.IsChecked=$false
            $UI.CrtToggle.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if($UI.Scanlines.Visibility -ne 'Collapsed' -or $null -ne $UI.Root.Effect -or $LauncherSettings.Scanlines){throw 'Scanline toggle did not turn off.'}
            $UI.CrtToggle.IsChecked=$true
            $UI.CrtToggle.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if($UI.Scanlines.Visibility -ne 'Visible' -or -not $LauncherSettings.Scanlines){throw 'Scanline toggle did not turn on.'}
            if(-not (Invoke-KeyCommand 'D7') -or $UI.Tabs.SelectedIndex -ne 6){throw 'Screen key 7 failed.'}
            if(-not (Invoke-KeyCommand 'D8') -or $UI.Tabs.SelectedItem -ne $UI.FgTab){throw 'Screen key 8 failed.'}
            if(Invoke-KeyCommand 'Escape'){throw 'Escape acted without a managed session.'}
            Set-Monitor $startMonitor; Save-Monitor $startMonitor
            Write-Output 'PASS: Four monitor themes, M cycling, saved launcher settings, scanline toggle and screen keys. No audio played.'
        }
        $surface = $Window.Content
        $Window.Content = $null
        $surface.Resources = $Window.Resources
        $surface.SetResourceReference([Windows.Documents.TextElement]::FontFamilyProperty, 'Mono')
        $surface.SetValue([Windows.Documents.TextElement]::FontSizeProperty, $Window.FontSize)
        $surface.SetResourceReference([Windows.Documents.TextElement]::ForegroundProperty, 'Fg')
        $surface.SetResourceReference([Windows.Controls.Panel]::BackgroundProperty, 'Bg')
        foreach ($index in 0..9) {
            $UI.Tabs.SelectedIndex=if($index -eq 9){7}elseif($index -eq 8){6}else{[math]::Min($index,5)}
            if($index -ge 5 -and $index -le 7){$UI.CpmPages.SelectedIndex=$index-5}
            $surface.Measure((New-Object Windows.Size(1260,900)))
            $surface.Arrange((New-Object Windows.Rect(0,0,1260,900)))
            $surface.UpdateLayout()
            $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap(1260,900,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($surface)
            $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
            $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $file=[IO.File]::Create((Join-Path $DataDir "preview-$index.png"))
            try { $encoder.Save($file) } finally { $file.Dispose() }
        }
        $shownMonitor=$CurrentMonitor
        foreach ($name in @($ThemeTable.order)) {
            # One render per monitor theme of the first and cassette screens, for visual review.
            Set-Monitor $name
            foreach ($tab in @(0,6)) {
                $UI.Tabs.SelectedIndex=$tab
                $surface.Measure((New-Object Windows.Size(1260,900)))
                $surface.Arrange((New-Object Windows.Rect(0,0,1260,900)))
                $surface.UpdateLayout()
                $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap(1260,900,96,96,[Windows.Media.PixelFormats]::Pbgra32)
                $bitmap.Render($surface)
                $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
                $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $file=[IO.File]::Create((Join-Path $DataDir "preview-$($name.ToLowerInvariant())-$tab.png"))
                try { $encoder.Save($file) } finally { $file.Dispose() }
            }
        }
        Set-Monitor $shownMonitor
        Write-Output 'PASS: XAML load, profile binding, preview callback, baud/FPS callback, eight tabs, three CP/M pages and four monitor themes rendered. No serial port opened.'
    } else {
        $Timer.Start()
        $null = $Window.ShowDialog()
    }
} catch {
    if (-not $SmokeTest -and -not $RenderPreview) { $null = [Windows.MessageBox]::Show($(if (Get-Command Format-LauncherError -ErrorAction SilentlyContinue) { Format-LauncherError $_ } else { $_.Exception.Message }), 'Crowbar Launcher could not continue', 'OK', 'Error') }
    throw
} finally {
    if (Get-Variable Timer -Scope Script -ErrorAction SilentlyContinue) { $Timer.Stop() }
    if ($null -ne $Active -and $null -ne $Active.Job) { $Active.Job.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
