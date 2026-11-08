# Dot-sourced after launcher event helpers are available.
# Screen 8: Farglade OS, the sibling project farglade-os. Its own tools build it, check it and boot it
# on the Apple; the launcher supplies the settings and supervises the process like any other session.
foreach($field in @('FgSlot','FgBaud')) {
    $choices=switch($field){'FgSlot'{@('1','2','3','4','5','6','7')} 'FgBaud'{@('115200','19200')}}
    foreach($choice in $choices){$null=$UI["${field}Field"].Items.Add($choice)}
}
function Update-FgSummary {
    $version=Get-FargladeVersion
    $UI.FgVersionText.Text=if(-not $version){'FARGLADE OS / NOT FOUND'}elseif(Test-FargladeBuilt){"FARGLADE OS $version / BUILT"}else{"FARGLADE OS $version / NOT BUILT YET"}
    $UI.FgWhere.Text=$FargladeDir
}
Add-Click 'FgBoot' {
    # The open-roads box is read at launch and never stored in a profile.
    $target=if([bool]$UI.FgOpenRoads.IsChecked){'OpenRoads'}else{''}
    Invoke-Launch 'FgBoot' (Read-Profile) $target
}
Add-Click 'FgBuild' {Invoke-Launch 'FgBuild' (Read-Profile)}
Add-Click 'FgCheck' {Invoke-Launch 'FgCheck' (Read-Profile)}
Add-Click 'FgStop' {$script:NextAction=$null; Request-SessionStop; Set-Status 'Stopping the Farglade uplink. The Apple then reports a quiet uplink until it is booted again.'}
Add-Click 'FgSave' {$UI.SaveProfile.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))}
Add-Click 'FgGuide' {
    $guide=Join-Path $FargladeDir 'docs\OPERATING.md'
    if(-not (Test-FilePath $guide)){throw "Farglade OS was not found at $FargladeDir."}
    Start-Process notepad.exe -ArgumentList ('"'+$guide+'"')
}
Add-Click 'FgFolder' {
    if(-not (Get-FargladeVersion)){throw "Farglade OS was not found at $FargladeDir."}
    Start-Process explorer.exe -ArgumentList ('"'+$FargladeDir+'"')
}

function Update-FgUi($Entry,[bool]$Done) {
    if($Entry.Kind -notlike 'Fg*'){return}
    $UI.FgLog.Text=Read-SessionLog $Entry
    $UI.FgLog.ScrollToEnd()
    if($Done){Update-FgSummary}
}
Update-FgSummary
