# Dot-sourced after launcher event helpers are available.
# Playback runs in-process through the PC's default audio output; it never opens a serial port.
$script:TapePlayer = $null
$script:TapeCurrent = $null
$script:ReceiverTapes = @()
$script:TapeJournal = New-Object 'System.Collections.Generic.List[string]'
$script:TapeServer = 'https://asciiexpress.net/gameserver/'
Initialize-TapeLibrary

function Format-TapeTime([double]$Seconds) {
    $span = [timespan]::FromSeconds([math]::Max(0, $Seconds))
    '{0}:{1:00}' -f [int][math]::Floor($span.TotalMinutes), $span.Seconds
}
function Show-TapeJournal([string]$Live = '') {
    $text = $TapeJournal -join "`r`n"
    if ($Live) { $text = ($text + "`r`n" + $Live).Trim() }
    if ($text) { $UI.TapeLog.Text = $text; $UI.TapeLog.ScrollToEnd() }
}
function Write-TapeJournal([string]$Text) {
    $TapeJournal.Add((Get-Date -Format 'HH:mm:ss') + '  ' + $Text)
    while ($TapeJournal.Count -gt 200) { $TapeJournal.RemoveAt(0) }
    Show-TapeJournal
}
function Show-TapeEntry($Entry) {
    $script:TapeCurrent = $Entry
    $UI.TapeTitleField.Text = $Entry.Title
    $UI.TapeLoadField.Text = $Entry.LoadCommand
    $UI.TapeLoadBig.Text = $Entry.LoadCommand
    $UI.TapeNotesField.Text = $Entry.Notes
    $UI.TapeLengthText.Text = $(if ($Entry.Seconds -gt 0) { Format-TapeTime $Entry.Seconds } else { 'shown while playing' }) + ' / ' + $Entry.Format
    $UI.TapeDetail.Text = "File:   $($Entry.File)`nSource: $($Entry.Source)`nSHA-256 $($Entry.Sha256)"
}
function Read-TapeEditor {
    if ($null -eq $TapeCurrent) { throw 'Choose a tape from the shelf, add a file or download one first.' }
    $t = ConvertTo-TapeEntry $TapeCurrent
    $t.Title = $UI.TapeTitleField.Text; $t.LoadCommand = $UI.TapeLoadField.Text; $t.Notes = $UI.TapeNotesField.Text
    ConvertTo-TapeEntry $t
}
function Refresh-TapeLibrary([string]$Select = '') {
    try { $script:ReceiverTapes = @(Get-ReceiverTapes) }
    catch { $script:ReceiverTapes = @(); Write-TapeJournal "Receiver tapes unavailable: $($_.Exception.Message)" }
    $items = @($ReceiverTapes) + @($TapeLibrary)
    $UI.TapeLibraryList.ItemsSource = $null
    $UI.TapeLibraryList.ItemsSource = $items
    if ($Select) { $UI.TapeLibraryList.SelectedItem = $items | Where-Object { $_.Title -eq $Select } | Select-Object -First 1 }
}
function Update-TapeButtons {
    $playing = $null -ne $TapePlayer
    $UI.TapePlay.IsEnabled = -not $playing
    $UI.TapeStop.IsEnabled = $playing
    $UI.TapeLibraryList.IsEnabled = -not $playing
}
function Stop-TapePlayback([string]$Reason) {
    $TapeClock.Stop()
    if ($null -ne $TapePlayer) {
        $player = $TapePlayer; $script:TapePlayer = $null
        $player.Stop(); $player.Close()
        if ($Reason) { Write-TapeJournal $Reason }
    }
    $UI.TapeProgress.Value = 0
    Update-TapeButtons
}
function Start-TapePlayback {
    if ($null -ne $TapePlayer) { throw 'A tape is already playing. Stop it first.' }
    $t = Test-TapeFile (Read-TapeEditor)
    $player = New-Object Windows.Media.MediaPlayer
    $player.Volume = $UI.TapeVolume.Value / 100
    $player.Add_MediaEnded({ try { Stop-TapePlayback 'Playback finished. The Apple should now run the program; a beep or ERR means retry with Ctrl-Reset.' } catch { Show-Error (Format-LauncherError $_) } })
    $player.Add_MediaFailed({
        param($sender, $eventArgs)
        try { Stop-TapePlayback 'Playback failed.'; Show-Error ('Windows could not play this tape: ' + $eventArgs.ErrorException.Message) } catch { Show-Error (Format-LauncherError $_) }
    })
    $script:TapePlayer = $player
    Update-TapeButtons
    $player.Open((New-Object Uri $t.File))
    $player.Play()
    $TapeClock.Start()
    $UI.TapePosition.Text = '0:00'
    Write-TapeJournal "Playing '$($t.Title)' at player volume $([int]$UI.TapeVolume.Value)%. On the Apple: $($t.LoadCommand)"
    Set-Status 'Playing to the default audio output. Keep other sounds off until the load finishes.'
}
function Update-TapeUi($Entry, [bool]$Done) {
    if ($Entry.Kind -notlike 'Tape*') { return }
    if (-not $Done) { Show-TapeJournal (Read-SessionLog $Entry); return }
    Write-TapeJournal ("$($Entry.Kind) $($Entry.Status).`r`n" + (Read-SessionLog $Entry).Trim())
    if ($Entry.Status -eq 'Completed') {
        $result = Read-TapeJson (Join-Path $Entry.PreviewDir 'result.json')
        $tape = ConvertTo-TapeEntry ([pscustomobject]@{ Title = $result.title; File = $result.file; Sha256 = $result.sha256; Source = $result.source; Format = $result.format; Seconds = $result.seconds; LoadCommand = 'LOAD'; Notes = (@($result.notes) -join ' ') })
        $UI.TapeLibraryList.SelectedItem = $null
        Show-TapeEntry $tape
        Set-Status 'Tape ready. Check its title and load command, then Save to library.'
    }
}

