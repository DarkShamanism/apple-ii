param(
    [string]$Port,
    [int]$Baud = 115200,
    [double]$Fps = 8.0,
    [int]$Frames = 0,
    [double]$Duration = 0,
    [switch]$Demo,
    [string]$Image,
    [string]$Region,
    [string]$WindowTitle,
    [ValidateSet("Crop", "Stretch", "Letterbox")]
    [string]$Fit = "Crop",
    [ValidateSet("Lores", "Dlgr", "DlgrC")]
    [string]$Mode = "Lores",
    [ValidateSet("Left", "Right", "None")]
    [string]$AuxRotate = "Left",
    [switch]$Dither,
    [double]$Saturation = 1.35,
    [double]$Contrast = 1.12,
    [double]$Gamma = 1.15,
    [switch]$NoInput,
    [int]$LookStep = 40,
    [int]$HoldMs = 350,
    [int]$PhotoRotate = 0,
    [string]$PhotoTest,
    [switch]$NoSounds,
    [string]$McLog = "$env:APPDATA\.minecraft\logs\latest.log",
    [switch]$DryRun,
    [string]$OutFrame,
    [string]$Preview,
    [switch]$SwapNibbles,
    [double]$OpenDelay = 1.0,
    [int]$StatsEvery = 30,
    [string]$StopFile
)

$ErrorActionPreference = "Stop"
$A2mcVersion = (Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) "VERSION") -Raw).Trim()
Write-Host "A2MC streamer $A2mcVersion"

