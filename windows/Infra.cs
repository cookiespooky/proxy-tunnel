// Нижний слой Windows-версии: настройки, ключи, ssh, туннель, PAC, системный прокси, настройки Claude Code.
// То же устройство, что у версии для Mac (menubar/), — описание в TECHNICAL.md.
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace ProxyTunnel;

public static class Paths
{
    public static string Dir
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Proxy Tunnel");
            Directory.CreateDirectory(d);
            return d;
        }
    }
    public static string ConfigFile => Path.Combine(Dir, "config.json");
    public static string TunnelKey => Path.Combine(Dir, "tunnel_rsa");
    public static string AdminKey => Path.Combine(Dir, "admin_rsa");
    public static string KnownHosts => Path.Combine(Dir, "known_hosts.json");
    public static string LogFile => Path.Combine(Dir, "log.txt");
    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string UserSsh => Path.Combine(Home, ".ssh");
    public static string ClaudeSettings => Path.Combine(Home, ".claude", "settings.json");
}

public static class Log
{
    static readonly object L = new();
    public static void Append(string s)
    {
        lock (L)
        {
            try
            {
                var stamp = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var text = string.Concat(s.Replace("\r", "").Split('\n').Where(x => x.Length > 0).Select(x => $"{stamp} {x}\n"));
                File.AppendAllText(Paths.LogFile, text);
            }
            catch { }
        }
    }
}

public sealed class Config
{
    public string Host { get; set; } = "";
    public int SshPort { get; set; } = 22;
    public string User { get; set; } = "tunnel";
    public string AdminUser { get; set; } = "root";
    public int LocalPort { get; set; } = 8888;
    public int RemotePort { get; set; } = 8888;
    public int PacPort { get; set; } = 8889;
    public List<string> Domains { get; set; } = new()
        { "claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com", "claude.site", "threads.net", "threads.com",
          "gemini.google.com", "aistudio.google.com", "chatgpt.com", "openai.com" };

    /// Где взять сервер — показывается, пока сервер не задан (реферальная ссылка автора).
    public const string RentServerUrl = "https://cloud4box.com/?from=108671";
    /// Ссылки окна «?»: страница инструмента, Life OS, автор.
    public const string ToolPageUrl = "https://antonlozhkin.ru/cases/proxy-tunnel/";
    public const string LifeOSUrl = "https://lifeos.antonlozhkin.ru/";

    [JsonIgnore] public string HostT => Host.Trim();
    [JsonIgnore] public string AdminT => string.IsNullOrWhiteSpace(AdminUser) ? "root" : AdminUser.Trim();
    [JsonIgnore] public bool IsComplete => HostT.Length > 0 && File.Exists(Paths.TunnelKey);
    [JsonIgnore] public string ProxyUrl => $"http://127.0.0.1:{LocalPort}";
    [JsonIgnore] public string PacBase => $"http://127.0.0.1:{PacPort}/proxy.pac";

    public List<string> CleanDomains() => Domains
        .Select(d => d.Trim().ToLowerInvariant().TrimStart('.'))
        .Where(d => d.Length > 0 && !d.Contains(' ') && !d.Contains('"'))
        .Distinct().ToList();

    /// PAC без запасного DIRECT: нет туннеля — нет соединения с этими доменами.
    public string PacText()
    {
        var list = string.Join(", ", CleanDomains().Select(d => $"\"{d}\""));
        return "// Proxy Tunnel: эти домены идут через туннель, остальное напрямую.\n" +
               "function FindProxyForURL(url, host) {\n" +
               $"  var viaTunnel = [{list}];\n" +
               "  for (var i = 0; i < viaTunnel.length; i++) {\n" +
               "    if (host == viaTunnel[i] || dnsDomainIs(host, \".\" + viaTunnel[i])) {\n" +
               $"      return \"PROXY 127.0.0.1:{LocalPort}\";\n" +
               "    }\n  }\n  return \"DIRECT\";\n}\n";
    }

