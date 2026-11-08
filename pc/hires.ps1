[CmdletBinding()]
param(
    [ValidateSet('Preview','Stream','Bootstrap')][string]$Action='Preview',
    [ValidateSet('Demo','Window','Desktop','Image')][string]$Source='Demo',
    [string]$WindowTitle='', [string]$Image='', [string]$Port='COM3',
    [ValidateSet(19200,115200)][int]$Baud=115200,
    [ValidateRange(1,7)][int]$Slot=2,
    [ValidateRange(0,1)][double]$Dither=0.9,
    [ValidateSet('Crop','Stretch','Letterbox')][string]$Fit='Letterbox',
    [ValidateRange(0.1,15)][double]$Fps=1,
    [ValidateRange(0,86400)][double]$Duration=0,
    [ValidateSet('Packed','Raw')][string]$Pages='Packed',
    [ValidateSet('Off','Log','Minecraft')][string]$Keys='Off',
    [ValidateRange(1,500)][int]$LookStep=40,
    [ValidateRange(1,2000)][int]$HoldMs=350,
    [ValidateRange(0,1000)][int]$KeyEvery=60,
    # For the checks only: stream to 127.0.0.1:<port> instead of a serial port. No port is opened.
    [ValidateRange(0,65535)][int]$Loopback=0,
    [string]$OutputDir, [string]$StopFile, [switch]$Once
)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$version=(Get-Content (Join-Path $project 'VERSION') -Raw).Trim()
if (-not $OutputDir) { $OutputDir=Join-Path $project "build\$version\hires-preview" }
if ($Port -notmatch '^COM[1-9][0-9]*$') { throw 'Use a serial name such as COM3.' }
if ($Source -eq 'Window' -and [string]::IsNullOrWhiteSpace($WindowTitle)) { throw 'Select a capture window.' }
if ($Source -eq 'Image' -and ([string]::IsNullOrWhiteSpace($Image) -or -not (Test-Path -LiteralPath $Image -PathType Leaf))) { throw 'Choose an existing image.' }
if ($Action -eq 'Stream' -and $Keys -eq 'Minecraft' -and $Source -ne 'Window') { throw 'Minecraft keys go to the captured window: choose the Window source, or set keys to Off or Log.' }
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'hires.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms
function Stopping { return ($StopFile -and (Test-Path -LiteralPath $StopFile)) }
function Build-Frame {
    $bitmap=[Hires]::Capture($Source,$WindowTitle,$Image)
    try { return [Hires]::Convert($bitmap,$Dither,$Fit) } finally { $bitmap.Dispose() }
}
$serial=$null; $client=$null; $net=$null; $frame=$null; $link=$null
$heldKeys=@{}; $heldButtons=@{}
# The link is a serial port, or for the checks a socket on this PC.
function Link-Available { if($null -ne $net){ return $client.Available }; return $serial.BytesToRead }
function Link-Read([byte[]]$Into) {
    if($null -ne $net){ return $net.Read($Into,0,[math]::Min($Into.Length,$client.Available)) }
    return $serial.Read($Into,0,[math]::Min($Into.Length,$serial.BytesToRead))
}
function Link-Write([byte[]]$Bytes) {
    if($null -ne $net){ $net.Write($Bytes,0,$Bytes.Length); $net.Flush(); return }
    $serial.Write($Bytes,0,$Bytes.Length)
    # Wait for driver drain so the next request cannot be confused with queued output.
    while($serial.BytesToWrite -gt 0) { Start-Sleep -Milliseconds 10 }
}
# A key from the IIe. Log writes what it would do; Minecraft does it, and only in the captured window.
function Use-Key([int]$Code) {
    $plan=[HiresInput]::Plan($Code,$LookStep)
    if($Keys -eq 'Log') { Write-Output ("key {0:X2} / {1}" -f $Code,$(if($plan){$plan}else{'nothing'})); return }
    if($Keys -ne 'Minecraft' -or -not $plan) { return }
    if(-not [HiresInput]::PidIsForeground([Hires]::CapturedPid)) { return }      # never type into another window
    $part=$plan -split ' '
    switch($part[0]) {
        'look' { [HiresInput]::Look([int]$part[1],[int]$part[2]) }
        'hold-key' {
            $vk=[int]$part[1]
            if(-not $heldKeys.ContainsKey($vk)) { [HiresInput]::Key([uint16]$vk,$true) }
            $heldKeys[$vk]=[datetime]::UtcNow
        }
        'hold-button' {
            $button=[int]$part[1]
            if(-not $heldButtons.ContainsKey($button)) { [HiresInput]::Button($button,$true) }
            $heldButtons[$button]=[datetime]::UtcNow
        }
        'tap' { [HiresInput]::Key([uint16][int]$part[1],$true); Start-Sleep -Milliseconds 15; [HiresInput]::Key([uint16][int]$part[1],$false) }
    }
}
# The IIe sends a key once, and again while it repeats: a held control is let go when the repeats stop.
function Release-Held([switch]$All) {
    $now=[datetime]::UtcNow
    foreach($vk in @($heldKeys.Keys)) { if($All -or ($now-$heldKeys[$vk]).TotalMilliseconds -gt $HoldMs) { [HiresInput]::Key([uint16]$vk,$false); $heldKeys.Remove($vk) } }
    foreach($button in @($heldButtons.Keys)) { if($All -or ($now-$heldButtons[$button]).TotalMilliseconds -gt $HoldMs) { [HiresInput]::Button([int]$button,$false); $heldButtons.Remove($button) } }
}
$watch=[Diagnostics.Stopwatch]::StartNew(); $sent=0
try {
    Write-Output "A2HR $version / $Action / $Source. Preview approximates artifact colors; actual NTSC output varies."
    if (Stopping) { return }
    if ($Action -eq 'Bootstrap') {
        $binary=[IO.File]::ReadAllBytes((Join-Path $project "build\$version\A2HR-RX.BIN"))
        if ($binary.Length -lt 6 -or $binary[0] -ne 0x4C -or [Text.Encoding]::ASCII.GetString($binary) -notmatch "A2HR RX V$([regex]::Escape($version))") { throw 'Receiver binary is missing or does not match this release.' }
        $binary[3]=[byte]$Slot; $binary[4]=[byte]$(if($Baud -eq 115200){0x10}else{0x1F}); $binary[5]=1
        $serial=New-Object IO.Ports.SerialPort $Port,9600,([IO.Ports.Parity]::None),8,([IO.Ports.StopBits]::One)
        $serial.WriteTimeout=3000; $serial.DtrEnable=$true; $serial.RtsEnable=$true; $serial.Open()
        # User prepares SSC serial input before this explicit action. Send monitor text, not a disk write.
        $serial.Write("CALL -151`r"); Start-Sleep -Milliseconds 200
        for($offset=0;$offset -lt $binary.Length;$offset+=8) {
            if(Stopping) { Write-Output 'Bootstrap cancelled. Reset the Apple II to restore local input; partial receiver was not started.'; return }
            $end=[math]::Min($offset+7,$binary.Length-1)
            $hex=($binary[$offset..$end] | ForEach-Object {$_.ToString('X2')}) -join ' '
            $serial.Write(('{0:X4}: {1}' -f (0x6000+$offset),$hex)+"`r")
            Start-Sleep -Milliseconds 100
            $null=$serial.ReadExisting()
        }
        if(Stopping) { return }
        $serial.Write("6000G`r")
        $drain=[Diagnostics.Stopwatch]::StartNew()
        while($serial.BytesToWrite -gt 0 -and $drain.Elapsed.TotalSeconds -lt 3) { Start-Sleep -Milliseconds 20 }
        Write-Output "Receiver uploaded to RAM at `$6000: slot $Slot, $Baud baud. Check the IIe for WAITING FOR HI-RES, then start Hi-Res stream. Upload is not a hardware acknowledgement."
        return
    }
    # Validate capture/conversion before opening serial.
    $frame=Build-Frame; [Hires]::Publish($frame,$OutputDir)
    if($Action -eq 'Preview') {
        $last=[Diagnostics.Stopwatch]::StartNew()
        while(-not ((Stopping) -or ($Duration -gt 0 -and $watch.Elapsed.TotalSeconds -ge $Duration))) {
            if($sent -gt 0) { $frame.Dispose(); $frame=Build-Frame; [Hires]::Publish($frame,$OutputDir) }
            $sent++
            $rate=if($sent -lt 2){'warming up'}else{('{0:N2} fps average' -f (($sent-1)/[math]::Max(.001,$watch.Elapsed.TotalSeconds)))}
            Write-Output ("frame {0} / {1} / {2} / 8192-byte HGR" -f $sent,$rate,$Action)
            if($Once) { break }
            while($last.Elapsed.TotalSeconds -lt (1.0/$Fps) -and -not (Stopping)) { Start-Sleep -Milliseconds 25 }
            $last.Restart()
        }
        return
    }
    if(Stopping) { return }
    if($Loopback) {
        $client=New-Object Net.Sockets.TcpClient; $client.NoDelay=$true; $client.Connect('127.0.0.1',$Loopback); $net=$client.GetStream()
        Write-Output "Check link to 127.0.0.1:$Loopback. No serial port is opened."
    } else {
        $serial=New-Object IO.Ports.SerialPort $Port,$Baud,([IO.Ports.Parity]::None),8,([IO.Ports.StopBits]::One)
        $serial.ReadTimeout=100; $serial.WriteTimeout=5000; $serial.DtrEnable=$true; $serial.RtsEnable=$true
        $serial.Open(); $serial.DiscardInBuffer()
    }
    $link=New-Object HiresLink; $link.KeyEvery=$KeyEvery; $link.RawOnly=($Pages -eq 'Raw')
    Link-Write ([byte[]]@(0x48))
    Write-Output 'Hello sent. Waiting for the A2HR receiver request; the A2MC and original vnIIc receivers are incompatible.'
    $incoming=New-Object byte[] 256
    $asked=$false; $first=$true; $kind=''; $stopClock=$null
    $waiting=[Diagnostics.Stopwatch]::StartNew(); $pace=[Diagnostics.Stopwatch]::StartNew()
    while($true) {
        $stop=(Stopping) -or ($Duration -gt 0 -and $watch.Elapsed.TotalSeconds -ge $Duration)
        if((Link-Available) -gt 0) {
            $count=Link-Read $incoming
            for($i=0;$i -lt $count;$i++) {
                $what=$link.Feed($incoming[$i])
                if($what -eq [HiresLink]::Request) {
                    $asked=$true; $link.Report($link.Marker)
                    $now=if($link.Version2){'Version 2 receiver: packed pages, keys and page reports.'}else{'Version 1 receiver: raw pages only. It sends no keys and does not report on pages.'}
                    if($now -ne $kind) { $kind=$now; Write-Output $kind }
                    if($link.Note) { Write-Output $link.Note }
                } elseif($what -ge 0) { Use-Key $what }
            }
        } else { Start-Sleep -Milliseconds 5 }
        Release-Held
        if(-not $asked) {
            if($stop) {
                # A page already on its way is allowed the time a raw page takes, and a little more, to be
                # answered, so that the stop lands at a boundary.
                if($null -eq $stopClock) { $stopClock=[Diagnostics.Stopwatch]::StartNew() }
                if($sent -eq 0 -or $stopClock.Elapsed.TotalSeconds -gt (2 + 1.5*81940/$Baud)) { Write-Output 'Stopped while waiting for receiver; press Esc on the IIe if it is still waiting.'; break }
            } elseif($waiting.Elapsed.TotalSeconds -gt 8) { throw 'No receiver request for eight seconds. Check A2HR receiver, slot, baud, and cable; press Esc and restart after a partial transfer.' }
            continue
        }
        # Only send stop at a request boundary.
        if($stop) { Link-Write ([byte[]]@(0)); Start-Sleep -Milliseconds 100; Write-Output 'Receiver stop command sent at frame boundary; port is closing.'; break }
        if(-not $first -and $pace.Elapsed.TotalSeconds -lt (1.0/$Fps)) { continue }
        if(-not $first) { $frame.Dispose(); $frame=Build-Frame; [Hires]::Publish($frame,$OutputDir) }
        $first=$false; $pace.Restart()
        $packet=$link.Compose($frame.Bytes)
        if($null -eq $packet) { continue }       # the IIe already shows this picture: its request is kept until the picture changes
        Link-Write $packet
        $asked=$false; $waiting.Restart(); $sent++
        $rate=if($sent -lt 2){'warming up'}else{('{0:N2} fps average' -f (($sent-1)/[math]::Max(.001,$watch.Elapsed.TotalSeconds)))}
        Write-Output ("frame {0} / {1} / {2} / {3} page, {4} bytes" -f $sent,$rate,$Action,$link.Kind,$packet.Length)
    }
} finally {
    Release-Held -All
    if($null -ne $frame) { $frame.Dispose() }
    if($null -ne $net) { $net.Dispose() }
    if($null -ne $client) { $client.Close() }
    if($null -ne $serial) { if($serial.IsOpen){$serial.Close()}; $serial.Dispose() }
    if($null -ne $link -and $link.Version2) { Write-Output ("Receiver reported {0} page(s) shown, {1} refused, {2} lost." -f $link.Accepted,$link.Refused,$link.Spoiled) }
    Write-Output "Finished $Action; $sent frame(s)."
}