$LoresWidth = 40
$LoresHeight = 48
$PageSize = 1024
# Double lo-res: 80x48 from main+aux text pages, 2K per frame.
# DlgrC compresses each frame (RLE keyframes + RLE'd XOR deltas).
$GridWidth = if ($Mode -ne "Lores") { 80 } else { 40 }
$PayloadSize = if ($Mode -ne "Lores") { 2048 } else { 1024 }
$ModeByte = if ($Mode -ne "Lores") { 2 } else { 1 }
$AuxRotateCode = switch ($AuxRotate) { "Left" { 1 } "Right" { 2 } default { 0 } }
$KeyframeEvery = 16

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# The per-pixel work lives in compiled C# so the loop can keep up with
# 8-10 fps; PowerShell-level pixel loops cannot. If you edit this class,
# start a fresh PowerShell session: Add-Type cannot replace a loaded type.
if (-not ([System.Management.Automation.PSTypeName]'A2MC').Type) {
    Add-Type -ReferencedAssemblies @("System.Drawing") -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class A2MC {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    public static int[] GetClientRegion(IntPtr hWnd) {
        RECT rect;
        if (!GetClientRect(hWnd, out rect)) {
            throw new InvalidOperationException("GetClientRect failed (window gone?).");
        }
        POINT point = new POINT();
        if (!ClientToScreen(hWnd, ref point)) {
            throw new InvalidOperationException("ClientToScreen failed (window gone?).");
        }
        return new int[] { point.X, point.Y, rect.Right - rect.Left, rect.Bottom - rect.Top };
    }

    // Apple II lo-res colors 0-15, same values as the Python streamer.
    public static readonly int[] PalR = { 0x00, 0x9D, 0x40, 0xD6, 0x00, 0x80, 0x2F, 0xBF, 0x6F, 0xFF, 0xC0, 0xFF, 0x2F, 0xFF, 0x72, 0xFF };
    public static readonly int[] PalG = { 0x00, 0x1B, 0x2C, 0x43, 0x7A, 0x80, 0x95, 0xD7, 0x4F, 0x6A, 0xC0, 0xA0, 0xD1, 0xF0, 0xFF, 0xFF };
    public static readonly int[] PalB = { 0x00, 0x6C, 0xB8, 0xFF, 0x3D, 0x80, 0xFF, 0xFF, 0x1F, 0x00, 0xC0, 0xD0, 0x41, 0x4A, 0xB5, 0xFF };

    // Map a small bitmap to lo-res color indices with a weighted RGB
    // distance; optionally Floyd-Steinberg dither. Gamma, saturation and
    // contrast are applied first so muted game scenes spread across more
    // of the 16-color palette instead of collapsing onto a few entries.
    public static byte[] ToIndices(Bitmap bmp, bool dither, double saturation, double contrast, double gamma) {
        int w = bmp.Width;
        int h = bmp.Height;
        BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        int stride = data.Stride;
        byte[] px = new byte[stride * h];
        Marshal.Copy(data.Scan0, px, 0, px.Length);
        bmp.UnlockBits(data);

        float[] gammaLut = new float[256];
        for (int i = 0; i < 256; i++) {
            gammaLut[i] = (float)(255.0 * Math.Pow(i / 255.0, 1.0 / gamma));
        }
        float sat = (float)saturation;
        float con = (float)contrast;

        byte[] result = new byte[w * h];
        float[] errR = new float[w * h];
        float[] errG = new float[w * h];
        float[] errB = new float[w * h];

        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int o = y * stride + x * 3;
                int p = y * w + x;
                float b = gammaLut[px[o]];
                float g = gammaLut[px[o + 1]];
                float r = gammaLut[px[o + 2]];
                float gray = r * 0.299f + g * 0.587f + b * 0.114f;
                r = gray + (r - gray) * sat;
                g = gray + (g - gray) * sat;
                b = gray + (b - gray) * sat;
                r = (r - 128f) * con + 128f;
                g = (g - 128f) * con + 128f;
                b = (b - 128f) * con + 128f;
                if (r < 0f) r = 0f; if (r > 255f) r = 255f;
                if (g < 0f) g = 0f; if (g > 255f) g = 255f;
                if (b < 0f) b = 0f; if (b > 255f) b = 255f;
                if (dither) {
                    r += errR[p]; g += errG[p]; b += errB[p];
                    if (r < 0f) r = 0f; if (r > 255f) r = 255f;
                    if (g < 0f) g = 0f; if (g > 255f) g = 255f;
                    if (b < 0f) b = 0f; if (b > 255f) b = 255f;
                }


                int best = 0;
                double bestDist = double.MaxValue;
                for (int i = 0; i < 16; i++) {
                    double dr = r - PalR[i];
                    double dg = g - PalG[i];
                    double db = b - PalB[i];
                    double dist = dr * dr * 30.0 + dg * dg * 59.0 + db * db * 11.0;
                    if (dist < bestDist) { bestDist = dist; best = i; }
                }
                result[p] = (byte)best;

                if (dither) {
                    float er = r - PalR[best];
                    float eg = g - PalG[best];
                    float eb = b - PalB[best];
                    if (x + 1 < w) {
                        errR[p + 1] += er * 7f / 16f; errG[p + 1] += eg * 7f / 16f; errB[p + 1] += eb * 7f / 16f;
                    }
                    if (y + 1 < h) {
                        if (x > 0) {
                            errR[p + w - 1] += er * 3f / 16f; errG[p + w - 1] += eg * 3f / 16f; errB[p + w - 1] += eb * 3f / 16f;
                        }
                        errR[p + w] += er * 5f / 16f; errG[p + w] += eg * 5f / 16f; errB[p + w] += eb * 5f / 16f;
                        if (x + 1 < w) {
                            errR[p + w + 1] += er * 1f / 16f; errG[p + w + 1] += eg * 1f / 16f; errB[p + w + 1] += eb * 1f / 16f;
                        }
                    }
                }
            }
        }
        return result;
    }

    // Pack 40x48 indices into the 1024-byte interleaved text-page image.
    // Low nibble = top pixel of the pair unless swap is set.
    public static byte[] PackPage(byte[] indices, bool swap) {
        if (indices.Length != 40 * 48) throw new ArgumentException("expected 1920 indices");
        byte[] page = new byte[1024];
        for (int y = 0; y < 48; y += 2) {
            int row = y / 2;
            int rowBase = (row & 7) * 0x80 + (row >> 3) * 0x28;
            for (int x = 0; x < 40; x++) {
                int top = indices[y * 40 + x] & 0x0F;
                int bottom = indices[(y + 1) * 40 + x] & 0x0F;
                page[rowBase + x] = (byte)(swap ? ((top << 4) | bottom) : (top | (bottom << 4)));
            }
        }
        return page;
    }

    // Pack 80x48 indices into the 2048-byte double lo-res image:
    // first KB is the AUX bank (even screen columns), second KB is
    // MAIN (odd columns). Aux nibbles are bit-rotated because the
    // IIe displays aux lo-res nibbles rotated by one bit.
    // auxRotate: 0 = none, 1 = rotate left, 2 = rotate right.
    public static byte[] PackDlgr(byte[] indices, bool swap, int auxRotate) {
        if (indices.Length != 80 * 48) throw new ArgumentException("expected 3840 indices");
        byte[] page = new byte[2048];
        for (int y = 0; y < 48; y += 2) {
            int row = y / 2;
            int rowBase = (row & 7) * 0x80 + (row >> 3) * 0x28;
            for (int c = 0; c < 40; c++) {
                int topA = indices[y * 80 + c * 2] & 0x0F;
                int botA = indices[(y + 1) * 80 + c * 2] & 0x0F;
                int topM = indices[y * 80 + c * 2 + 1] & 0x0F;
                int botM = indices[(y + 1) * 80 + c * 2 + 1] & 0x0F;
                if (auxRotate == 1) {
                    topA = ((topA << 1) | (topA >> 3)) & 0x0F;
                    botA = ((botA << 1) | (botA >> 3)) & 0x0F;
                } else if (auxRotate == 2) {
                    topA = ((topA >> 1) | (topA << 3)) & 0x0F;
                    botA = ((botA >> 1) | (botA << 3)) & 0x0F;
                }
                page[rowBase + c] = (byte)(swap ? ((topA << 4) | botA) : (topA | (botA << 4)));
                page[1024 + rowBase + c] = (byte)(swap ? ((topM << 4) | botM) : (topM | (botM << 4)));
            }
        }
        return page;
    }

    public static byte Checksum(byte[] data) {
        byte v = 0;
        for (int i = 0; i < data.Length; i++) v ^= data[i];
        return v;
    }

    // Token stream: $01-$7F = run (next byte repeated n times),
    // $80-$FF = (n - $7F) literal bytes, $00 never emitted.
    public static byte[] RleEncode(byte[] data) {
        System.Collections.Generic.List<byte> output = new System.Collections.Generic.List<byte>(data.Length + 64);
        int i = 0;
        while (i < data.Length) {
            int run = 1;
            while (i + run < data.Length && data[i + run] == data[i] && run < 127) run++;
            if (run >= 3) {
                output.Add((byte)run);
                output.Add(data[i]);
                i += run;
                continue;
            }
            int start = i;
            int lit = 0;
            while (i < data.Length && lit < 128) {
                int r = 1;
                while (i + r < data.Length && data[i + r] == data[i] && r < 127) r++;
                if (r >= 3) break;
                i++; lit++;
            }
            output.Add((byte)(0x7F + lit));
            for (int k = 0; k < lit; k++) output.Add(data[start + k]);
        }
        return output.ToArray();
    }

    // Reference decoder mirroring the 6502's semantics; used for
    // self-tests. basis == null decodes a keyframe; otherwise the
    // stream is an XOR delta against basis.
    public static byte[] RleDecode(byte[] comp, byte[] basis) {
        byte[] result = (basis == null) ? new byte[2048] : (byte[])basis.Clone();
        int o = 0, i = 0;
        while (o < 2048) {
            if (i >= comp.Length) throw new InvalidOperationException("source exhausted");
            int t = comp[i++];
            if (t == 0) throw new InvalidOperationException("zero token");
            if (t < 0x80) {
                if (i >= comp.Length) throw new InvalidOperationException("missing run value");
                byte v = comp[i++];
                if (o + t > 2048) throw new InvalidOperationException("output overflow");
                for (int k = 0; k < t; k++) { if (basis == null) result[o] = v; else result[o] ^= v; o++; }
            } else {
                int n = t - 0x7F;
                if (o + n > 2048 || i + n > comp.Length) throw new InvalidOperationException("overflow");
                for (int k = 0; k < n; k++) { byte v = comp[i++]; if (basis == null) result[o] = v; else result[o] ^= v; o++; }
            }
        }
        if (i != comp.Length) throw new InvalidOperationException("trailing source bytes");
        return result;
    }

    public static byte[] XorBytes(byte[] a, byte[] b) {
        byte[] r = new byte[a.Length];
        for (int i = 0; i < a.Length; i++) r[i] = (byte)(a[i] ^ b[i]);
        return r;
    }

    // Compressed packet: sync + mode + 16-bit length + payload + checksum.
    public static byte[] BuildPacketC(byte[] payload, byte mode) {
        byte[] packet = new byte[6 + payload.Length + 1];
        packet[0] = 0xA2; packet[1] = 0x4D; packet[2] = 0x43; packet[3] = mode;
        packet[4] = (byte)(payload.Length & 0xFF);
        packet[5] = (byte)(payload.Length >> 8);
        Array.Copy(payload, 0, packet, 6, payload.Length);
        packet[packet.Length - 1] = Checksum(payload);
        return packet;
    }

    public static byte[] BuildPacket(byte[] payload, byte mode) {
        byte[] packet = new byte[4 + payload.Length + 1];
        packet[0] = 0xA2; packet[1] = 0x4D; packet[2] = 0x43; packet[3] = mode;
        Array.Copy(payload, 0, packet, 4, payload.Length);
        packet[packet.Length - 1] = Checksum(payload);
        return packet;
    }

    // 140x192x16 double hi-res: 28-bit groups of 7 pixels spread over
    // aux/main byte pairs (LSB first, bit 7 unused), hi-res row
    // interleave. First 8K of the result is the aux bank.
    public static byte[] PackDhgr(byte[] indices, int rot) {
        if (indices.Length != 140 * 192) throw new ArgumentException("expected 26880 indices");
        byte[] o = new byte[16384];
        for (int y = 0; y < 192; y++) {
            int rb = (y & 7) * 0x400 + ((y >> 3) & 7) * 0x80 + (y >> 6) * 0x28;
            for (int g = 0; g < 20; g++) {
                uint bits = 0;
                for (int p = 0; p < 7; p++) {
                    int c = indices[y * 140 + g * 7 + p] & 0x0F;
                    if (rot != 0) c = ((c << rot) | (c >> (4 - rot))) & 0x0F;
                    bits |= (uint)c << (p * 4);
                }
                int off = rb + g * 2;
                o[off] = (byte)(bits & 0x7F);
                o[8192 + off] = (byte)((bits >> 7) & 0x7F);
                o[off + 1] = (byte)((bits >> 14) & 0x7F);
                o[8192 + off + 1] = (byte)((bits >> 21) & 0x7F);
            }
        }
        return o;
    }

    // Photo pipeline: gamma-lifted luminance, Floyd-Steinberg to 1-bit.
    public static byte[] DitherMono(Bitmap bmp) {
        int w = bmp.Width, h = bmp.Height;
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        int stride = d.Stride;
        byte[] px = new byte[stride * h];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        bmp.UnlockBits(d);
        float[] lum = new float[w * h];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int o = y * stride + x * 3;
                double v = px[o] * 0.114 + px[o + 1] * 0.587 + px[o + 2] * 0.299;
                lum[y * w + x] = (float)(255.0 * Math.Pow(v / 255.0, 1.0 / 1.3));
            }
        }
        byte[] outb = new byte[w * h];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int p = y * w + x;
                float v = lum[p];
                byte b = (byte)(v >= 128f ? 1 : 0);
                outb[p] = b;
                float err = v - (b == 1 ? 255f : 0f);
                if (x + 1 < w) lum[p + 1] += err * 7f / 16f;
                if (y + 1 < h) {
                    if (x > 0) lum[p + w - 1] += err * 3f / 16f;
                    lum[p + w] += err * 5f / 16f;
                    if (x + 1 < w) lum[p + w + 1] += err * 1f / 16f;
                }
            }
        }
        return outb;
    }

    // 280x192 1-bit -> 8K hi-res page (7 pixels/byte LSB-first, bit 7 clear).
    public static byte[] PackHgr(byte[] bits) {
        if (bits.Length != 280 * 192) throw new ArgumentException("expected 53760 bits");
        byte[] o = new byte[8192];
        for (int y = 0; y < 192; y++) {
            int rb = (y & 7) * 0x400 + ((y >> 3) & 7) * 0x80 + (y >> 6) * 0x28;
            for (int bx = 0; bx < 40; bx++) {
                int v = 0;
                for (int p = 0; p < 7; p++) {
                    if (bits[y * 280 + bx * 7 + p] != 0) v |= 1 << p;
                }
                o[rb + bx] = (byte)v;
            }
        }
        return o;
    }

    public static byte[] UnpackHgr(byte[] hgr) {
        byte[] bits = new byte[280 * 192];
        for (int y = 0; y < 192; y++) {
            int rb = (y & 7) * 0x400 + ((y >> 3) & 7) * 0x80 + (y >> 6) * 0x28;
            for (int bx = 0; bx < 40; bx++) {
                int v = hgr[rb + bx];
                for (int p = 0; p < 7; p++) {
                    bits[y * 280 + bx * 7 + p] = (byte)((v >> p) & 1);
                }
            }
        }
        return bits;
    }

    public static byte[] UnpackDhgr(byte[] dhgr, int rot) {
        byte[] indices = new byte[140 * 192];
        for (int y = 0; y < 192; y++) {
            int rb = (y & 7) * 0x400 + ((y >> 3) & 7) * 0x80 + (y >> 6) * 0x28;
            for (int g = 0; g < 20; g++) {
                int off = rb + g * 2;
                uint bits = (uint)(dhgr[off] & 0x7F)
                          | ((uint)(dhgr[8192 + off] & 0x7F) << 7)
                          | ((uint)(dhgr[off + 1] & 0x7F) << 14)
                          | ((uint)(dhgr[8192 + off + 1] & 0x7F) << 21);
                for (int p = 0; p < 7; p++) {
                    int c = (int)((bits >> (p * 4)) & 0x0F);
                    if (rot != 0) c = ((c >> rot) | (c << (4 - rot))) & 0x0F;
                    indices[y * 140 + g * 7 + p] = (byte)c;
                }
            }
        }
        return indices;
    }
}

