param([switch]$Stop, [switch]$Background, [switch]$Logs, [switch]$Status)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ListFile = Join-Path $Root 'lists\list-proxy.txt'
$LogFile = Join-Path $PSScriptRoot 'ws-proxy.log'
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Fail([string]$msg) {
    Write-Host "ws-proxy: $msg" -ForegroundColor Red
    if ($logReady) { [WsProxy]::Log("ERR  $msg") }
    else { try { "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $msg" | Out-File $LogFile -Append -Encoding UTF8 } catch { } }
    if (-not ($Background -or $Stop)) { Read-Host 'Press Enter to close' }
    exit 1
}
trap { Fail "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }

function Test-NamedMutex([string]$name) {
    $m = $null
    try { if (-not [System.Threading.Mutex]::TryOpenExisting($name, [ref]$m)) { return $false }; $m.Dispose() } catch [System.UnauthorizedAccessException] { }
    return $true
}

if ($Status) {
    try { $on = Test-NamedMutex 'Local\zapret-ws-proxy' } catch { Write-Host 'Cannot check WS proxy status.'; exit 2 }
    if ($on) { Write-Host 'WS proxy is RUNNING.'; exit 0 } else { Write-Host 'WS proxy is NOT running.'; exit 1 }
}

if ($Logs) {
    $host.UI.RawUI.WindowTitle = 'zapret: ws-proxy log'
    # while this mutex exists, the proxy logs every connection
    $debug = New-Object System.Threading.Mutex($false, 'Local\zapret-ws-proxy-debug')
    Write-Host "Closing this window does not stop the proxy.`nPRX = proxy, DIR = direct.`n"
    $buf = New-Object byte[] 65536; $gen = $null; $pos = 0L; $was = $null
    while ($true) {
        $on = Test-NamedMutex 'Local\zapret-ws-proxy'
        if ($on -ne $was) { $was = $on; if ($on) { Write-Host 'WS proxy is running.' -ForegroundColor Green } else { Write-Host 'WS proxy is not running.' -ForegroundColor Yellow } }
        try {
            $f = [System.IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
            try {
                # new creation time = proxy restarted, shorter file = log rotated: read from the beginning
                $ct = [System.IO.File]::GetCreationTimeUtc($LogFile)
                if ($ct -ne $gen -or $pos -gt $f.Length) { $gen = $ct; $pos = 0L }
                [void]$f.Seek($pos, 'Begin')
                $n = $f.Read($buf, 0, $buf.Length)
                $e = if ($n -gt 0) { [Array]::LastIndexOf($buf, [byte]10, $n - 1) } else { -1 }
                if ($e -ge 0) {
                    foreach ($l in [System.Text.Encoding]::UTF8.GetString($buf, 0, $e).Split([char]10)) {
                        $l = $l.TrimEnd([char]13)
                        if ($l -cmatch ' (ERR|FAIL) ') { Write-Host $l -ForegroundColor Red }
                        elseif ($l -cmatch ' WARN ') { Write-Host $l -ForegroundColor Yellow }
                        else { Write-Host $l }
                    }
                    $pos += $e + 1
                }
            }
            finally { $f.Dispose() }
        }
        catch { }
        Start-Sleep -Milliseconds 250
    }
}

$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class ServerAnswer : Exception
{
    public int Code;
    public ServerAnswer(string msg, int code = 0) : base(msg) { Code = code; }
}

public class Ws
{
    Stream st;
    TcpClient tcp;
    public string Server;
    public volatile int RxSeq;
    byte[] pre = new byte[0];
    int preOff;
    byte[] sendBuf = new byte[65550];
    byte[] sendMask = new byte[4];
    SemaphoreSlim wl = new SemaphoreSlim(1, 1);
    static Random rnd = new Random();
    static volatile SslProtocols tlsProto = SslProtocols.None;

    public static async Task<Ws> Connect(Uri u, string ip, CancellationToken ct = default(CancellationToken))
    {
        Ws w = new Ws();
        IPAddress[] addrs = ip != "" ? new[] { IPAddress.Parse(ip) } : await WsProxy.Timeout(Dns.GetHostAddressesAsync(u.Host), 8000, "DNS " + u.Host, ct);
        Array.Sort(addrs, (a, b) => a.AddressFamily.CompareTo(b.AddressFamily));
        string errs = "";
        foreach (IPAddress a in addrs)
        {
            ct.ThrowIfCancellationRequested();
            TcpClient c = new TcpClient(a.AddressFamily);
            try { await WsProxy.Timeout(c.ConnectAsync(a, u.Port), 7000, "TCP", ct); w.tcp = c; break; }
            catch (OperationCanceledException) { c.Close(); throw; }
            catch (Exception e) { errs += " " + a + ": " + e.GetBaseException().Message + ";"; c.Close(); }
        }
        if (w.tcp == null) throw new Exception("TCP connect failed:" + errs);
        try
        {
            w.tcp.NoDelay = true;
            WsProxy.KeepAlive(w.tcp);
            w.st = w.tcp.GetStream();
            if (u.Scheme == "wss")
            {
                SslStream ssl = new SslStream(w.st);
                bool retry = false;
                try { await WsProxy.Timeout(ssl.AuthenticateAsClientAsync(u.Host, null, tlsProto, false), 10000, "TLS " + u.Host, ct); }
                catch (ArgumentException) { tlsProto = SslProtocols.Tls12; retry = true; }
                if (retry)
                {
                    ssl = new SslStream(w.st);
                    await WsProxy.Timeout(ssl.AuthenticateAsClientAsync(u.Host, null, tlsProto, false), 10000, "TLS " + u.Host, ct);
                }
                w.st = ssl;
            }
            byte[] key = new byte[16];
            lock (rnd) rnd.NextBytes(key);
            await WsProxy.Write(w.st, "GET " + u.PathAndQuery + " HTTP/1.1\r\nHost: " + (u.IsDefaultPort ? u.Host : u.Host + ":" + u.Port) +
                "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " +
                Convert.ToBase64String(key) + "\r\nSec-WebSocket-Version: 13\r\n\r\n");
            byte[] hb = new byte[16384];
            int hl = await WsProxy.Timeout(WsProxy.ReadHeader(w.st, hb), 15000, "Server response", ct);
            int he = WsProxy.HeaderEnd(hb, hl);
            string status = Encoding.ASCII.GetString(hb, 0, he).Split('\r')[0];
            if (!status.Contains(" 101"))
            {
                string[] sp = status.Split(' ');
                int code = 0;
                if (sp.Length > 1) int.TryParse(sp[1], out code);
                throw new ServerAnswer("Server answered '" + status + "' " + Encoding.UTF8.GetString(hb, he, Math.Min(hl - he, 120)).Trim(), code);
            }
            w.pre = new byte[hl - he];
            Buffer.BlockCopy(hb, he, w.pre, 0, w.pre.Length);
            return w;
        }
        catch { w.Close(); throw; }
    }

    async Task Read(byte[] b, int len)
    {
        int off = 0;
        while (off < len)
        {
            int n;
            if (preOff < pre.Length)
            {
                n = Math.Min(len - off, pre.Length - preOff);
                Buffer.BlockCopy(pre, preOff, b, off, n);
                preOff += n;
            }
            else
            {
                n = await st.ReadAsync(b, off, len - off);
                if (n <= 0) throw new EndOfStreamException();
            }
            off += n;
        }
    }

    public async Task Send(byte[] data, int len, int op = 2)
    {
        int h = len < 126 ? 2 : len < 65536 ? 4 : 10;
        int total = h + 4 + len;
        await wl.WaitAsync();
        try
        {
            if (sendBuf.Length < total) sendBuf = new byte[total];
            byte[] f = sendBuf;
            f[0] = (byte)(0x80 | op);
            if (h == 2) f[1] = (byte)(0x80 | len);
            else if (h == 4) { f[1] = 0x80 | 126; f[2] = (byte)(len >> 8); f[3] = (byte)len; }
            else { f[1] = 0x80 | 127; Array.Clear(f, 2, 4); for (int i = 0; i < 4; i++) f[6 + i] = (byte)(len >> (24 - 8 * i)); }
            lock (rnd) rnd.NextBytes(sendMask);
            Buffer.BlockCopy(sendMask, 0, f, h, 4);
            for (int i = 0; i < len; i++) f[h + 4 + i] = (byte)(data[i] ^ sendMask[i & 3]);
            await st.WriteAsync(f, 0, total);
        }
        finally { wl.Release(); }
    }

    public async Task ReceiveTo(Stream to, int stopAfter = 0)
    {
        byte[] h = new byte[8], m = new byte[4], buf = new byte[65536];
        while (true)
        {
            await Read(h, 2);
            int op = h[0] & 15;
            bool masked = (h[1] & 128) != 0;
            long len = h[1] & 127;
            if (len == 126) { await Read(h, 2); len = (h[0] << 8) | h[1]; }
            else if (len == 127) { await Read(h, 8); len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | h[i]; }
            if (len < 0 || len > 16 << 20) throw new Exception("WS frame too big");
            if (masked) await Read(m, 4);
            if (len > buf.Length) buf = new byte[len];
            int n = (int)len;
            await Read(buf, n);
            if (masked) for (int i = 0; i < n; i++) buf[i] ^= m[i & 3];
            if (op == 8) return;
            if (op == 9) await Send(buf, n, 10);
            else if (op != 10 && n > 0)
            {
                RxSeq++;
                await to.WriteAsync(buf, 0, n);
                if (stopAfter > 0 && to.Length >= stopAfter) return;
            }
        }
    }

    public void Close()
    {
        try { if (st != null) st.Dispose(); } catch { }
        try { if (tcp != null) tcp.Close(); } catch { }
    }
}

public static class WsProxy
{
    public static string Pac = "";
    public static string[] Names = new string[0], Urls = new string[0], Keys = new string[0], Ips = new string[0];
    public static int SwitchTimeout = 5000;
    public static int Port = 1080;
    public static bool Verbose;
    static HashSet<string> domains = new HashSet<string>(StringComparer.Ordinal);
    public static void SetDomains(string[] list) { domains = new HashSet<string>(list, StringComparer.Ordinal); }

    [DllImport("wininet.dll")]
    static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);
    public static void RefreshProxy()
    {
        try { InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0); } catch { }
    }

    static object logLock = new object();
    static List<string> held = null;
    static string logFile = null;
    public static void InitLog(string path, string first)
    {
        lock (logLock)
        {
            using (new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite)) { }
            try { File.SetCreationTimeUtc(path, DateTime.UtcNow); } catch { } // tells the log window that a new log has started
            logFile = path;
            WriteLog(first);
            Console.WriteLine(first);
        }
    }
    static void WriteLog(string l)
    {
        try
        {
            if (l.Length > 8192) l = l.Substring(0, 8192) + "...";
            byte[] b = Encoding.UTF8.GetBytes(l + "\r\n");
            using (FileStream f = new FileStream(logFile, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite))
            {
                if (f.Length + b.Length > 5 << 20) f.SetLength(0);
                f.Seek(0, SeekOrigin.End);
                f.Write(b, 0, b.Length);
            }
        }
        catch { } // logging must not break connections
    }
    static volatile int debugTick = unchecked(Environment.TickCount - 2000);
    static volatile bool debugCached;
    static bool DebugOpen()
    {
        int now = Environment.TickCount;
        if (unchecked((uint)(now - debugTick)) < 1000u) return debugCached;
        bool open = true;
        Mutex m;
        try { if (!Mutex.TryOpenExisting(@"Local\zapret-ws-proxy-debug", out m)) open = false; else m.Dispose(); } catch (UnauthorizedAccessException) { }
        debugCached = open;
        debugTick = now;
        return open;
    }
    public static void Hold() { lock (logLock) held = new List<string>(); }
    public static void Release()
    {
        lock (logLock) { foreach (string l in held) Console.WriteLine(l); held = null; }
    }
    public static void Log(string s)
    {
        string l = DateTime.Now.ToString("HH:mm:ss") + " " + s;
        lock (logLock) { if (logFile != null) WriteLog(l); if (held != null) held.Add(l); else Console.WriteLine(l); }
    }

    public static async Task<T> Timeout<T>(Task<T> t, int ms, string what, CancellationToken ct = default(CancellationToken))
    {
        using (CancellationTokenSource cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            if (await Task.WhenAny(t, Task.Delay(ms, cts.Token)) != t)
            {
                t.ContinueWith(x => { var e = x.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                if (ct.IsCancellationRequested) throw new OperationCanceledException();
                throw new TimeoutException(what + " timeout");
            }
            cts.Cancel();
            return await t;
        }
    }
    public static async Task Timeout(Task t, int ms, string what, CancellationToken ct = default(CancellationToken))
    {
        using (CancellationTokenSource cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            if (await Task.WhenAny(t, Task.Delay(ms, cts.Token)) != t)
            {
                t.ContinueWith(x => { var e = x.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                if (ct.IsCancellationRequested) throw new OperationCanceledException();
                throw new TimeoutException(what + " timeout");
            }
            cts.Cancel();
            await t;
        }
    }

    public static Task Write(Stream s, string text)
    {
        byte[] b = Encoding.ASCII.GetBytes(text);
        return s.WriteAsync(b, 0, b.Length);
    }

    public static int HeaderEnd(byte[] b, int len)
    {
        for (int i = 0; i + 3 < len; i++)
            if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i + 4;
        return -1;
    }

    public static async Task<int> ReadHeader(Stream s, byte[] b)
    {
        int len = 0;
        while (HeaderEnd(b, len) < 0)
        {
            if (len == b.Length) throw new Exception("header too big");
            int n = await s.ReadAsync(b, len, b.Length - len);
            if (n <= 0) throw new EndOfStreamException();
            len += n;
        }
        return len;
    }

    static Uri TunUri(int i, string host, int port)
    {
        return new Uri(Urls[i] + (Urls[i].Contains("?") ? "&" : "?") + "k=" + Uri.EscapeDataString(Keys[i]) +
            "&h=" + Uri.EscapeDataString(host) + "&p=" + port);
    }

    static void Drop(Task<Ws> t)
    {
        t.ContinueWith(x => { if (x.IsFaulted) { var e = x.Exception; } else if (!x.IsCanceled) x.Result.Close(); });
    }

    static DateTime[] downUntil = new DateTime[0];
    static async Task<Ws> Tunnel(string host, int port)
    {
        for (int i = 0; ; i++)
        {
            bool last = i == Urls.Length - 1;
            bool down = false;
            if (!last) lock (downUntil)
            {
                DateTime now = DateTime.Now;
                if (now < downUntil[i]) down = true;
                else if (downUntil[i] != DateTime.MinValue) downUntil[i] = now.AddMilliseconds(SwitchTimeout + 1000);
            }
            if (down) continue;
            if (last) { Ws w = await Ws.Connect(TunUri(i, host, port), Ips[i]); w.Server = Names[i]; return w; }
            using (CancellationTokenSource cts = new CancellationTokenSource())
            {
                Task<Ws> t = Ws.Connect(TunUri(i, host, port), Ips[i], cts.Token);
                try
                {
                    Ws w = await Timeout(t, SwitchTimeout, "connect");
                    w.Server = Names[i];
                    bool back = false;
                    lock (downUntil) { if (downUntil[i] != DateTime.MinValue) { downUntil[i] = DateTime.MinValue; back = true; } }
                    if (back) Log(Names[i] + " is back");
                    return w;
                }
                catch (Exception e)
                {
                    cts.Cancel();
                    Drop(t);
                    ServerAnswer sa = e as ServerAnswer;
                    if (sa != null && sa.Code != 401 && sa.Code != 403 && sa.Code != 429) continue;
                    bool show;
                    lock (downUntil) { show = DateTime.Now >= downUntil[i]; downUntil[i] = DateTime.Now.AddSeconds(60); }
                    if (show) Log(Names[i] + " didn't answer, trying " + Names[i + 1] + " (" + e.GetBaseException().Message + ")");
                }
            }
        }
    }

    static readonly byte[] kaVals = InitKa();
    static byte[] InitKa()
    {
        byte[] b = new byte[12];
        BitConverter.GetBytes((uint)1).CopyTo(b, 0);
        BitConverter.GetBytes((uint)45000).CopyTo(b, 4);
        BitConverter.GetBytes((uint)5000).CopyTo(b, 8);
        return b;
    }
    public static void KeepAlive(TcpClient c)
    {
        try { c.Client.IOControl(IOControlCode.KeepAliveValues, kaVals, null); } catch { }
    }

    public static string[] CheckAll()
    {
        Task<string>[] tasks = new Task<string>[Urls.Length];
        for (int i = 0; i < Urls.Length; i++)
        {
            int idx = i;
            tasks[i] = Task.Run(() => Check(idx));
        }
        Task.WaitAll(tasks);
        string[] res = new string[Urls.Length];
        for (int i = 0; i < Urls.Length; i++) res[i] = tasks[i].Result;
        return res;
    }

    public static string Check(int i)
    {
        DateTime t0 = DateTime.Now;
        Ws ws = null;
        using (CancellationTokenSource cts = new CancellationTokenSource())
        {
            try
            {
                Task<string> t = Task.Run(async () =>
                {
                    ws = await Ws.Connect(TunUri(i, "www.google.com", 80), Ips[i], cts.Token);
                    byte[] req = Encoding.ASCII.GetBytes("HEAD / HTTP/1.1\r\nHost: www.google.com\r\nConnection: close\r\n\r\n");
                    await ws.Send(req, req.Length);
                    MemoryStream ms = new MemoryStream();
                    await Timeout(ws.ReceiveTo(ms, 5), 15000, "answer", cts.Token);
                    if (ms.Length < 5) throw new Exception("server closed the connection");
                    string ans = Encoding.ASCII.GetString(ms.ToArray(), 0, 5);
                    if (ans != "HTTP/") throw new Exception("strange answer from server");
                    return "ok (" + (int)(DateTime.Now - t0).TotalMilliseconds + " ms)";
                });
                if (!t.Wait(20000)) { cts.Cancel(); t.ContinueWith(x => { var e = x.Exception; }, TaskContinuationOptions.OnlyOnFaulted); throw new TimeoutException("no answer in 20 s"); }
                return t.Result;
            }
            catch (Exception e)
            {
                string m = e.GetBaseException().Message;
                m = m.Replace("  ", " ").Trim();
                if (m.Contains(" 403") || m.Contains(" 401")) m += " - check key";
                else if (m.Contains("end of the stream")) m = "connection closed before answer - server is blocked or url is wrong";
                else if (m.Contains("timeout") || m.Contains("TCP connect failed")) m += " - server unreachable (blocked? check url/ip)";
                return "FAIL - " + m;
            }
            finally { if (ws != null) ws.Close(); }
        }
    }

    static bool Match(string host)
    {
        HashSet<string> set = domains;
        host = host.ToLowerInvariant().TrimEnd('.');
        int idx = 0;
        while (true)
        {
            if (set.Contains(idx == 0 ? host : host.Substring(idx))) return true;
            int dot = host.IndexOf('.', idx);
            if (dot < 0) return false;
            idx = dot + 1;
        }
    }

    static async Task Pump(Stream from, Stream to)
    {
        byte[] buf = new byte[65536];
        int n;
        while ((n = await from.ReadAsync(buf, 0, buf.Length)) > 0) await to.WriteAsync(buf, 0, n);
    }

    static async Task PumpWs(Stream from, Ws ws)
    {
        byte[] buf = new byte[65536];
        int n;
        while ((n = await from.ReadAsync(buf, 0, buf.Length)) > 0) await ws.Send(buf, n);
    }

    public static Task Run()
    {
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        downUntil = new DateTime[Urls.Length];
        TcpListener l = new TcpListener(IPAddress.Loopback, Port);
        l.Start(512);
        return Accept(l);
    }

    static async Task Accept(TcpListener l)
    {
        while (true)
        {
            TcpClient c = await l.AcceptTcpClientAsync();
            Task t = Handle(c);
        }
    }

    static async Task Handle(TcpClient c)
    {
        c.NoDelay = true;
        KeepAlive(c);
        string target = "?";
        bool connect = false, ok = false;
        Ws ws = null;
        TcpClient remote = null;
        NetworkStream ns = c.GetStream();
        try
        {
            byte[] hb = new byte[32768];
            int hl = await Timeout(ReadHeader(ns, hb), 15000, "read header");
            int he = HeaderEnd(hb, hl);
            string[] rl = Encoding.ASCII.GetString(hb, 0, he).Split('\r')[0].Split(' ');
            if (rl.Length < 3) return;
            string host;
            int port;
            byte[] first;
            if (rl[0] == "CONNECT")
            {
                connect = true;
                int i = rl[1].LastIndexOf(':');
                if (i <= 0 || !int.TryParse(rl[1].Substring(i + 1), out port) || port < 1 || port > 65535) return;
                host = rl[1].Substring(0, i).Trim('[', ']');
                first = new byte[hl - he];
                Buffer.BlockCopy(hb, he, first, 0, first.Length);
            }
            else if (rl[1].StartsWith("/"))
            {
                byte[] body = Encoding.UTF8.GetBytes(rl[1].StartsWith("/proxy.pac") ? Pac : "");
                await Write(ns, (body.Length > 0 ? "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig" : "HTTP/1.1 404 Not Found") +
                    "\r\nCache-Control: no-cache\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n\r\n");
                await ns.WriteAsync(body, 0, body.Length);
                return;
            }
            else
            {
                Uri u;
                if (!Uri.TryCreate(rl[1], UriKind.Absolute, out u) || string.IsNullOrEmpty(u.Host) || u.Port < 1 || u.Port > 65535) return;
                host = u.Host.Trim('[', ']');
                port = u.Port;
                string hdr = Encoding.ASCII.GetString(hb, 0, he);
                int eol = hdr.IndexOf("\r\n");
                if (eol < 0) return;
                StringBuilder sb = new StringBuilder();
                sb.Append(rl[0]).Append(' ').Append(u.PathAndQuery).Append(' ').Append(rl[2]).Append("\r\n");
                foreach (string line in hdr.Substring(eol + 2).Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
                {
                    if (line.StartsWith("Proxy-Connection:", StringComparison.OrdinalIgnoreCase) ||
                        line.StartsWith("Connection:", StringComparison.OrdinalIgnoreCase)) continue;
                    sb.Append(line).Append("\r\n");
                }
                sb.Append("Connection: close\r\n\r\n");
                byte[] nh = Encoding.ASCII.GetBytes(sb.ToString());
                int bodyLen = hl - he;
                first = new byte[nh.Length + bodyLen];
                Buffer.BlockCopy(nh, 0, first, 0, nh.Length);
                Buffer.BlockCopy(hb, he, first, nh.Length, bodyLen);
            }
            target = host + ":" + port;
            bool tun = Match(host);
            target = (tun ? "PRX  " : "DIR  ") + target;
            Stream rs = null;
            if (tun)
            {
                ws = await Tunnel(host, port);
                target += " [" + ws.Server + "]";
            }
            else
            {
                remote = new TcpClient();
                remote.NoDelay = true;
                await Timeout(remote.ConnectAsync(host, port), 15000, "connect");
                KeepAlive(remote);
                rs = remote.GetStream();
            }
            if (Verbose || DebugOpen()) Log(target);
            if (connect) await Write(ns, "HTTP/1.1 200 Connection Established\r\n\r\n");
            ok = true;
            if (tun)
            {
                if (first.Length > 0) await ws.Send(first, first.Length);
                Task up = PumpWs(ns, ws), dn = ws.ReceiveTo(ns);
                Task done = await Task.WhenAny(up, dn);
                if (done == up && !up.IsFaulted)
                {
                    int seq;
                    do
                    {
                        seq = ws.RxSeq;
                        using (CancellationTokenSource cts = new CancellationTokenSource())
                        {
                            await Task.WhenAny(dn, Task.Delay(5000, cts.Token));
                            cts.Cancel();
                        }
                    } while (!dn.IsCompleted && ws.RxSeq != seq);
                }
                up.ContinueWith(x => { var e = x.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                dn.ContinueWith(x => { var e = x.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
            }
            else
            {
                if (first.Length > 0) await rs.WriteAsync(first, 0, first.Length);
                Task up = Pump(ns, rs).ContinueWith(x => { if (x.IsFaulted) { var e = x.Exception; try { remote.Close(); } catch { } } else { try { remote.Client.Shutdown(SocketShutdown.Send); } catch { } } });
                Task dn = Pump(rs, ns).ContinueWith(x => { if (x.IsFaulted) { var e = x.Exception; try { c.Close(); } catch { } } else { try { c.Client.Shutdown(SocketShutdown.Send); } catch { } } });
                await Task.WhenAll(up, dn);
            }
        }
        catch (Exception e)
        {
            if (target != "?") Log("ERR  " + target + " : " + e.GetBaseException().Message);
            if (connect && !ok) try { ns.Write(Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\n\r\n"), 0, 28); } catch { }
        }
        finally
        {
            if (ws != null) ws.Close();
            if (remote != null) remote.Close();
            c.Close();
        }
    }
}
'@

$cfg = @{ port = '1080'; setpac = '1'; verbose = '0' }
$srv = @{ cloudflare = @{ url = ''; key = ''; ip = '' }; deno = @{ url = ''; key = ''; ip = '' } }
$order = New-Object System.Collections.Generic.List[string]
$ini = Join-Path $PSScriptRoot 'ws-proxy-settings.txt'
if (Test-Path $ini) {
    $sec = ''
    foreach ($l in Get-Content $ini -Encoding UTF8) {
        if ($l -match '^\s*\[\s*([a-z]+)\s*\]\s*$') { $sec = $Matches[1].ToLower(); if ($srv.ContainsKey($sec) -and -not $order.Contains($sec)) { $order.Add($sec) }; continue }
        if ($l -match '^\s*([a-z_]+)\s*=\s*(.*?)\s*$') {
            if ($srv.ContainsKey($sec)) { $srv[$sec][$Matches[1].ToLower()] = $Matches[2] }
            else { $cfg[$Matches[1].ToLower()] = $Matches[2] }
        }
    }
}
$Port = 1080
if (-not [int]::TryParse($cfg.port, [ref]$Port) -or $Port -lt 1 -or $Port -gt 65535) {
    if (-not $Stop) { Fail "invalid port '$($cfg.port)' in utils\ws-proxy-settings.txt (must be 1..65535)" }
    $Port = 1080
}
$PacUrl = "http://127.0.0.1:$Port/proxy.pac"

if (-not ('WsProxy' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp -IgnoreWarnings }

$PacKey = 'HKCU:\Software\zapret-ws-proxy'
function Set-Pac([bool]$on, [bool]$reload) {
    $cur = (Get-ItemProperty $RegPath -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    $mine = "$cur" -match '^http://127\.0\.0\.1:\d+/proxy\.pac\?v=\d+$'
    if ($reload -and -not $mine) { [WsProxy]::Log('PAC setting changed externally, not overwriting it'); return }
    if ($on -and -not $mine) {
        # remember the previous PAC, so it can be restored even after a crash
        Remove-Item $PacKey -ErrorAction SilentlyContinue
        [void](New-Item $PacKey -Force)
        if ($null -ne $cur) { [void](New-ItemProperty $PacKey -Name PrevPac -Value $cur -PropertyType String -Force) }
    }
    if ($on) { Set-ItemProperty $RegPath -Name AutoConfigURL -Value "$PacUrl`?v=$([DateTime]::Now.Ticks)" }
    elseif ($mine) {
        $prev = (Get-ItemProperty $PacKey -Name PrevPac -ErrorAction SilentlyContinue).PrevPac
        if ($null -ne $prev) { Set-ItemProperty $RegPath -Name AutoConfigURL -Value $prev } else { Remove-ItemProperty $RegPath -Name AutoConfigURL }
    }
    if (-not $on) { Remove-Item $PacKey -ErrorAction SilentlyContinue }
    [WsProxy]::RefreshProxy()
}

if ($Stop) {
    # while this mutex exists, the running proxy exits by itself
    $request = New-Object System.Threading.Mutex($false, 'Local\zapret-ws-proxy-stop')
    for ($i = 0; (Test-NamedMutex 'Local\zapret-ws-proxy'); $i++) { if ($i -ge 200) { Fail 'did not stop in 50 s' }; Start-Sleep -Milliseconds 250 }
    Set-Pac $false
    Write-Host 'ws-proxy stopped'
    exit 0
}

$Servers = @()
foreach ($n in $order) {
    $u = $srv[$n].url; $k = $srv[$n].key; $ip = $srv[$n].ip
    if ($u -eq '' -and $k -eq '') { continue }
    if (-not $u.StartsWith('wss://', [StringComparison]::OrdinalIgnoreCase)) { Write-Host "[$n] skipped: url is empty or not wss:// (now: '$u')" -ForegroundColor Yellow; continue }
    if ($k -eq '' -or $k.StartsWith('CHANGE-ME', [StringComparison]::OrdinalIgnoreCase)) { Write-Host "[$n] skipped: key is empty" -ForegroundColor Yellow; continue }
    $parsedIp = $null
    if ($ip -ne '' -and (-not ($ip.Contains('.') -or $ip.Contains(':')) -or -not [System.Net.IPAddress]::TryParse($ip, [ref]$parsedIp))) { Write-Host "[$n] skipped: invalid ip '$ip'" -ForegroundColor Yellow; continue }
    $Servers += $n
}
if ($Servers.Count -eq 0) { Fail 'no server is set up: fill in url and key in [cloudflare] and/or [deno] section of utils\ws-proxy-settings.txt' }

$mutex = New-Object System.Threading.Mutex($false, 'Local\zapret-ws-proxy')
$acquired = $false
try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { Write-Host 'ws-proxy is already running'; Start-Sleep 3; exit 0 }
if (Test-NamedMutex 'Local\zapret-ws-proxy-stop') { Write-Host 'ws-proxy is stopping'; exit 0 }

function Load-List {
    $d = @(Get-Content $ListFile -Encoding UTF8 | ForEach-Object {
            $s = $_.Trim().ToLower()
            if ($s -eq '' -or $s.StartsWith('#')) { return }
            $s = ($s -replace '^https?://', '' -replace '^\*\.', '' -replace '[\s/:?#].*$', '').Trim('.')
            if ($s -match '^[a-z0-9._-]+$') { $s }
        } | Select-Object -Unique)
    if ($d.Count -eq 0) { return 0 }
    [WsProxy]::SetDomains([string[]]$d)
    $js = ($d | ForEach-Object { "`"$_`":1" }) -join ','
    [WsProxy]::Pac = "var d={$js};`nfunction FindProxyForURL(url, host) {`n  host = host.toLowerCase().replace(/\.+$/, '');`n  while (true) {`n    if (d[host] === 1) return 'PROXY 127.0.0.1:$Port; DIRECT';`n    var i = host.indexOf('.');`n    if (i < 0) return 'DIRECT';`n    host = host.slice(i + 1);`n  }`n}`n"
    return $d.Count
}

if (-not (Test-Path $ListFile)) { Fail "$ListFile not found" }
$count = Load-List
if ($count -eq 0) { Fail 'list-proxy.txt is empty' }
$listTime = (Get-Item $ListFile).LastWriteTime

[WsProxy]::Names = [string[]]$Servers
[WsProxy]::Urls = [string[]]@($Servers | ForEach-Object { $srv[$_].url })
[WsProxy]::Keys = [string[]]@($Servers | ForEach-Object { $srv[$_].key })
[WsProxy]::Ips = [string[]]@($Servers | ForEach-Object { "$($srv[$_].ip)" })
[WsProxy]::Port = $Port
[WsProxy]::Verbose = ($cfg.verbose -eq '1')

try { $task = [WsProxy]::Run() } catch { Fail "cannot listen on 127.0.0.1:$Port - $($_.Exception.GetBaseException().Message)" }
try { [WsProxy]::InitLog($LogFile, "ws-proxy running: proxy 127.0.0.1:$Port, PAC $PacUrl"); $logReady = $true } catch { Fail "cannot create log: $($_.Exception.Message)" }
try {
    if ($cfg.setpac -eq '1') { Set-Pac $true }

    $host.UI.RawUI.WindowTitle = 'zapret: ws-proxy'
    for ($i = 0; $i -lt $Servers.Count; $i++) { [WsProxy]::Log("$(if ($i -eq 0) { 'main' } else { 'fallback' }): $($Servers[$i])") }
    [WsProxy]::Log("domains via proxy: $count (lists\list-proxy.txt)")
    [WsProxy]::Log('run "ws-proxy.ps1 -Stop" to stop')
    if ($cfg.setpac -eq '1') {
        $inet = Get-ItemProperty $RegPath -ErrorAction SilentlyContinue
        if ($inet -and $inet.ProxyEnable -eq 1) {
            $psrv = if ($inet.ProxyServer) { " ($($inet.ProxyServer))" } else { '' }
            [WsProxy]::Log("WARN Windows manual proxy is enabled$psrv - browsers may ignore PAC")
        }
        $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxySettingsPerUser -ErrorAction SilentlyContinue
        if ($pol -and $pol.ProxySettingsPerUser -eq 0) {
            [WsProxy]::Log('WARN ProxySettingsPerUser=0 in Windows policy - HKCU PAC may be ignored')
        }
    }
    [WsProxy]::Hold()
    try {
        $checks = @([WsProxy]::CheckAll())
        for ($i = 0; $i -lt $Servers.Count; $i++) { [WsProxy]::Log("checking $($Servers[$i])... $($checks[$i])") }
        Write-Host ''
    }
    finally { [WsProxy]::Release() }

    while (-not $task.Wait(2000) -and -not (Test-NamedMutex 'Local\zapret-ws-proxy-stop')) {
        $t = (Get-Item $ListFile -ErrorAction SilentlyContinue).LastWriteTime
        if ($t -and $t -ne $listTime) {
            try { $count = Load-List } catch { continue }
            $listTime = $t
            if ($count -gt 0) {
                if ($cfg.setpac -eq '1') { Set-Pac $true $true }
                [WsProxy]::Log("list-proxy.txt reloaded: $count domains")
            }
            else { [WsProxy]::Log('list-proxy.txt is empty, keeping the previous list') }
        }
    }
    if ($task.IsFaulted) { Fail "crashed: $($task.Exception.GetBaseException().Message)" }
}
finally {
    if ($cfg.setpac -eq '1') { try { Set-Pac $false } catch { [WsProxy]::Log("ERR  cannot restore PAC: $($_.Exception.Message)") } }
}