    static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

    public static Config Load()
    {
        try { return JsonSerializer.Deserialize<Config>(File.ReadAllText(Paths.ConfigFile)) ?? new Config(); }
        catch { return new Config(); }
    }

    public void Save() => File.WriteAllText(Paths.ConfigFile, JsonSerializer.Serialize(this, Opts));
    public Config Clone() => JsonSerializer.Deserialize<Config>(JsonSerializer.Serialize(this))!;
}

/// Ключи программы — в её папке, не в ~/.ssh. RSA: ed25519 встроенными средствами .NET не создать.
/// Годный ключ используется повторно; негодный под тем же именем откладывается в «<имя>.old-<время>».
public static class Keys
{
    public static string Machine => Regex.Replace(Environment.MachineName, "[^A-Za-z0-9_-]", "-");

    public static string? Ensure(string path, string comment)
    {
        try
        {
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            void Aside(string p)
            {
                if (!File.Exists(p)) return;
                File.Move(p, $"{p}.old-{stamp}");
                Log.Append($"ключ {p} не годится — отложен как {p}.old-{stamp}");
            }
            if (File.Exists(path))
            {
                try
                {
                    using var existing = RSA.Create();
                    existing.ImportFromPem(File.ReadAllText(path));
                    _ = new PrivateKeyFile(path);
                    var line = PublicLine(existing, comment);
                    var body = string.Join(' ', line.Split(' ').Take(2));
                    if (!File.Exists(path + ".pub") || !File.ReadAllText(path + ".pub").StartsWith(body))
                    {
                        Aside(path + ".pub");
                        File.WriteAllText(path + ".pub", line + "\n");
                    }
                    return null;
                }
                catch { Aside(path); Aside(path + ".pub"); }
            }
            else Aside(path + ".pub");

            using var rsa = RSA.Create(3072);
            File.WriteAllText(path, rsa.ExportRSAPrivateKeyPem());
            File.WriteAllText(path + ".pub", PublicLine(rsa, comment) + "\n");
            return null;
        }
        catch (Exception e) { return e.Message; }
    }

    public static string? Public(string path) =>
        File.Exists(path + ".pub") ? File.ReadAllText(path + ".pub").Trim() : null;

    /// Открытый ключ в формате OpenSSH: «ssh-rsa <base64> <комментарий>».
    static string PublicLine(RSA rsa, string comment)
    {
        var p = rsa.ExportParameters(false);
        using var ms = new MemoryStream();
        void Str(byte[] b)
        {
            var len = BitConverter.GetBytes(b.Length);
            if (BitConverter.IsLittleEndian) Array.Reverse(len);
            ms.Write(len, 0, 4);
            ms.Write(b, 0, b.Length);
        }
        static byte[] Mpint(byte[] b)
        {
            if (b.Length > 0 && b[0] >= 0x80)
            {
                var r = new byte[b.Length + 1];
                Buffer.BlockCopy(b, 0, r, 1, b.Length);
                return r;
            }
            return b;
        }
        Str(Encoding.ASCII.GetBytes("ssh-rsa"));
        Str(Mpint(p.Exponent!));
        Str(Mpint(p.Modulus!));
        return $"ssh-rsa {Convert.ToBase64String(ms.ToArray())} {comment}@{Machine}";
    }
}

/// Ключ сервера: запоминается при первом подключении, при смене — отказ (сервер переустановили или подмена).
public static class HostKeys
{
    static Dictionary<string, string> Load()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Paths.KnownHosts)) ?? new(); }
        catch { return new(); }
    }

    public static bool Check(string id, string fingerprint)
    {
        lock (typeof(HostKeys))
        {
            var d = Load();
            if (d.TryGetValue(id, out var known)) return known == fingerprint;
            d[id] = fingerprint;
            File.WriteAllText(Paths.KnownHosts, JsonSerializer.Serialize(d));
            return true;
        }
    }

    public static void Forget() { try { File.Delete(Paths.KnownHosts); } catch { } }
}