// Injects Apple II keystrokes into the game via SendInput, with a
// foreground guard so stray bytes can never type into other windows.
public static class A2In {
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint code, uint mapType);

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    private struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public UNION u; }

    public static bool PidIsForeground(int pid) {
        uint p;
        GetWindowThreadProcessId(GetForegroundWindow(), out p);
        return p == (uint)pid;
    }

    public static void Key(ushort vk, bool down) {
        INPUT i = new INPUT();
        i.type = 1;
        i.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
        i.u.ki.dwFlags = (uint)(0x0008 | (down ? 0 : 0x0002));   // SCANCODE (+ KEYUP)
        SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Look(int dx, int dy) {
        INPUT i = new INPUT();
        i.type = 0;
        i.u.mi.dx = dx; i.u.mi.dy = dy;
        i.u.mi.dwFlags = 0x0001;                                  // relative move
        SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Button(int button, bool down) {
        INPUT i = new INPUT();
        i.type = 0;
        i.u.mi.dwFlags = (uint)(button == 0 ? (down ? 0x0002 : 0x0004) : (down ? 0x0008 : 0x0010));
        SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@
}

function Get-TextPageOffset {
    param([int]$TextRow, [int]$Column)
    return (($TextRow -band 7) * 0x80) + ([math]::Floor($TextRow / 8) * 0x28) + $Column
}

function Convert-PageToIndices {
    param([byte[]]$Page)
    $Indices = New-Object byte[] ($LoresWidth * $LoresHeight)
    for ($Y = 0; $Y -lt $LoresHeight; $Y += 2) {
        $RowBase = Get-TextPageOffset ([int]($Y / 2)) 0
        for ($X = 0; $X -lt $LoresWidth; $X++) {
            $Value = $Page[$RowBase + $X]
            if ($SwapNibbles) {
                $Top = ($Value -shr 4) -band 0x0F
                $Bottom = $Value -band 0x0F
            } else {
                $Top = $Value -band 0x0F
                $Bottom = ($Value -shr 4) -band 0x0F
            }
            $Indices[$Y * $LoresWidth + $X] = [byte]$Top
            $Indices[($Y + 1) * $LoresWidth + $X] = [byte]$Bottom
        }
    }
    return $Indices
}

function Get-DemoIndices {
    param([int]$FrameNo)
    $Indices = New-Object byte[] ($LoresWidth * $LoresHeight)
    $SunX = 5 + ($FrameNo % 28)
    $CloudX = (($FrameNo * 2) % 52) - 8
    $I = 0
    for ($Y = 0; $Y -lt $LoresHeight; $Y++) {
        for ($X = 0; $X -lt $LoresWidth; $X++) {
            if ($Y -lt 22) {
                [byte]$Color = if ($Y -lt 16) { 7 } else { 6 }
                if ((($X - $SunX) * ($X - $SunX) + ($Y - 7) * ($Y - 7)) -lt 18) {
                    $Color = 13
                }
                if ([math]::Abs($Y - 10) -lt 2 -and $X -ge $CloudX -and $X -le ($CloudX + 10)) {
                    $Color = 15
                }
            } elseif ($Y -lt 28) {
                [byte]$Color = if ((($X + [int]($FrameNo / 2)) % 5) -eq 0) { 14 } else { 12 }
            } else {
                $Noise = ($X * 7 + $Y * 3 + $FrameNo) % 11
                [byte]$Color = if ($Noise -lt 7) { 8 } else { 9 }
                if (($Y -eq 34 -or $Y -eq 35) -and $X -gt 7 -and $X -lt 18) {
                    $Color = 5
                }
            }

            if (($X -eq 20 -and $Y -ge 20 -and $Y -le 28) -or ($Y -eq 24 -and $X -ge 16 -and $X -le 24)) {
                $Color = 15
            }
            $Indices[$I] = $Color
            $I++
        }
    }
    return $Indices
}

# Persistent target bitmap (40x48 or 80x48); reused every frame.
$script:SmallBitmap = New-Object System.Drawing.Bitmap $GridWidth, $LoresHeight, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$script:SmallGfx = [System.Drawing.Graphics]::FromImage($script:SmallBitmap)
$script:SmallGfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
$script:SmallGfx.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

# Reused capture bitmap; reallocated only when the region size changes.
$script:CapBitmap = $null
$script:CapGfx = $null

function Convert-BitmapToIndices {
    param([System.Drawing.Bitmap]$SourceBitmap)
    $Graphics = $script:SmallGfx
    $Graphics.Clear([System.Drawing.Color]::Black)

    $SourceRect = New-Object System.Drawing.Rectangle 0, 0, $SourceBitmap.Width, $SourceBitmap.Height
    $DestRect = New-Object System.Drawing.Rectangle 0, 0, $GridWidth, $LoresHeight

    if ($Fit -eq "Crop") {
        # The full grid fills a 4:3 CRT, so crop the source at 4:3 to
        # keep the picture undistorted (grid pixels are not square).
        $TargetAspect = 4.0 / 3.0
        $SourceAspect = $SourceBitmap.Width / $SourceBitmap.Height
        if ($SourceAspect -gt $TargetAspect) {
            $CropWidth = [int]($SourceBitmap.Height * $TargetAspect)
            $SourceRect = New-Object System.Drawing.Rectangle ([int](($SourceBitmap.Width - $CropWidth) / 2)), 0, $CropWidth, $SourceBitmap.Height
        } else {
            $CropHeight = [int]($SourceBitmap.Width / $TargetAspect)
            $SourceRect = New-Object System.Drawing.Rectangle 0, ([int](($SourceBitmap.Height - $CropHeight) / 2)), $SourceBitmap.Width, $CropHeight
        }
    } elseif ($Fit -eq "Letterbox") {
        $Scale = [math]::Min($GridWidth / $SourceBitmap.Width, $LoresHeight / $SourceBitmap.Height)
        $DestWidth = [int]($SourceBitmap.Width * $Scale)
        $DestHeight = [int]($SourceBitmap.Height * $Scale)
        $DestRect = New-Object System.Drawing.Rectangle ([int](($GridWidth - $DestWidth) / 2)), ([int](($LoresHeight - $DestHeight) / 2)), $DestWidth, $DestHeight
    }

    $Graphics.DrawImage($SourceBitmap, $DestRect, $SourceRect, [System.Drawing.GraphicsUnit]::Pixel)
    return [A2MC]::ToIndices($script:SmallBitmap, [bool]$Dither, $Saturation, $Contrast, $Gamma)
}

function Get-RegionFromString {
    param([string]$Value)
    $Parts = $Value.Split(",") | ForEach-Object { [int]$_.Trim() }
    if ($Parts.Count -ne 4 -or $Parts[2] -le 0 -or $Parts[3] -le 0) {
        throw "Region must be left,top,width,height."
    }
    return $Parts
}

function Resolve-WindowHandle {
    param([string]$Title)
    $Process = Get-Process | Where-Object {
        $_.MainWindowTitle -and $_.MainWindowTitle.ToLowerInvariant().Contains($Title.ToLowerInvariant())
    } | Select-Object -First 1
    if (-not $Process) {
        throw "No visible process window title contains '$Title'."
    }
    Write-Host ("Tracking window: '{0}' (pid {1})" -f $Process.MainWindowTitle, $Process.Id)
    $script:TrackedPid = $Process.Id
    return $Process.MainWindowHandle
}

function Get-ScreenIndices {
    param([int[]]$CaptureRegion)
    if ($null -eq $script:CapBitmap -or $script:CapBitmap.Width -ne $CaptureRegion[2] -or $script:CapBitmap.Height -ne $CaptureRegion[3]) {
        if ($script:CapGfx) { $script:CapGfx.Dispose() }
        if ($script:CapBitmap) { $script:CapBitmap.Dispose() }
        $script:CapBitmap = New-Object System.Drawing.Bitmap $CaptureRegion[2], $CaptureRegion[3]
        $script:CapGfx = [System.Drawing.Graphics]::FromImage($script:CapBitmap)
    }
    $script:CapGfx.CopyFromScreen($CaptureRegion[0], $CaptureRegion[1], 0, 0, $script:CapBitmap.Size)
    return Convert-BitmapToIndices $script:CapBitmap
}

function Save-Preview {
    param([byte[]]$Indices, [string]$Path)
    $SmallBitmap = New-Object System.Drawing.Bitmap $LoresWidth, $LoresHeight
    $PreviewBitmap = New-Object System.Drawing.Bitmap ($LoresWidth * 8), ($LoresHeight * 8)
    $Graphics = [System.Drawing.Graphics]::FromImage($PreviewBitmap)
    try {
        $I = 0
        for ($Y = 0; $Y -lt $LoresHeight; $Y++) {
            for ($X = 0; $X -lt $LoresWidth; $X++) {
                $C = $Indices[$I] -band 0x0F
                $SmallBitmap.SetPixel($X, $Y, [System.Drawing.Color]::FromArgb([A2MC]::PalR[$C], [A2MC]::PalG[$C], [A2MC]::PalB[$C]))
                $I++
            }
        }
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $Graphics.DrawImage($SmallBitmap, 0, 0, $PreviewBitmap.Width, $PreviewBitmap.Height)
        $Directory = Split-Path -Parent $Path
        if ($Directory) {
            New-Item -ItemType Directory -Force -Path $Directory | Out-Null
        }
        $PreviewBitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $Graphics.Dispose()
        $SmallBitmap.Dispose()
        $PreviewBitmap.Dispose()
    }
}

$script:ImageBitmap = $null

function Get-NextPage {
    param([int]$FrameNo, [int[]]$CaptureRegion)
    if ($Demo) {
        $Indices = Get-DemoIndices $FrameNo
        if ($Mode -ne "Lores") {
            # Pixel-double the 40-wide demo scene to 80 wide.
            $Wide = New-Object byte[] (80 * $LoresHeight)
            for ($I = 0; $I -lt $Indices.Length; $I++) {
                $Wide[$I * 2] = $Indices[$I]
                $Wide[$I * 2 + 1] = $Indices[$I]
            }
            $Indices = $Wide
        }
    } elseif ($Image) {
        if ($null -eq $script:ImageBitmap) {
            $script:ImageBitmap = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Image))
        }
        $Indices = Convert-BitmapToIndices $script:ImageBitmap
    } else {
        $Indices = Get-ScreenIndices $CaptureRegion
    }
    if ($Mode -ne "Lores") {
        return [A2MC]::PackDlgr($Indices, [bool]$SwapNibbles, $AuxRotateCode)
    }
    return [A2MC]::PackPage($Indices, [bool]$SwapNibbles)
}

