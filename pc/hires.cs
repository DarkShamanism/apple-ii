// Hi-res quantization/packing adapted from vnIIc by Joshua Bell (MIT).
// See third_party/vnIIc/LICENSE and NOTICE.md. Native capture and lifecycle are A2MC additions.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public sealed class HiresFrame : IDisposable {
    public byte[] Bytes;
    public Bitmap Preview;
    public void Dispose() { if (Preview != null) Preview.Dispose(); }
}
public static class Hires {
    static readonly int[,] Colors = {{0,0,0},{47,188,26},{208,67,229},{255,255,255},
                                     {0,0,0},{208,106,26},{47,149,229},{255,255,255}};
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr handle, out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr handle, ref Point point);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr handle);
    public static int Offset(int y) { return ((y & 7) << 10) + (((y >> 3) & 7) << 7) + ((y >> 6) * 40); }
    public static int CapturedPid;   // the process whose window was last captured, 0 for any other source
    public static Bitmap Capture(string source, string title, string image) {
        CapturedPid = 0;
        if (source == "Image") { using (var original = new Bitmap(image)) return new Bitmap(original); }
        if (source == "Demo") {
            var b = new Bitmap(560,384);
            using (var g = Graphics.FromImage(b)) {
                for (int x=0; x<8; x++) using (var brush = new SolidBrush(Color.FromArgb(Colors[x,0],Colors[x,1],Colors[x,2]))) g.FillRectangle(brush,x*70,0,70,384);
                using (var font = new Font("Georgia",36)) g.DrawString("The Far Glade",font,Brushes.White,30,145);
            }
            return b;
        }
        Rectangle area;
        if (source == "Desktop") area = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        else if (source == "Window") {
            Process match = null;
            foreach (var p in Process.GetProcesses()) {
                if (p.MainWindowHandle != IntPtr.Zero && p.MainWindowTitle.IndexOf(title,StringComparison.OrdinalIgnoreCase)>=0) {
                    if (match != null) { match.Dispose(); p.Dispose(); throw new Exception("Multiple windows match. Use a more specific title."); }
                    match=p;
                } else p.Dispose();
            }
            if (match == null) throw new Exception("No window matches: " + title);
            using (match) {
                CapturedPid = match.Id;
                if (IsIconic(match.MainWindowHandle)) throw new Exception("Restore the minimized capture window.");
                Rect r; var origin = new Point();
                if (!GetClientRect(match.MainWindowHandle,out r) || !ClientToScreen(match.MainWindowHandle,ref origin)) throw new Exception("Capture window disappeared.");
                area=new Rectangle(origin.X,origin.Y,r.Right-r.Left,r.Bottom-r.Top);
            }
        } else throw new ArgumentException("Unknown capture source.");
        if (area.Width<=0 || area.Height<=0) throw new Exception("Capture area is empty.");
        var result=new Bitmap(area.Width,area.Height);
        try { using(var g=Graphics.FromImage(result)) g.CopyFromScreen(area.Location,System.Drawing.Point.Empty,area.Size); return result; }
        catch { result.Dispose(); throw; }
    }
    public static HiresFrame Convert(Bitmap source, double dither, string fit) {
        if (dither<0 || dither>1 || Double.IsNaN(dither)) throw new ArgumentOutOfRangeException("dither");
        var indexes=new byte[140*192];
        var pixels=new float[140*192*3];
        using (var small=new Bitmap(140,192)) {
            using (var g=Graphics.FromImage(small)) {
                g.Clear(Color.Black); g.InterpolationMode=InterpolationMode.HighQualityBicubic;
                // Physical display is 280x192; each sampled color pixel spans two dots.
                float scale=fit=="Crop" ? Math.Max(280f/source.Width,192f/source.Height) : Math.Min(280f/source.Width,192f/source.Height);
                if(fit=="Stretch") g.DrawImage(source,new Rectangle(0,0,140,192));
                else if(fit=="Crop" || fit=="Letterbox") { float w=source.Width*scale/2f,h=source.Height*scale; g.DrawImage(source,(140-w)/2,(192-h)/2,w,h); }
                else throw new ArgumentException("Invalid fit.");
            }
            for(int y=0;y<192;y++) for(int x=0;x<140;x++) { var c=small.GetPixel(x,y); int i=(y*140+x)*3; pixels[i]=c.R; pixels[i+1]=c.G; pixels[i+2]=c.B; }
        }
        for(int y=0;y<192;y++) for(int x=0;x<140;x++) {
            int i=(y*140+x)*3, best=0; double min=Double.MaxValue;
            for(int c=0;c<8;c++) { double dist=0; for(int k=0;k<3;k++) { double e=pixels[i+k]-Colors[c,k]; dist+=e*e; } if(dist<min) {min=dist;best=c;} }
            indexes[y*140+x]=(byte)best;
            for(int k=0;k<3;k++) {
                float e=(float)((pixels[i+k]-Colors[best,k])*dither);
                Spread(pixels,x+1,y,k,e*7/16); Spread(pixels,x-1,y+1,k,e*3/16); Spread(pixels,x,y+1,k,e*5/16); Spread(pixels,x+1,y+1,k,e/16);
            }
        }
        byte[] bytes=Pack(indexes);
        return new HiresFrame {Bytes=bytes,Preview=Decode(bytes)};
    }
    static void Spread(float[] a,int x,int y,int k,float e) { if(x>=0 && x<140 && y<192) { int i=(y*140+x)*3+k; a[i]=Math.Max(0,Math.Min(255,a[i]+e)); } }
    public static byte[] Pack(byte[] indexes) {
        if(indexes.Length!=140*192) throw new ArgumentException("Expected 140x192 indexes.");
        var bytes=new byte[8192];
        int[] bits={0,2,1,3,0,2,1,3};
        for(int y=0;y<192;y++) {
            int address=Offset(y), input=y*140;
            for(int pair=0;pair<20;pair++) {
                int accum=0,shift=0,pal1=0,pal2=0;
                for(int pixel=0;pixel<7;pixel++) {
                    int c=indexes[input++]; if(c>7) throw new ArgumentException("Invalid palette index.");
                    if(c==1 || c==2) pal1++; if(c==5 || c==6) pal2++;
                    accum|=bits[c]<<shift; shift+=2;
                    if(pixel==3 || pixel==6) { bytes[address++]=(byte)((accum&127)|(pal2>pal1?128:0)); accum>>=7; shift=1; pal1=pal2=0; }
                }
            }
        }
        return bytes;
    }
    public static Bitmap Decode(byte[] bytes) {
        if(bytes.Length!=8192) throw new ArgumentException("Expected 8192-byte HGR frame.");
        var bmp=new Bitmap(280,192);
        for(int y=0;y<192;y++) for(int x=0;x<140;x++) {
            int bit=x*2, a=Offset(y)+bit/7, b=Offset(y)+(bit+1)/7;
            int lo=(bytes[a]>>(bit%7))&1,hi=(bytes[b]>>((bit+1)%7))&1;
            int phase=((lo!=0?bytes[a]:bytes[b])&128)!=0?4:0;
            int color=lo+hi*2; // 01 violet, 10 green
            int palette=color==1?2:color==2?1:color;
            var c=Color.FromArgb(Colors[palette+phase,0],Colors[palette+phase,1],Colors[palette+phase,2]);
            bmp.SetPixel(x*2,y,c); bmp.SetPixel(x*2+1,y,c);
        }
        return bmp;
    }
    public static byte[] Packet(byte[] frame) {
        if(frame.Length!=8192) throw new ArgumentException("Invalid frame length.");
        var packet=new byte[8194]; packet[0]=1; Buffer.BlockCopy(frame,0,packet,1,8192);
        byte xor=0; foreach(byte b in frame) xor^=b; packet[8193]=xor; return packet;
    }
    // ---- A2HR version 2: packed pages. A2MC additions, not from vnIIc. ----
    // The eight bytes that end each 128 of a hi-res page are never displayed.
    public static bool Hole(int i) { return (i & 0x7F) >= 0x78; }
    // True when two pages show the same picture: equal wherever a byte is displayed.
    public static bool Shown(byte[] a, byte[] b) {
        if (a == null || b == null || a.Length != 8192 || b.Length != 8192) return false;
        for (int i = 0; i < 8192; i++) if (a[i] != b[i] && !Hole(i)) return false;
        return true;
    }
    // Tokens that turn a page holding `model` into one showing `target`. With no model (the page's
    // contents are not known) every byte is written. `applied` is what the page then holds.
    // Token: top two bits 00 literal, 01 skip, 10 run of one byte, 11 run of a pair; low six bits count - 1.
    public static byte[] Encode(byte[] target, byte[] model, out byte[] applied) {
        if (target == null || target.Length != 8192 || (model != null && model.Length != 8192)) throw new ArgumentException("Expected 8192-byte pages.");
        var t = (byte[])target.Clone();
        // Undisplayed bytes may hold anything: let them carry on the pattern before them, so runs pass through.
        for (int i = 2; i < 8192; i++) if (Hole(i)) t[i] = t[i - 2];
        applied = model != null ? (byte[])model.Clone() : new byte[8192];
        var output = new List<byte>(2048);
        int p = 0, literal = -1;        // literal: where the open literal's header is, or -1
        while (p < 8192) {
            int s = 0;
            if (model != null) {
                while (p + s < 8192 && (Hole(p + s) || t[p + s] == model[p + s])) s++;
                if (p + s == 8192) break;                       // the rest is already right
            }
            bool open = literal >= 0;
            if (s >= (open ? 3 : 1)) {
                while (s > 0) { int n = Math.Min(s, 64); output.Add((byte)(0x40 | (n - 1))); s -= n; p += n; }
                literal = -1; continue;
            }
            int r = 1; while (p + r < 8192 && t[p + r] == t[p]) r++;
            if (r >= (open ? 4 : 3)) {
                int n = Math.Min(r, 64);
                output.Add((byte)(0x80 | (n - 1))); output.Add(t[p]);
                for (int i = 0; i < n; i++) applied[p + i] = t[p + i];
                p += n; literal = -1; continue;
            }
            int q = 1; if (p + 1 < 8192) { q = 2; while (p + q < 8192 && t[p + q] == t[p + q - 2]) q++; }
            if (q / 2 >= (open ? 3 : 2)) {
                int n = Math.Min(q / 2, 64);
                output.Add((byte)(0xC0 | (n - 1))); output.Add(t[p]); output.Add(t[p + 1]);
                for (int i = 0; i < 2 * n; i++) applied[p + i] = t[p + i];
                p += 2 * n; literal = -1; continue;
            }
            if (!open || output[literal] == 63) { literal = output.Count; output.Add(0); } else output[literal]++;
            output.Add(t[p]); applied[p] = t[p]; p++;
        }
        if (output.Count == 0) output.Add(0x40);                // nothing differs: one token, so the page can still be shown
        return output.ToArray();
    }
    // What the receiver does with a payload, for checking one before it is sent. Throws when the
    // receiver would refuse it: a token past the end of the page or of the payload.
    public static byte[] Apply(byte[] payload, byte[] model) {
        if (payload == null || payload.Length == 0 || payload.Length > 8191) throw new InvalidDataException("A packed page is 1 to 8191 bytes.");
        var page = model != null ? (byte[])model.Clone() : new byte[8192];
        int s = 0, d = 0;
        while (s < payload.Length) {
            int kind = payload[s] & 0xC0, n = (payload[s] & 0x3F) + 1; s++;
            int bytes = kind == 0xC0 ? 2 * n : n, needs = kind == 0x00 ? n : kind == 0x40 ? 0 : kind == 0x80 ? 1 : 2;
            if (d + bytes > 8192) throw new InvalidDataException("A token writes past the page.");
            if (s + needs > payload.Length) throw new InvalidDataException("A token runs past the payload.");
            if (kind == 0x00) Buffer.BlockCopy(payload, s, page, d, n);
            else if (kind == 0x80) for (int i = 0; i < n; i++) page[d + i] = payload[s];
            else if (kind == 0xC0) for (int i = 0; i < bytes; i++) page[d + i] = payload[s + (i & 1)];
            s += needs; d += bytes;
        }
        return page;
    }
    // Command 2, the length, the payload, then two checks: the XOR of the bytes, and the running
    // total of that XOR after each byte, which notices bytes out of place as well as bytes changed.
    public static byte[] PackedPacket(byte[] payload) {
        if (payload == null || payload.Length == 0 || payload.Length > 8191) throw new ArgumentException("A packed page is 1 to 8191 bytes.");
        var packet = new byte[payload.Length + 5];
        packet[0] = 2; packet[1] = (byte)(payload.Length & 255); packet[2] = (byte)(payload.Length >> 8);
        Buffer.BlockCopy(payload, 0, packet, 3, payload.Length);
        byte xor = 0, sum = 0;
        foreach (byte b in payload) { xor ^= b; sum += xor; }
        packet[payload.Length + 3] = xor; packet[payload.Length + 4] = sum;
        return packet;
    }
    public static void Publish(HiresFrame frame,string directory) {
        Directory.CreateDirectory(directory);
        File.WriteAllBytes(Path.Combine(directory,"frame.bin.tmp"),frame.Bytes);
        Replace(Path.Combine(directory,"frame.bin.tmp"),Path.Combine(directory,"frame.bin"));
        frame.Preview.Save(Path.Combine(directory,"preview.tmp.png"),ImageFormat.Png);
        Replace(Path.Combine(directory,"preview.tmp.png"),Path.Combine(directory,"preview.png"));
    }
    static void Replace(string temp,string path) { if(File.Exists(path)) File.Replace(temp,path,null); else File.Move(temp,path); }
}