public sealed class HostKeyChangedException : Exception { }

public enum Probe { Root, Sudo, NoSudo, Denied, Refused, Failed }

public static class Ssh
{
    /// Ключи для входа админом: ключ входа программы и обычные ключи пользователя из ~/.ssh.
    public static List<string> DefaultKeyFiles()
    {
        var l = new List<string>();
        if (File.Exists(Paths.AdminKey)) l.Add(Paths.AdminKey);
        foreach (var n in new[] { "id_ed25519", "id_ecdsa", "id_rsa" })
        {
            var p = Path.Combine(Paths.UserSsh, n);
            if (File.Exists(p)) l.Add(p);
        }
        return l;
    }

    /// Подключение. password != null — по паролю; иначе по ключам (keyFiles или ключи по умолчанию).
    public static SshClient Connect(Config c, string user, string? password, IEnumerable<string>? keyFiles)
    {
        var methods = new List<AuthenticationMethod>();
        if (password != null)
        {
            methods.Add(new PasswordAuthenticationMethod(user, password));
            var ki = new KeyboardInteractiveAuthenticationMethod(user);
            ki.AuthenticationPrompt += (_, e) => { foreach (var p in e.Prompts) p.Response = password; };
            methods.Add(ki);
        }
        else
        {
            var keys = new List<IPrivateKeySource>();
            foreach (var f in keyFiles ?? DefaultKeyFiles())
            {
                try { keys.Add(new PrivateKeyFile(f)); } catch { }   // ключ с паролем или не ключ — пропускаем
            }
            if (keys.Count == 0) throw new SshAuthenticationException("нет ключей для входа");
            methods.Add(new PrivateKeyAuthenticationMethod(user, keys.ToArray()));
        }
        var ci = new ConnectionInfo(c.HostT, c.SshPort, user, methods.ToArray()) { Timeout = TimeSpan.FromSeconds(15) };
        var client = new SshClient(ci);
        var changed = false;
        client.HostKeyReceived += (_, e) =>
        {
            if (HostKeys.Check($"{c.HostT}:{c.SshPort}", e.FingerPrintSHA256)) e.CanTrust = true;
            else { e.CanTrust = false; changed = true; }
        };
        try { client.Connect(); }
        catch when (changed) { client.Dispose(); throw new HostKeyChangedException(); }
        catch { client.Dispose(); throw; }
        return client;
    }

    static SocketError? Sock(Exception e)
    {
        for (var x = e; x != null; x = x.InnerException)
            if (x is SocketException se) return se.SocketErrorCode;
        return null;
    }

    public static string Explain(Exception e)
    {
        if (e is HostKeyChangedException)
            return "Ключ сервера изменился (сервер переустановили?). В настройках нажмите «Забыть ключ сервера» и повторите.";
        if (e is SshAuthenticationException) return "Вход не прошёл: неверный логин, пароль или ключ.";
        switch (Sock(e))
        {
            case SocketError.ConnectionRefused:
                return "Сервер отклонил подключение. Если перед этим было много подключений подряд, подождите полминуты и повторите; иначе проверьте порт.";
            case SocketError.HostNotFound:
            case SocketError.NoData:
                return "Адрес сервера не найден.";
            case SocketError.AddressAlreadyInUse:
                return "Порт туннеля на этом компьютере занят другой программой — смените его в «Дополнительно».";
            case null: break;
            default: return "Сервер не отвечает: проверьте адрес и порт.";
        }
        if (e is SshOperationTimeoutException) return "Сервер не отвечает: проверьте адрес и порт.";
        return e.Message;
    }

    public static Probe Classify(Exception e) =>
        e is SshAuthenticationException ? Probe.Denied :
        Sock(e) == SocketError.ConnectionRefused ? Probe.Refused : Probe.Failed;