# Pick the cheapest representation of this frame and build its packet.
# Returns packet, the chosen mode, and the receiver's decode-time gap.
function New-FramePacket {
    param([byte[]]$Page)
    if ($Mode -ne "DlgrC") {
        $GapMs = if ($Mode -eq "Dlgr") { 24 } else { 2 }
        return @([A2MC]::BuildPacket($Page, [byte]$ModeByte), $ModeByte, $GapMs)
    }
    $Payload = [A2MC]::RleEncode($Page)
    $PMode = 3
    if ($null -ne $script:PrevPage -and $script:SinceKey -lt $KeyframeEvery) {
        $Delta = [A2MC]::RleEncode([A2MC]::XorBytes($Page, $script:PrevPage))
        if ($Delta.Length -lt $Payload.Length) {
            $Payload = $Delta
            $PMode = 4
        }
    }
    $script:PrevPage = $Page
    if ($Payload.Length -ge 2048) {
        $script:SinceKey = 0        # raw refreshes the receiver's base too
        return @([A2MC]::BuildPacket($Page, 2), 2, 65)
    }
    if ($PMode -eq 4) {
        $script:SinceKey++
        return @([A2MC]::BuildPacketC($Payload, 4), 4, (24 + [int]($Payload.Length / 30)))
    }
    $script:SinceKey = 0
    return @([A2MC]::BuildPacketC($Payload, 3), 3, (45 + [int]($Payload.Length / 40)))
}

