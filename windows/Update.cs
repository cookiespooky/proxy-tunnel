// Проверка новой версии и анонимная статистика — как menubar/Update.swift: раз в день один запрос на
// stats.antonlozhkin.ru/pt/ping (и ещё один при первом за день включении туннеля). Статистика выключена —
// запрос только узнаёт версию.
using System.Reflection;
using System.Text.Json;
using Microsoft.Win32;

namespace ProxyTunnel;

public static class AppUpdate
{
    const string Endpoint = "https://stats.antonlozhkin.ru/pt/ping";
    public const string DownloadUrl = "https://github.com/cookiespooky/proxy-tunnel/releases/latest/download/ProxyTunnel-windows.exe";
    const string RegKey = @"Software\Proxy Tunnel";
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    public static string Version
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetName().Version;
            return v == null ? "0" : v.Build > 0 ? $"{v.Major}.{v.Minor}.{v.Build}" : $"{v.Major}.{v.Minor}";
        }
    }

    /// Галочка «Отправлять анонимную статистику» (по умолчанию включена).
    public static bool SendStats
    {
        get
        {
            try { using var k = Registry.CurrentUser.OpenSubKey(RegKey); return (k?.GetValue("SendStats") as int?) != 0; }
            catch { return true; }
        }
        set
        {
            try { using var k = Registry.CurrentUser.CreateSubKey(RegKey); k.SetValue("SendStats", value ? 1 : 0, RegistryValueKind.DWord); }
            catch { }
        }
    }

    /// Id — случайный номер установки, с компьютером не связан; Day / OnDay — когда отмечались; Latest — что ответил
    /// сервер в последний раз.
    public sealed class State
    {
        public string Id { get; set; } = "";
        public string Day { get; set; } = "";
        public string OnDay { get; set; } = "";
        public string Latest { get; set; } = "";
    }

    static string StateFile => Path.Combine(Paths.Dir, "stats.json");

    static State Load()
    {
        State s;
        try { s = JsonSerializer.Deserialize<State>(File.ReadAllText(StateFile)) ?? new State(); }
        catch { s = new State(); }
        if (s.Id.Length != 32) { s.Id = Guid.NewGuid().ToString("N"); Save(s); }
        return s;
    }

    static void Save(State s)
    {
        try { File.WriteAllText(StateFile, JsonSerializer.Serialize(s)); } catch { }
    }

    static string Today => DateTime.Now.ToString("yyyy-MM-dd");

    public static string KnownLatest => Load().Latest;

    /// Пора ли отметиться: сегодня ещё не спрашивали, или туннель включён, а сегодня об этом ещё не говорили.
    public static bool Due(bool tunnelOn)
    {
        var s = Load();
        return s.Day != Today || (tunnelOn && SendStats && s.OnDay != Today);
    }

    /// Один запрос. -> последняя версия или null, если сервер не ответил.
    public static async Task<string?> Ping(bool tunnelOn)
    {
        var s = Load();
        var url = $"{Endpoint}?os=win&v={Uri.EscapeDataString(Version)}";
        if (SendStats) url += $"&id={s.Id}&on={(tunnelOn ? 1 : 0)}";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.UserAgent.ParseAdd($"ProxyTunnel/{Version}");
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return null;
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            s.Latest = doc.RootElement.TryGetProperty("latest", out var l) ? l.GetString() ?? "" : "";
            s.Day = Today;
            if (tunnelOn && SendStats) s.OnDay = Today;
            Save(s);
            return s.Latest;
        }
        catch { return null; }
    }

    /// «1.10» новее «1.9»: сравнение по числам через точку.
    public static bool IsNewer(string a, string b)
    {
        int[] P(string x) => x.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var x = P(a); var y = P(b);
        for (var i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            var p = i < x.Length ? x[i] : 0; var q = i < y.Length ? y[i] : 0;
            if (p != q) return p > q;
        }
        return false;
    }
}