    public static (int code, string output) Run(SshClient cl, string cmd)
    {
        using var c = cl.CreateCommand(cmd);
        c.CommandTimeout = TimeSpan.FromMinutes(10);
        var output = c.Execute();
        object? es = c.ExitStatus;
        var code = es == null ? -1 : Convert.ToInt32(es);
        return (code, output + c.Error);
    }

    const string ProbeCmd =
        "if [ \"$(id -u)\" = 0 ]; then echo PT-ROOT; elif sudo -n true 2>/dev/null; then echo PT-SUDO; else echo PT-NOSUDO; fi";

    public static Probe ProbeOn(SshClient cl)
    {
        var (_, o) = Run(cl, ProbeCmd);
        return o.Contains("PT-ROOT") ? Probe.Root : o.Contains("PT-SUDO") ? Probe.Sudo : Probe.NoSudo;
    }

    public static string Sq(string s) => "'" + s.Replace("'", "'\\''") + "'";

    /// Скрипт из server/, вшитый в программу (один и тот же для Mac и Windows).
    public static string Script(string name)
    {
        using var st = typeof(Ssh).Assembly.GetManifestResourceStream($"ProxyTunnel.{name}.sh")
                       ?? throw new InvalidOperationException($"нет скрипта {name}.sh");
        using var r = new StreamReader(st);
        return r.ReadToEnd().Replace("\r\n", "\n");
    }

    public static string ScriptEnv(Config c, string pub) =>
        $"TUNNEL_USER={Sq(c.User)} PROXY_PORT={c.RemotePort} PUBKEY={Sq(pub)}";

    public static string ManualCommand(Config c, string pub) =>
        $"sudo env {ScriptEnv(c, pub)} bash <<'PROXYTUNNEL'\n{Script("setup")}\nPROXYTUNNEL\n";

    /// Запускает скрипт на сервере под root (или через sudo); null — успех, иначе причина.
    public static string? RunScript(SshClient cl, string name, bool root, string env, string success)
    {
        var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(Script(name)));
        var cmd = $"echo {b64} | base64 -d | " + (root ? "" : "sudo -n ") + $"env {env} bash -s";
        var (code, o) = Run(cl, cmd);
        Log.Append($"{name}.sh: код {code}\n{o}");
        if (code == 0 && o.Contains(success)) return null;
        var err = o.Split('\n').FirstOrDefault(l => l.StartsWith("PT-ERROR:"));
        if (err != null) return err["PT-ERROR:".Length..].Trim();
        var last = o.Trim().Split('\n').LastOrDefault() ?? "";
        return last.Length > 0 ? last : $"код {code}";
    }

    public static string? AddKey(SshClient cl, string pub)
    {
        var k = Sq(pub);
        var (_, o) = Run(cl, "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
                             $"(grep -qxF {k} ~/.ssh/authorized_keys || echo {k} >> ~/.ssh/authorized_keys) && echo PT-OK");
        return o.Contains("PT-OK") ? null : o.Trim();
    }

    public static bool? PasswordEnabled(SshClient cl, bool root)
    {
        var (_, o) = Run(cl, (root ? "" : "sudo -n ") + "sshd -T 2>/dev/null | grep -i '^passwordauthentication '");
        o = o.ToLowerInvariant();
        return o.Contains("passwordauthentication yes") ? true : o.Contains("passwordauthentication no") ? false : null;
    }
}

/// Туннель: ssh-подключение пользователем туннеля и проброс 127.0.0.1:<порт> на прокси сервера.
/// Обрыв — переподключение с паузой 3 → 60 секунд.
public sealed class Tunnel
{
    SshClient? client;
    ForwardedPortLocal? fwd;
    CancellationTokenSource? cts;
    public volatile bool Running;
    public volatile string LastError = "";

    public void Start(Config c)
    {
        Stop();
        cts = new CancellationTokenSource();
        var token = cts.Token;
        var cfg = c.Clone();
        Task.Run(() => Loop(cfg, token));
    }