# ---- Apple II keyboard -> game input ----
$script:TrackedPid = 0
$script:HeldVk = @{}
$script:HeldBtn = @{}
$script:PhotoWanted = $false
$script:LogTick = 0

function Set-HeldKey {
    param([int]$Vk)
    if (-not $script:HeldVk.ContainsKey($Vk)) { [A2In]::Key([uint16]$Vk, $true) }
    $script:HeldVk[$Vk] = [datetime]::UtcNow
}

function Set-HeldButton {
    param([int]$Button)
    if (-not $script:HeldBtn.ContainsKey($Button)) { [A2In]::Button($Button, $true) }
    $script:HeldBtn[$Button] = [datetime]::UtcNow
}

function Process-SerialInput {
    while ($Serial.BytesToRead -gt 0) {
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { return }
        $B = $Serial.ReadByte() -band 0x7F
        $Code = [int][char]::ToUpperInvariant([char]$B)
        if ($Code -eq 80) {                       # P = photo
            $script:PhotoWanted = $true
            continue
        }
        if ($NoInput) { continue }
        if ($script:TrackedPid -ne 0 -and -not [A2In]::PidIsForeground($script:TrackedPid)) {
            continue                              # never type into other windows
        }
        switch ($Code) {
            8   { [A2In]::Look(-$LookStep, 0) }                       # left arrow
            21  { [A2In]::Look($LookStep, 0) }                        # right arrow
            11  { [A2In]::Look(0, -[int]($LookStep * 0.75)) }         # up arrow
            10  { [A2In]::Look(0, [int]($LookStep * 0.75)) }          # down arrow
            13  { Set-HeldButton 0 }                                  # Return = mine
            46  { Set-HeldButton 1 }                                  # . = use/place
            32  { Set-HeldKey 0x20 }                                  # space = jump
            87  { Set-HeldKey 0x57 }                                  # W
            65  { Set-HeldKey 0x41 }                                  # A
            83  { Set-HeldKey 0x53 }                                  # S
            68  { Set-HeldKey 0x44 }                                  # D
            default {
                if (($Code -ge 65 -and $Code -le 90) -or ($Code -ge 48 -and $Code -le 57)) {
                    [A2In]::Key([uint16]$Code, $true)                 # tap (E, Q, 1-9...)
                    Start-Sleep -Milliseconds 15
                    [A2In]::Key([uint16]$Code, $false)
                }
            }
        }
    }
    $Now = [datetime]::UtcNow
    foreach ($K in @($script:HeldVk.Keys)) {
        if (($Now - $script:HeldVk[$K]).TotalMilliseconds -gt $HoldMs) {
            [A2In]::Key([uint16]$K, $false)
            $script:HeldVk.Remove($K)
        }
    }
    foreach ($K in @($script:HeldBtn.Keys)) {
        if (($Now - $script:HeldBtn[$K]).TotalMilliseconds -gt $HoldMs) {
            [A2In]::Button([int]$K, $false)
            $script:HeldBtn.Remove($K)
        }
    }
}

