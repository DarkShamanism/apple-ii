# Dot-sourced after the XAML is loaded: monitor themes, the bundled font and keyboard shortcuts.
# Display settings are launcher-wide (launcher-settings.json), separate from launch profiles.
$script:ThemeTable = Get-LauncherThemes
$script:CurrentMonitor = 'Green'
$script:ApplyingTheme = $false
Initialize-LauncherSettings

# VT323 is bundled under the SIL Open Font License; without it, fall back to a Windows console font.
# Resources are built with ::new, not New-Object: Windows PowerShell 5.1 stores New-Object output in a
# ResourceDictionary inside a PSObject wrapper, which WPF then rejects as a font or brush.
$fontFile = Join-Path $Project 'third_party\VT323\VT323-Regular.ttf'
if (Test-FilePath $fontFile) {
    $Window.Resources['Mono'] = [Windows.Media.FontFamily]::new([Uri]::new((Split-Path -Parent $fontFile) + '\'), './#VT323')
    $Window.FontSize = 22
} else {
    $Window.Resources['Mono'] = [Windows.Media.FontFamily]::new('Lucida Console, Consolas')
    $Window.FontSize = 15
}
if (-not [Windows.SystemParameters]::ClientAreaAnimation) { $UI.ReadyCursor.Triggers.Clear() }

function Set-Glow {
    $theme = $ThemeTable.themes.$CurrentMonitor
    $on = [bool]$LauncherSettings.Scanlines
    $UI.Scanlines.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    if ($on) {
        $glow = New-Object Windows.Media.Effects.DropShadowEffect
        $glow.Color = [Windows.Media.ColorConverter]::ConvertFromString($theme.Glow)
        $glow.BlurRadius = 6; $glow.ShadowDepth = 0; $glow.Opacity = [double]$theme.GlowOpacity
        $UI.Root.Effect = $glow
    } else { $UI.Root.Effect = $null }
}
function Set-Monitor([string]$Name) {
    # Replaces the palette brushes; every DynamicResource in the XAML follows.
    $theme = $ThemeTable.themes.$Name
    foreach ($key in $ThemeKeys) {
        if ($key -eq 'Glow') { continue }
        $brush = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($theme.$key))
        $brush.Freeze()
        $Window.Resources[$key] = $brush
    }
    $isColor = $Name -eq 'Color'
    $UI.ColorBand.Visibility = if ($isColor) { 'Visible' } else { 'Collapsed' }
    $UI.MonoRule.Visibility = if ($isColor) { 'Collapsed' } else { 'Visible' }
    $UI.MonitorCycle.Content = "MONITOR: $($theme.Label)"
    $script:CurrentMonitor = $Name
    $script:ApplyingTheme = $true
    try { $UI["Monitor$Name"].IsChecked = $true } finally { $script:ApplyingTheme = $false }
    Set-Glow
}
function Save-Monitor([string]$Name) {
    $s = ConvertTo-LauncherSettings $LauncherSettings
    $s.Monitor = $Name
    Save-LauncherSettings $s
    Set-Status "Monitor: $($ThemeTable.themes.$Name.Name). Saved for every screen."
}
function Invoke-Hotkey($Button) {
    if ($null -eq $Button -or -not $Button.IsEnabled -or -not $Button.IsVisible) { return $false }
    $Button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    return $true
}
function Invoke-KeyCommand([string]$Key) {
    # 1-8 choose a screen, Esc stops the managed session, letters press the visible button showing them.
    if ($Key -match '^(?:D|NumPad)([1-8])$') { $UI.Tabs.SelectedIndex = [int]$Matches[1] - 1; return $true }
    if ($Key -eq 'Escape') { return (Invoke-Hotkey $UI.Stop) }
    if ($Key -cmatch '^[A-Z]$') {
        foreach ($button in $HotkeyButtons) {
            if ([string]$button.Tag -ceq $Key -and $button.IsVisible) { return (Invoke-Hotkey $button) }
        }
    }
    return $false
}

$script:HotkeyButtons = @(foreach ($node in $xaml.SelectNodes("//*[local-name()='Button'][@Tag][@Name]")) { $UI[$node.Name] })
$monitorChecked = {
    param($sender, $eventArgs)
    if ($ApplyingTheme) { return }
    try { $name = $sender.Name.Substring(7); Set-Monitor $name; Save-Monitor $name } catch { Show-Error (Format-LauncherError $_) }
}
foreach ($name in @($ThemeTable.order)) { $UI["Monitor$name"].Add_Checked($monitorChecked) }
Add-Click 'MonitorCycle' {
    $order = @($ThemeTable.order)
    $next = $order[([array]::IndexOf($order, $CurrentMonitor) + 1) % $order.Count]
    Set-Monitor $next
    Save-Monitor $next
}
Add-Click 'CrtToggle' {
    $s = ConvertTo-LauncherSettings $LauncherSettings
    $s.Scanlines = [bool]$UI.CrtToggle.IsChecked
    Save-LauncherSettings $s
    Set-Glow
    Set-Status $(if ($s.Scanlines) { 'Scanlines and glow on.' } else { 'Scanlines and glow off.' })
}
$Window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    try {
        if ($eventArgs.KeyboardDevice.Modifiers -ne [Windows.Input.ModifierKeys]::None) { return }
        # Typing into a field or list control keeps every key for that control.
        $focus = [Windows.Input.Keyboard]::FocusedElement
        if ($focus -is [Windows.Controls.Primitives.TextBoxBase] -or $focus -is [Windows.Controls.ComboBox] -or $focus -is [Windows.Controls.ComboBoxItem]) { return }
        if (Invoke-KeyCommand $eventArgs.Key.ToString()) { $eventArgs.Handled = $true }
    } catch { Show-Error (Format-LauncherError $_) }
})

$UI.CrtToggle.IsChecked = [bool]$LauncherSettings.Scanlines
Set-Monitor $LauncherSettings.Monitor