    public void Stop()
    {
        cts?.Cancel();
        cts = null;
        Close();
        Running = false;
    }

    void Close()
    {
        try { fwd?.Stop(); } catch { }
        try { client?.Disconnect(); } catch { }
        try { client?.Dispose(); } catch { }
        client = null;
        fwd = null;
    }

    async Task Loop(Config c, CancellationToken t)
    {
        var backoff = 3.0;
        while (!t.IsCancellationRequested)
        {
            try
            {
                client = Ssh.Connect(c, c.User, null, new[] { Paths.TunnelKey });
                client.KeepAliveInterval = TimeSpan.FromSeconds(20);
                fwd = new ForwardedPortLocal("127.0.0.1", (uint)c.LocalPort, "127.0.0.1", (uint)c.RemotePort);
                client.AddForwardedPort(fwd);
                fwd.Start();
                Running = true;
                LastError = "";
                backoff = 3;
                Log.Append($"туннель подключён: {c.User}@{c.HostT}:{c.SshPort}, 127.0.0.1:{c.LocalPort}");
                while (!t.IsCancellationRequested && client.IsConnected && fwd.IsStarted)
                {
                    try { await Task.Delay(2000, t); } catch { break; }
                }
            }
            catch (Exception e)
            {
                LastError = Ssh.Explain(e);
                Log.Append("туннель: " + e.Message);
            }
            Running = false;
            Close();
            if (t.IsCancellationRequested) break;
            try { await Task.Delay(TimeSpan.FromSeconds(backoff), t); } catch { break; }
            backoff = Math.Min(backoff * 2, 60);
        }
    }
}

/// Раздаёт PAC-файл на 127.0.0.1:<порт> из памяти программы.
public sealed class PacServer
{
    TcpListener? listener;
    volatile string text = "";
    public string Error = "";

    public void Start(int port, string pac)
    {
        Stop();
        text = pac;
        try
        {
            var l = new TcpListener(IPAddress.Loopback, port);
            l.Start();
            listener = l;
            Error = "";
            _ = Accept(l);
        }
        catch (Exception e)
        {
            Error = "PAC: " + e.Message;
            Log.Append(Error);
        }
    }

    public void Stop()
    {
        try { listener?.Stop(); } catch { }
        listener = null;
    }

    async Task Accept(TcpListener l)
    {
        while (true)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(); } catch { return; }
            _ = Task.Run(() => Serve(c));
        }
    }

    void Serve(TcpClient c)
    {
        using (c)
        {
            try
            {
                var s = c.GetStream();
                s.ReadTimeout = 3000;
                var buf = new byte[8192];
                _ = s.Read(buf, 0, buf.Length);
                var body = Encoding.UTF8.GetBytes(text);
                var head = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n" +
                    $"Content-Length: {body.Length}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n");
                s.Write(head, 0, head.Length);
                s.Write(body, 0, body.Length);
            }
            catch { }
        }
    }
}

/// Системный прокси Windows для текущего пользователя (настройки, которые берут браузеры и приложение Claude).
/// Ставится только адрес PAC; если там уже стоит чужой PAC — не трогаем. Права администратора не нужны.
public static class SystemProxy
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    [DllImport("wininet.dll", SetLastError = true)]
    static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);

    static void Notify()
    {
        InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0);   // INTERNET_OPTION_SETTINGS_CHANGED
        InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);   // INTERNET_OPTION_REFRESH
    }

    public static string? CurrentPac()
    {
        using var k = Registry.CurrentUser.OpenSubKey(Key);
        return k?.GetValue("AutoConfigURL") as string;
    }

    public static bool ManualProxyOn()
    {
        using var k = Registry.CurrentUser.OpenSubKey(Key);
        return k?.GetValue("ProxyEnable") is int v && v == 1;
    }

    public static bool IsOurs(string pacBase) => CurrentPac()?.StartsWith(pacBase) == true;

    /// refresh — поставить новый адрес даже если наш уже стоит: Windows кэширует PAC по адресу,
    /// а после смены списка сайтов нужен свежий. Возвращает (чужой PAC, ошибка).
    public static (bool foreign, string? error) Apply(string pacBase, bool refresh)
    {
        try
        {
            var cur = CurrentPac();
            var ours = cur?.StartsWith(pacBase) == true;
            if (!ours && !string.IsNullOrEmpty(cur)) return (true, null);
            if (ours && !refresh) return (false, null);
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            k.SetValue("AutoConfigURL", $"{pacBase}?v={DateTime.UtcNow.Ticks}");
            Notify();
            return (false, null);
        }
        catch (Exception e) { return (false, e.Message); }
    }

    public static void Remove(string pacBase)
    {
        try
        {
            if (!IsOurs(pacBase)) return;
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            k.DeleteValue("AutoConfigURL", false);
            Notify();
        }
        catch { }
    }
}