# ---- Apple II speaker tones (packet mode 6) ----
# Each note is @(freqHz, ms); freq 0 = rest. Returns payload bytes
# and the total play time so the stream can stay silent that long.
function ConvertTo-ToneBytes {
    param([object[]]$Notes)
    $Entries = @()
    $TotalMs = 0.0
    foreach ($Note in $Notes) {
        $F = [double]$Note[0]
        $Ms = [double]$Note[1]
        $Rest = $F -le 0
        if ($Rest) { $F = 250 }
        $N = [int][math]::Round((1020500.0 / (2.0 * $F) - 20.0) / 19.0)
        if ($N -lt 1) { $N = 1 }
        if ($N -gt 127) { $N = 127 }
        $HalfCycles = 19 * $N + 20
        $Pairs = [int][math]::Round($Ms * 1020.5 / (2.0 * $HalfCycles))
        if ($Pairs -lt 1) { $Pairs = 1 }
        while ($Pairs -gt 0) {
            $T = [math]::Min(127, $Pairs)
            $Pairs -= $T
            $NB = $N
            if ($Rest) { $NB = $NB -bor 0x80 }
            $Entries += , @([byte]$NB, [byte]$T)
            $TotalMs += 2.0 * $T * $HalfCycles / 1020.5
        }
    }
    if ($Entries.Count -gt 100) { $Entries = $Entries[0..99] }
    $Payload = New-Object byte[] (1 + 2 * $Entries.Count)
    $Payload[0] = [byte]$Entries.Count
    for ($I = 0; $I -lt $Entries.Count; $I++) {
        $Payload[1 + 2 * $I] = $Entries[$I][0]
        $Payload[2 + 2 * $I] = $Entries[$I][1]
    }
    return , @($Payload, $TotalMs)
}

function Send-Tones {
    param([object[]]$Notes)
    if ($NoSounds -or $Mode -ne "DlgrC") { return }
    $R = ConvertTo-ToneBytes $Notes
    $Pkt = [A2MC]::BuildPacketC($R[0], 6)
    $Serial.Write($Pkt, 0, $Pkt.Length)
    # the receiver owns the CPU while it plays; keep the line silent
    Start-Sleep -Milliseconds ([int]($Pkt.Length * 10000.0 / $Baud) + [int]$R[1] + 8)
}

# ---- Minecraft log tail -> game-event sounds ----
$script:LogReader = $null
$script:PendingTones = New-Object System.Collections.Queue

