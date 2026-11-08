# Dot-sourced after launcher event helpers are available.
foreach($field in @('CpmBaud','CpmHandshake','CpmTarget','CpmSlot','CpmBootBaud','CpmWrites')) {
    $choices=switch($field){'CpmBaud'{@('300','1200','2400','4800','9600','19200')} 'CpmHandshake'{@('None','RtsCts')} 'CpmTarget'{@('Module','COM')} 'CpmSlot'{@('1','2','3','4','5','6','7')} 'CpmBootBaud'{@('115200','19200')} 'CpmWrites'{@('Save to image','Read only')}}
    foreach($choice in $choices){$null=$UI["${field}Field"].Items.Add($choice)}
}
Initialize-CpmLibrary
function Refresh-CpmLibrary {$UI.CpmLibraryList.ItemsSource=$null; $UI.CpmLibraryList.ItemsSource=@($CpmLibrary)}
function Choose-CpmFile([string]$Field,[string]$Filter) {
    $dialog=New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter=$Filter
    if($dialog.ShowDialog($Window)){$UI["${Field}Field"].Text=$dialog.FileName}
}
function Send-CpmText([string]$Text) {
    if($null -eq $Active -or $Active.Entry.Kind -ne 'ZTerminal' -or $null -ne $Active.StopRequested){throw 'Connect the CP/M terminal first.'}
    if($Text.Length -gt 2048 -or $Text -match '[^\x00-\x7f]'){throw 'Terminal input must be at most 2048 ASCII characters.'}
    $path=Join-Path $Active.Entry.PreviewDir 'terminal-send.json'
    if(Test-Path -LiteralPath $path){throw 'Wait for the previous terminal message to be sent.'}
    Save-JsonAtomic $path @{text=$Text}
    Set-Status 'Terminal text queued for the active connection.'
}
function New-CpmExample([bool]$Com) {
    $dest=Join-Path $Project ("build\$Version\z80\workshop\"+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $dest -Force
    $name=if($Com){'hello-cpm.asm'}else{'example-module.asm'}
    $file=Join-Path $dest $name
    Copy-Item -LiteralPath (Join-Path $Project "src\z80\$name") -Destination $file
    $UI.CpmSourceField.Text=$file
    $UI.CpmTargetField.SelectedItem=if($Com){'COM'}else{'Module'}
    $UI.CpmBinaryField.Text=''
    Set-Status "Created editable example: $file"
}
$UI.CpmLibraryList.Add_SelectionChanged({
    if($null -ne $UI.CpmLibraryList.SelectedItem){
        $item=$UI.CpmLibraryList.SelectedItem
        foreach($field in @('CpmTitle','CpmDisk','CpmVersion','CpmCommand','CpmNotes','CpmPort')){$UI["${field}Field"].Text=$item.$field}
        $UI.CpmBaudField.SelectedItem=[string]$item.CpmBaud
        $UI.CpmHandshakeField.SelectedItem=$item.CpmHandshake
    }
})
Refresh-CpmLibrary
foreach($item in @(@('CpmPrepare','ZPrepare'),@('CpmBuild','ZBuild'),@('CpmEmulate','ZEmulate'),@('CpmProbe','ZProbe'),@('CpmUpload','ZUpload'),@('CpmRun','ZRun'),@('CpmQuit','ZQuit'),@('CpmInspect','ZInspect'),@('CpmTerminal','ZTerminal'),@('CpmSendHex','ZSendHex'),@('CpmCardProbe','ZCardProbe'),@('CpmBootPc','ZCpmBoot'))) {
    $kind=$item[1]
    Add-Click $item[0] {Invoke-Launch $kind (Read-Profile)}.GetNewClosure()
}
Add-Click 'CpmSave' {$UI.SaveProfile.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))}
Add-Click 'CpmStop' {$script:NextAction=$null; Request-SessionStop; Set-Status 'Stopping the PC session. The Apple helper may remain active.'}
Add-Click 'CpmToAdt' {Invoke-Handoff 'ADTPro'}
Add-Click 'CpmFromAdt' {Invoke-Handoff 'ZTerminal'}
Add-Click 'CpmGuide' {Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $Project 'docs\SOFTCARD.md')+'"')}
Add-Click 'CpmBrowseDisk' {Choose-CpmFile 'CpmDisk' 'Apple disk images|*.dsk;*.do;*.po;*.img;*.woz;*.nib|All files|*.*'}
Add-Click 'CpmBrowseDiskB' {Choose-CpmFile 'CpmDiskB' '140K disk images|*.dsk;*.do;*.po'}
Add-Click 'CpmBrowseSource' {Choose-CpmFile 'CpmSource' 'Z80 assembly|*.asm;*.z80;*.s|All files|*.*'}
Add-Click 'CpmBrowseBinary' {Choose-CpmFile 'CpmBinary' 'Workbench binaries (requires adjacent result.json)|*.BIN;*.COM'}
Add-Click 'CpmBrowseHex' {Choose-CpmFile 'CpmHex' 'Intel HEX|*.hex'}
Add-Click 'CpmHelperHex' {$UI.CpmHexField.Text=Join-Path $Project "build\$Version\A2Z.HEX"}
Add-Click 'CpmExample' {New-CpmExample $false}
Add-Click 'CpmHello' {New-CpmExample $true}
Add-Click 'CpmEdit' {
    $path=$UI.CpmSourceField.Text
    if(-not (Test-FilePath $path)){throw 'Choose a source file first.'}
    # Keep sealed source examples intact; edit a versioned workshop copy instead.
    $full=[IO.Path]::GetFullPath($path)
    if($full.StartsWith((Join-Path $Project 'src\z80\'),[StringComparison]::OrdinalIgnoreCase)){
        New-CpmExample ($UI.CpmTargetField.SelectedItem -eq 'COM'); $path=$UI.CpmSourceField.Text
    }
    Start-Process notepad.exe -ArgumentList ('"'+$path+'"')
}
Add-Click 'CpmBuildFolder' {
    $path=$UI.CpmBinaryField.Text
    if(-not (Test-FilePath $path)){throw 'Assemble or choose a previous build first.'}
    Start-Process explorer.exe -ArgumentList ('"'+(Split-Path -Parent $path)+'"')
}
Add-Click 'CpmDiskFolder' {
    $path=$UI.CpmDiskField.Text
    if(-not (Test-FilePath $path)){throw 'Choose an existing disk image first.'}
    Start-Process explorer.exe -ArgumentList ('"'+(Split-Path -Parent $path)+'"')
}
Add-Click 'CpmSaveLibrary' {Save-CpmLibraryEntry (Read-Profile); Refresh-CpmLibrary; Set-Status 'Saved CP/M library entry. Disk contents were not changed.'}
Add-Click 'CpmRemoveLibrary' {
    if($null -eq $UI.CpmLibraryList.SelectedItem){throw 'Select a library entry first.'}
    $title=$UI.CpmLibraryList.SelectedItem.CpmTitle
    $script:CpmLibrary=@($CpmLibrary | Where-Object {$_.CpmTitle -ne $title})
    Save-JsonAtomic (Join-Path $DataDir 'cpm-library.json') @($CpmLibrary)
    Refresh-CpmLibrary; Set-Status 'Removed the library reference. Disk file preserved.'
}
Add-Click 'CpmSend' {Send-CpmText ($UI.CpmTerminalInput.Text+"`r"); $UI.CpmTerminalInput.Text=''}
Add-Click 'CpmSendCommand' {Send-CpmText ($UI.CpmCommandField.Text+"`r")}
Add-Click 'CpmCtrlC' {Send-CpmText ([string][char]3)}

function Update-CpmUi($Entry,[bool]$Done) {
    if($Entry.Kind -notlike 'Z*'){return}
    $UI.CpmLog.Text=Read-SessionLog $Entry
    $UI.CpmLog.ScrollToEnd()
    if($Done -and $Entry.Kind -eq 'ZBuild' -and $Entry.Status -eq 'Completed') {
        $result=Get-Content -LiteralPath (Join-Path $Entry.PreviewDir 'result.json') -Raw | ConvertFrom-Json
        $UI.CpmBinaryField.Text=$result.binary
        $UI.CpmHexField.Text=[IO.Path]::ChangeExtension($result.binary,'.HEX')
        $UI.CpmTargetField.SelectedItem=$result.target
    }
}