/// ~/.claude/settings.json: трогаем только env.HTTPS_PROXY и env.NO_PROXY, перед записью — копия .bak.
public static class ClaudeSettings
{
    static JsonObject Load()
    {
        var p = Paths.ClaudeSettings;
        if (!File.Exists(p)) return new JsonObject();
        return JsonNode.Parse(File.ReadAllText(p)) as JsonObject
               ?? throw new InvalidOperationException("~/.claude/settings.json не читается как JSON — не трогаю его");
    }

    public static string? Proxy()
    {
        try { return Load()["env"]?["HTTPS_PROXY"]?.GetValue<string>(); }
        catch { return null; }
    }

    public static void Set(string? proxy, string host)
    {
        var d = Load();
        var p = Paths.ClaudeSettings;
        if (File.Exists(p)) File.Copy(p, p + ".bak", true);
        var env = d["env"] as JsonObject;
        d.Remove("env");
        env ??= new JsonObject();
        if (proxy != null)
        {
            env["HTTPS_PROXY"] = proxy;
            env["NO_PROXY"] = "localhost,127.0.0.1,::1,.ru,.xn--p1ai," + host;
        }
        else
        {
            env.Remove("HTTPS_PROXY");
            env.Remove("NO_PROXY");
        }
        if (env.Count > 0) d["env"] = env;
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        var opts = new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };
        File.WriteAllText(p, d.ToJsonString(opts) + "\n");
    }
}

public static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "Proxy Tunnel";

    public static bool On
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(Name) != null;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue(Name, $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue(Name, false);
        }
    }
}

public static class Net
{
    /// Что claude.ai видит на выходе через туннель: адрес и страна.
    public static async Task<(string ip, string loc)> Trace(string proxyUrl)
    {
        try
        {
            using var h = new HttpClientHandler { Proxy = new WebProxy(proxyUrl), UseProxy = true };
            using var c = new HttpClient(h) { Timeout = TimeSpan.FromSeconds(10) };
            var t = await c.GetStringAsync("https://claude.ai/cdn-cgi/trace");
            string ip = "", loc = "";
            foreach (var l in t.Split('\n'))
            {
                if (l.StartsWith("ip=")) ip = l[3..].Trim();
                if (l.StartsWith("loc=")) loc = l[4..].Trim();
            }
            return (ip, loc);
        }
        catch { return ("", ""); }
    }

    public static async Task<string> Get(string url)
    {
        try
        {
            using var h = new HttpClientHandler { UseProxy = false };
            using var c = new HttpClient(h) { Timeout = TimeSpan.FromSeconds(3) };
            return await c.GetStringAsync(url);
        }
        catch { return ""; }
    }

    public static string? ResolveIPv4(string host)
    {
        if (IPAddress.TryParse(host, out var a)) return a.ToString();
        try { return Dns.GetHostAddresses(host).FirstOrDefault(x => x.AddressFamily == AddressFamily.InterNetwork)?.ToString(); }
        catch { return null; }
    }
}