function Test-GameLog {
    if ($NoSounds -or $Mode -ne "DlgrC") { return }
    try {
        if ($null -eq $script:LogReader) {
            if (-not (Test-Path $McLog)) { return }
            $Fs = New-Object System.IO.FileStream($McLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $Fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            $script:LogReader = New-Object System.IO.StreamReader($Fs)
            Write-Host "sound: tailing $McLog"
        }
        while ($null -ne ($Line = $script:LogReader.ReadLine())) {
            if ($Line -notmatch '\[CHAT\]') { continue }
            if ($Line -match 'has made the advancement|completed the challenge|reached the goal') {
                $script:PendingTones.Enqueue(@(@(523, 60), @(659, 60), @(784, 60), @(1047, 160)))
            } elseif ($Line -match 'was slain|was shot|drowned|blew up|fell from|hit the ground|burned to death|swim in lava|withered away|starved|suffocated|was killed|froze to death|was pricked|went up in flames|died') {
                $script:PendingTones.Enqueue(@(@(392, 140), @(294, 140), @(196, 280)))
            } elseif ($Line -match 'joined the game|left the game') {
                $script:PendingTones.Enqueue(@(@(660, 60), @(880, 100)))
            } else {
                $script:PendingTones.Enqueue(@(@(1500, 35)))
            }
        }
    } catch { }
}

function Get-PhotoIndices {
    param([int[]]$Reg)
    if ($null -eq $Reg) {
        $Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $Reg = [int[]]($Bounds.Left, $Bounds.Top, $Bounds.Width, $Bounds.Height)
    }
    if ($null -eq $script:CapBitmap -or $script:CapBitmap.Width -ne $Reg[2] -or $script:CapBitmap.Height -ne $Reg[3]) {
        if ($script:CapGfx) { $script:CapGfx.Dispose() }
        if ($script:CapBitmap) { $script:CapBitmap.Dispose() }
        $script:CapBitmap = New-Object System.Drawing.Bitmap $Reg[2], $Reg[3]
        $script:CapGfx = [System.Drawing.Graphics]::FromImage($script:CapBitmap)
    }
    $script:CapGfx.CopyFromScreen($Reg[0], $Reg[1], 0, 0, $script:CapBitmap.Size)
    $PhotoBmp = New-Object System.Drawing.Bitmap 280, 192, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $G = [System.Drawing.Graphics]::FromImage($PhotoBmp)
    try {
        $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $TargetAspect = 4.0 / 3.0
        $SrcAspect = $script:CapBitmap.Width / $script:CapBitmap.Height
        if ($SrcAspect -gt $TargetAspect) {
            $CW = [int]($script:CapBitmap.Height * $TargetAspect)
            $SrcRect = New-Object System.Drawing.Rectangle ([int](($script:CapBitmap.Width - $CW) / 2)), 0, $CW, $script:CapBitmap.Height
        } else {
            $CH = [int]($script:CapBitmap.Width / $TargetAspect)
            $SrcRect = New-Object System.Drawing.Rectangle 0, ([int](($script:CapBitmap.Height - $CH) / 2)), $script:CapBitmap.Width, $CH
        }
        $G.DrawImage($script:CapBitmap, (New-Object System.Drawing.Rectangle 0, 0, 280, 192), $SrcRect, [System.Drawing.GraphicsUnit]::Pixel)
    } finally {
        $G.Dispose()
    }
    $Bits = [A2MC]::DitherMono($PhotoBmp)   # 1-bit FS dither: it's a still
    $PhotoBmp.Dispose()
    return $Bits
}

function Send-Photo {
    param([int[]]$Reg)
    Send-Tones @(@(1200, 18), @(0, 50), @(1200, 18))   # camera shutter
    Write-Host "photo: capturing..."
    $Bits = Get-PhotoIndices $Reg
    $Hgr = [A2MC]::PackHgr($Bits)
    $Comp = [A2MC]::RleEncode($Hgr)
    Write-Host ("photo: sending {0} compressed bytes (8192 raw)..." -f $Comp.Length)
    $Header = [byte[]](0xA2, 0x4D, 0x43, 0x05, ($Comp.Length -band 0xFF), (($Comp.Length -shr 8) -band 0xFF))
    $Serial.Write($Header, 0, 6)
    # Pace by decoder debt: run tokens expand to many stored bytes at
    # ~30us each while the wire keeps delivering, and the 6551 only
    # buffers two bytes - so flush and sleep whenever the decoder
    # falls more than ~100us behind the line.
    $ByteUs = 10000000.0 / $Baud
    $Pos = 0
    $ChunkStart = 0
    $DebtUs = 0.0
    while ($Pos -lt $Comp.Length) {
        $T = $Comp[$Pos]
        if ($T -lt 0x80) { $OutB = $T; $WireB = 2 }
        else { $OutB = $T - 0x7F; $WireB = 1 + ($T - 0x7F) }
        $Pos += $WireB
        $DebtUs += ($OutB * 30.0) + 20.0 - ($WireB * $ByteUs)
        if ($DebtUs -lt 0) { $DebtUs = 0 }
        if ($DebtUs -gt 100 -or ($Pos - $ChunkStart) -ge 192 -or $Pos -ge $Comp.Length) {
            $Serial.Write($Comp, $ChunkStart, $Pos - $ChunkStart)
            $ChunkStart = $Pos
            if ($DebtUs -gt 0) {
                Start-Sleep -Milliseconds ([int][math]::Ceiling($DebtUs / 1000.0) + 1)
                $DebtUs = 0
            }
        }
    }
    Write-Host "photo: on screen. Any key on the Apple II resumes live video."
    while ($Serial.BytesToRead -eq 0) {
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { return }
        Start-Sleep -Milliseconds 100
    }
    $null = $Serial.ReadExisting()      # swallow the resume keypress
    $script:SinceKey = 999              # photo clobbered the delta base
    Write-Host "photo: resuming live stream."
}

if (-not $DryRun -and -not $PhotoTest -and -not $Port) {
    throw "Port is required unless -DryRun or -PhotoTest is used."
}

if ($Fps -lt 0) {
    throw "Fps cannot be negative."
}

$script:Hwnd = [IntPtr]::Zero
$CaptureRegion = $null
if (-not $Demo -and -not $Image) {
    if ($Region) {
        $CaptureRegion = Get-RegionFromString $Region
    } elseif ($WindowTitle) {
        $script:Hwnd = Resolve-WindowHandle $WindowTitle
        $CaptureRegion = [A2MC]::GetClientRegion($script:Hwnd)
    } else {
        $Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $CaptureRegion = [int[]]($Bounds.Left, $Bounds.Top, $Bounds.Width, $Bounds.Height)
    }
}

$script:PrevPage = $null
$script:SinceKey = 0

if ($PhotoTest) {
    $Bits = Get-PhotoIndices $CaptureRegion
    $Hgr = [A2MC]::PackHgr($Bits)
    $Back = [A2MC]::UnpackHgr($Hgr)
    $RoundtripOk = [System.Linq.Enumerable]::SequenceEqual([byte[]]$Back, [byte[]]$Bits)
    $Comp = [A2MC]::RleEncode($Hgr)
    Write-Host ("photo test: roundtrip {0}, packed 8192, compressed {1} bytes (~{2:N1}s on the wire)" -f $RoundtripOk, $Comp.Length, ($Comp.Length * 10.0 / 115200))
    $Bmp = New-Object System.Drawing.Bitmap 280, 192
    $Big = New-Object System.Drawing.Bitmap 560, 384
    $G = [System.Drawing.Graphics]::FromImage($Big)
    $I = 0
    for ($Y = 0; $Y -lt 192; $Y++) {
        for ($X = 0; $X -lt 280; $X++) {
            $V = if ($Back[$I] -ne 0) { 255 } else { 0 }
            $Bmp.SetPixel($X, $Y, [System.Drawing.Color]::FromArgb($V, $V, $V))
            $I++
        }
    }
    $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $G.DrawImage($Bmp, 0, 0, 560, 384)
    $Dir = Split-Path -Parent $PhotoTest
    if ($Dir) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    $Big.Save($PhotoTest, [System.Drawing.Imaging.ImageFormat]::Png)
    $G.Dispose(); $Bmp.Dispose(); $Big.Dispose()
    Write-Host "photo test preview: $PhotoTest"
    if (-not $RoundtripOk) { throw "DHGR pack/unpack roundtrip failed!" }
    exit 0
}

if ($DryRun) {
    $Page = Get-NextPage 0 $CaptureRegion
    if ($Mode -eq "DlgrC") {
        # Round-trip self-test of the compression against this frame
        # plus edge cases, using the reference decoder that mirrors
        # the 6502 logic.
        $Key = [A2MC]::RleEncode($Page)
        $Back = [A2MC]::RleDecode($Key, $null)
        $KeyOk = [System.Linq.Enumerable]::SequenceEqual([byte[]]$Back, [byte[]]$Page)
        $Shifted = New-Object byte[] 2048
        [array]::Copy($Page, 1, $Shifted, 0, 2047); $Shifted[2047] = $Page[0]
        $Delta = [A2MC]::RleEncode([A2MC]::XorBytes($Page, $Shifted))
        $Back2 = [A2MC]::RleDecode($Delta, $Shifted)
        $DeltaOk = [System.Linq.Enumerable]::SequenceEqual([byte[]]$Back2, [byte[]]$Page)
        $Flat = New-Object byte[] 2048   # extreme run case
        $FlatOk = [System.Linq.Enumerable]::SequenceEqual([byte[]]([A2MC]::RleDecode([A2MC]::RleEncode($Flat), $null)), [byte[]]$Flat)
        $Noise = New-Object byte[] 2048  # extreme literal case
        $Rng = New-Object System.Random 42
        $Rng.NextBytes($Noise)
        $NoiseComp = [A2MC]::RleEncode($Noise)
        $NoiseOk = [System.Linq.Enumerable]::SequenceEqual([byte[]]([A2MC]::RleDecode($NoiseComp, $null)), [byte[]]$Noise)
        Write-Host ("RLE self-test: key {0} ({1}B), delta {2} ({3}B), flat {4}, noise {5} ({6}B)" -f $KeyOk, $Key.Length, $DeltaOk, $Delta.Length, $FlatOk, $NoiseOk, $NoiseComp.Length)
        if (-not ($KeyOk -and $DeltaOk -and $FlatOk -and $NoiseOk)) { throw "RLE round-trip failed!" }
    }
    $Packet = (New-FramePacket $Page)[0]
    if ($OutFrame) {
        $Directory = Split-Path -Parent $OutFrame
        if ($Directory) {
            New-Item -ItemType Directory -Force -Path $Directory | Out-Null
        }
        [System.IO.File]::WriteAllBytes($OutFrame, $Packet)
        Write-Host "Wrote packet: $OutFrame ($($Packet.Length) bytes, mode $($Packet[3]))"
    }
    if ($Preview) {
        if ($Mode -eq "Dlgr") {
            Write-Host "Preview PNG is only supported in Lores mode; skipped."
        } else {
            Save-Preview (Convert-PageToIndices $Page) $Preview
            Write-Host "Wrote preview: $Preview"
        }
    }
    Write-Host ("Page checksum: `$" + ([A2MC]::Checksum($Page).ToString("X2")))
    exit 0
}

if ($StopFile -and (Test-Path -LiteralPath $StopFile)) {
    Write-Host 'Stopped before opening the serial port.'
    exit 0
}
$Serial = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$Serial.Handshake = [System.IO.Ports.Handshake]::None
$Serial.DtrEnable = $true   # the SSC's 6551 disables its receiver unless
$Serial.RtsEnable = $true   # DCD (wired from PC DTR/RTS via null modem) is low
$Serial.WriteTimeout = 5000
$Serial.Open()

$PacketLength = 4 + $PayloadSize + 1
$ByteBudget = ($Baud / 10.0) / $PacketLength
Write-Host ("Streaming {0} to {1} at {2} baud (raw packet limit ~{3:N1} fps); target {4} fps. Ctrl+C stops." -f $Mode, $Port, $Baud, $ByteBudget, $Fps)

try {
    Start-Sleep -Milliseconds ([int]($OpenDelay * 1000))
    Send-Tones @(@(523, 70), @(659, 70), @(784, 120))   # connected jingle
    $FrameInterval = if ($Fps -gt 0) { 1.0 / $Fps } else { 0.0 }
    $Started = [System.Diagnostics.Stopwatch]::StartNew()
    $StatsWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $StatsBase = 0
    $Sent = 0
    $StatBytes = 0
    $StatModes = @{ 1 = 0; 2 = 0; 3 = 0; 4 = 0 }
    while ($true) {
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
        if ($Frames -gt 0 -and $Sent -ge $Frames) {
            break
        }
        if ($Duration -gt 0 -and $Started.Elapsed.TotalSeconds -ge $Duration) {
            break
        }

        $FrameWatch = [System.Diagnostics.Stopwatch]::StartNew()

        if ($WindowTitle -and -not $Demo -and -not $Image) {
            try {
                $CaptureRegion = [A2MC]::GetClientRegion($script:Hwnd)
            } catch {
                $script:Hwnd = Resolve-WindowHandle $WindowTitle
                $CaptureRegion = [A2MC]::GetClientRegion($script:Hwnd)
            }
            if ($CaptureRegion[2] -le 0 -or $CaptureRegion[3] -le 0) {
                Start-Sleep -Milliseconds 250   # minimized; wait for it to come back
                continue
            }
        }

        $Page = Get-NextPage $Sent $CaptureRegion
        $Built = New-FramePacket $Page
        $Packet = $Built[0]
        $FrameType = $Built[1]
        $GapMs = $Built[2]
        $Serial.Write($Packet, 0, $Packet.Length)
        $Sent++
        $StatBytes += $Packet.Length
        $StatModes[[int]$FrameType]++

        if ($StatsEvery -gt 0 -and ($Sent % $StatsEvery) -eq 0) {
            $Secs = $StatsWatch.Elapsed.TotalSeconds
            if ($Secs -gt 0) {
                Write-Host ("frame {0,6}  {1,5:N1} fps  avg {2,5:N0} B/frame  K{3}/D{4}/R{5}" -f $Sent, (($Sent - $StatsBase) / $Secs), ($StatBytes / $StatsEvery), $StatModes[3], $StatModes[4], ($StatModes[1] + $StatModes[2]))
            }
            $StatsWatch.Restart()
            $StatsBase = $Sent
            $StatBytes = 0
            $StatModes = @{ 1 = 0; 2 = 0; 3 = 0; 4 = 0 }
        }

        # Sleep until the wire has drained AND the receiver has had its
        # decode/copy window, or until the fps pacing point - whichever
        # is later. SerialPort.Write returns when the driver buffers the
        # bytes, not when they leave the wire, so the drain time counts
        # from the write start. The wait is chunked so Apple II
        # keystrokes coming back up the line are handled promptly.
        $DrainS = $Packet.Length * 10.0 / $Baud
        $TargetS = [math]::Max($DrainS + ($GapMs / 1000.0), $FrameInterval)
        while ($true) {
            if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
            Process-SerialInput
            $script:LogTick++
            if (($script:LogTick % 10) -eq 0) { Test-GameLog }
            $RemainS = $TargetS - $FrameWatch.Elapsed.TotalSeconds
            if ($RemainS -le 0) { break }
            Start-Sleep -Milliseconds ([int][math]::Min(20, [math]::Ceiling($RemainS * 1000)))
        }
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
        if ($script:PhotoWanted) {
            $script:PhotoWanted = $false
            Send-Photo $CaptureRegion
        }
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
        if ($script:PendingTones.Count -gt 0) {
            Send-Tones ([object[]]$script:PendingTones.Dequeue())
        }
    }
} finally {
    foreach ($Vk in @($script:HeldVk.Keys)) { [A2In]::Key([uint16]$Vk, $false) }
    foreach ($Button in @($script:HeldBtn.Keys)) { [A2In]::Button([int]$Button, $false) }
    if ($Serial.IsOpen) {
        $Serial.Close()
    }
    $Serial.Dispose()
    if ($script:ImageBitmap) { $script:ImageBitmap.Dispose() }
    Write-Host "Sent $Sent frame(s)."
}