$script:TapeClock = New-Object Windows.Threading.DispatcherTimer
$TapeClock.Interval = [timespan]::FromMilliseconds(200)
$TapeClock.Add_Tick({
    try {
        if ($null -eq $TapePlayer) { $TapeClock.Stop(); return }
        $position = $TapePlayer.Position.TotalSeconds
        if ($TapePlayer.NaturalDuration.HasTimeSpan -and $TapePlayer.NaturalDuration.TimeSpan.TotalSeconds -gt 0) {
            $total = $TapePlayer.NaturalDuration.TimeSpan.TotalSeconds
            $UI.TapeProgress.Value = [math]::Min(1, $position / $total)
            $UI.TapePosition.Text = (Format-TapeTime $position) + ' / ' + (Format-TapeTime $total)
        } else { $UI.TapePosition.Text = Format-TapeTime $position }
    } catch { Stop-TapePlayback 'Playback stopped after a player error.'; Show-Error (Format-LauncherError $_) }
})
$UI.TapeLibraryList.Add_SelectionChanged({
    try { if ($null -ne $UI.TapeLibraryList.SelectedItem) { Show-TapeEntry $UI.TapeLibraryList.SelectedItem } } catch { Show-Error (Format-LauncherError $_) }
})
$UI.TapeLoadField.Add_TextChanged({ $UI.TapeLoadBig.Text = $UI.TapeLoadField.Text })
$UI.TapeVolume.Add_ValueChanged({
    $UI.TapeVolumeText.Text = "$([int]$UI.TapeVolume.Value)%"
    if ($null -ne $TapePlayer) { $TapePlayer.Volume = $UI.TapeVolume.Value / 100 }
})
$Window.Add_Closed({ if ($null -ne $TapePlayer) { $TapePlayer.Stop(); $TapePlayer.Close() } })

Add-Click 'TapePlay' { Start-TapePlayback }
Add-Click 'TapeStop' { Stop-TapePlayback "Stopped at $($UI.TapePosition.Text). A partial load needs Ctrl-Reset on the Apple before retrying."; Set-Status 'Playback stopped.' }
Add-Click 'TapeGuide' { Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $Project 'docs\CASSETTE.md') + '"') }
Add-Click 'TapeOpenServer' { Start-Process $TapeServer; Set-Status 'Opened the ASCII Express game server in your browser. Copy an audio file link, then paste it here.' }
Add-Click 'TapeDownload' { Invoke-Launch 'TapeFetch' (Read-Profile) $UI.TapeUrlField.Text }
Add-Click 'TapeCancel' { $script:NextAction = $null; Request-SessionStop; Set-Status 'Cancelling the download; nothing is added to the library.' }
Add-Click 'TapeAddFile' {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Cassette audio|*.wav;*.aif;*.aiff;*.aifc;*.mp3|All files|*.*'
    if ($dialog.ShowDialog($Window)) { Invoke-Launch 'TapeImport' (Read-Profile) $dialog.FileName }
}
Add-Click 'TapeSave' {
    $t = Save-TapeEntry (Read-TapeEditor)
    Refresh-TapeLibrary $t.Title
    Set-Status "Saved tape: $($t.Title). The previous library file is kept as tape-library.json.bak."
}
Add-Click 'TapeRemove' {
    if ($null -eq $UI.TapeLibraryList.SelectedItem) { throw 'Select a saved library entry first.' }
    $title = $UI.TapeLibraryList.SelectedItem.Title
    Remove-TapeEntry $title
    $script:TapeCurrent = $null
    Refresh-TapeLibrary
    Set-Status "Removed $title from the library. Its audio file was kept."
}
Add-Click 'TapeFolder' {
    if ($null -eq $TapeCurrent -or -not (Test-FilePath $TapeCurrent.File)) { throw 'Choose a tape with an existing audio file first.' }
    Start-Process explorer.exe -ArgumentList ('/select,"' + $TapeCurrent.File + '"')
}

Refresh-TapeLibrary
if (@($ReceiverTapes).Count -eq 0) { Write-TapeJournal 'No receiver tapes listed: run build.ps1 to create this release''s receiver WAVs and build provenance.' }
Update-TapeButtons