// The PC's side of an A2HR session: what the IIe says, what each of its two pages holds, and
// what to send next. It opens no port; pc/hires.ps1 moves the bytes.
public sealed class HiresLink {
    public const int Request = 256;
    public byte[][] Pages = new byte[2][];  // what each page is known to hold; null when that cannot be known
    public int KeyEvery = 60;               // send a page whole instead of its changes every so many; 0 never
    public bool RawOnly;                    // raw pages only, as version 1 sent them
    public int Marker = -1;                 // the status byte before the request just read; -1 from a version 1 receiver
    public bool Version2;                   // the receiver last heard from sends a status byte
    public int Target;                      // the page the next one goes to: 0 at $2000, 1 at $4000
    public string Kind = "";                // raw, whole or changes: what Compose last made
    public string Note = "";                // what Report learned, when it is worth a line in the journal
    public int Accepted, Refused, Spoiled;
    int state, seen = -1, pending = -1;
    bool pendingPacked;
    byte[] pendingPage;
    readonly int[] since = new int[2];

    // One byte from the IIe. Returns Request when a request is complete, a key's ASCII value
    // (0-127) when a key was pressed, and -1 otherwise.
    public int Feed(int b) {
        if (state == 0) {
            if (b == 0x90) { state = 1; return -1; }
            if (b >= 0xA0 && b <= 0xA7) { seen = b; return -1; }
            if (b >= 0 && b < 0x80) return b;
            seen = -1; return -1;
        }
        if (b != 1) { state = 0; seen = -1; return -1; }
        if (state == 1) { state = 2; return -1; }
        state = 0; Marker = seen; seen = -1;
        return Request;
    }
    // Take in a request's status byte: what became of the page sent before, and which page is next.
    public void Report(int marker) {
        Note = "";
        Version2 = marker >= 0xA0 && marker <= 0xA7;
        if (!Version2) { Pages[0] = Pages[1] = null; pending = -1; Target = 0; return; }
        int status = marker & 3;
        Target = (marker >> 2) & 1;
        if (status == 0 || pending < 0) {
            Pages[0] = Pages[1] = null;                         // it has only just begun, or speaks of a page this session did not send
        } else if (status == 1) {
            if (Target != pending) { Pages[pending] = pendingPage; Accepted++; }
            else { Pages[0] = Pages[1] = null; Note = "Out of step with the receiver; sending whole pages."; }
        } else {
            if (status == 2) Refused++; else Spoiled++;
            if (Target != pending) { Pages[0] = Pages[1] = null; Note = "Out of step with the receiver; sending whole pages."; }
            else if (status == 3 || !pendingPacked) { Pages[Target] = null; Note = "The receiver lost a page on the way; sending that page whole."; }
            else Note = "The receiver refused a damaged page; its screen is unchanged and the page is sent again.";
        }
        pending = -1;
    }
    // The packet that makes the IIe show `frame`, or null when it already shows it.
    public byte[] Compose(byte[] frame) {
        if (frame == null || frame.Length != 8192) throw new ArgumentException("Invalid frame length.");
        if (!Version2) { Kind = "raw"; return Hires.Packet(frame); }
        if (Hires.Shown(Pages[1 - Target], frame)) return null;
        byte[] model = Pages[Target], packet = null, applied = null;
        if (model != null && KeyEvery > 0 && since[Target] >= KeyEvery) model = null;
        if (!RawOnly) {
            byte[] payload = Hires.Encode(frame, model, out applied);
            // Send it packed only if it is smaller than the raw page and this PC's own copy of the receiver's work agrees.
            if (payload.Length < 8192) {
                applied = Hires.Apply(payload, model);
                if (Hires.Shown(applied, frame)) packet = Hires.PackedPacket(payload);
            }
        }
        pendingPacked = packet != null;
        if (packet == null) { packet = Hires.Packet(frame); applied = (byte[])frame.Clone(); model = null; }
        Kind = !pendingPacked ? "raw" : model == null ? "whole" : "changes";
        since[Target] = model == null ? 0 : since[Target] + 1;
        pending = Target; pendingPage = applied;
        return packet;
    }
}

// Keys from the IIe, turned into the same Minecraft controls the A2MC streamer uses. Plan says what
// a key does; the rest injects it with SendInput. Nothing here decides whether to: pc/hires.ps1
// injects only while the captured window is the foreground window.
public static class HiresInput {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }

    // What a key from the IIe does: "look dx dy", "hold-key vk", "hold-button n", "tap vk" or "" for nothing.
    public static string Plan(int code, int lookStep) {
        code &= 0x7F;
        if (code >= 'a' && code <= 'z') code -= 32;
        int tilt = (int)(lookStep * 0.75);
        switch (code) {
            case 8: return "look " + (-lookStep) + " 0";        // left arrow
            case 21: return "look " + lookStep + " 0";          // right arrow
            case 11: return "look 0 " + (-tilt);                // up arrow
            case 10: return "look 0 " + tilt;                   // down arrow
            case 13: return "hold-button 0";                    // Return: mine / attack
            case 46: return "hold-button 1";                    // . : place / use
            case 32: return "hold-key 32";                      // space: jump
            case 87: case 65: case 83: case 68: return "hold-key " + code;      // W A S D
        }
        if ((code >= 65 && code <= 90) || (code >= 48 && code <= 57)) return "tap " + code;     // E, Q, 1-9 and the rest
        return "";
    }
    public static bool PidIsForeground(int pid) {
        uint p;
        GetWindowThreadProcessId(GetForegroundWindow(), out p);
        return pid != 0 && p == (uint)pid;
    }
    public static void Key(ushort vk, bool down) {
        INPUT i = new INPUT();
        i.type = 1;
        i.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
        i.u.ki.dwFlags = (uint)(0x0008 | (down ? 0 : 0x0002));  // scan code (+ key up)
        SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Look(int dx, int dy) {
        INPUT i = new INPUT();
        i.type = 0;
        i.u.mi.dx = dx; i.u.mi.dy = dy;
        i.u.mi.dwFlags = 0x0001;                                // relative move
        SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Button(int button, bool down) {
        INPUT i = new INPUT();
        i.type = 0;
        i.u.mi.dwFlags = (uint)(button == 0 ? (down ? 0x0002 : 0x0004) : (down ? 0x0008 : 0x0010));
        SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }
}
