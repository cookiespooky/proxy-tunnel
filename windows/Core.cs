// Логика Windows-версии: включение туннеля, проверки, настройка сервера, доступ к серверу.
// Повторяет Model.swift версии для Mac. Все изменения состояния — на потоке окна; Changed зовёт перерисовку.
using Renci.SshNet;

namespace ProxyTunnel;

public sealed class Step
{
    public string Title = "";
    public bool? Ok;          // null — ещё идёт или не начат
    public bool Running;
    public string Detail = "";
    public Step(string t) { Title = t; }
}

public enum AccessState { Idle, Checking, Key, NeedPassword, Failed }

public sealed class Core
{
    readonly SynchronizationContext ui;
    public event Action? Changed;
    public void Fire() => ui.Post(_ => Changed?.Invoke(), null);

    public Config Config = Config.Load();
    public readonly Tunnel Tunnel = new();
    public readonly PacServer Pac = new();

    // окошко значка
    public bool Enabled;            // при запуске — выключен; включают нажатием на карточку
    public bool Busy, Checking, VerdictOK;
    public string Message = "";
    public DateTime? CheckedAt;
    public List<Step> Steps = new();
    public bool ForeignPac;
    bool announceOn;

    // новая версия: что сказал сервер обновлений; новее установленной — строка «Доступна версия…» в панели
    public string LatestVersion = AppUpdate.KnownLatest;
    DateTime pingFailedAt = DateTime.MinValue;
    public string? UpdateAvailable =>
        LatestVersion.Length > 0 && AppUpdate.IsNewer(LatestVersion, AppUpdate.Version) ? LatestVersion : null;

    // настройка сервера
    public AccessState Access = AccessState.Idle;
    public string AccessText = "";
    public List<Step> SetupSteps = new();
    public bool SetupBusy, SetupDone;
    int probeGen;

    // доступ к серверу
    public bool AccessBusy;
    public bool? KeyStable;
    public string KeyCheckedHow = "";   // «проверено при настройке» / «проверено при открытии настроек»; пусто — кнопкой, 3 из 3
    public bool? PasswordLogin;
    public bool KeyDenied;
    public string AccessNote = "";
    bool adminIsRoot = true;

    public static readonly string[] TunnelSteps =
        { "Туннель подключён", "Выход через туннель", "Claude Code → туннель", "Сайты из списка → туннель" };

    public Core()
    {
        ui = SynchronizationContext.Current ?? new SynchronizationContext();
        var timer = new System.Windows.Forms.Timer { Interval = 120_000 };
        timer.Tick += async (_, _) => { await Refresh(quiet: true); MaybePing(); };
        timer.Start();
        ui.Post(async _ => { await Task.Delay(5000); MaybePing(); }, null);
    }

    /// Спросить о новой версии (и отметиться, если статистика включена), когда пора; сервер не ответил — через полчаса.
    public async void MaybePing()
    {
        var on = Enabled && VerdictOK;
        if (!AppUpdate.Due(on) || DateTime.Now - pingFailedAt < TimeSpan.FromMinutes(30)) return;
        pingFailedAt = DateTime.Now;           // и защита от второго запроса, пока идёт первый
        var v = await AppUpdate.Ping(on);
        if (v == null) return;
        pingFailedAt = DateTime.MinValue;
        LatestVersion = v;
        Fire();
    }

    // MARK: туннель и системные настройки

    /// Туннель выключен — гасит его и снимает настройки (в том числе оставшиеся после аварийного закрытия).
    public async Task StartServices(bool refreshPac = true)
    {
        Tunnel.Stop();
        if (!(Config.IsComplete && Enabled))
        {
            Pac.Stop();
            RemoveSystem();
            Steps.Clear();
            VerdictOK = false;
            CheckedAt = null;
            Fire();
            return;
        }
        Pac.Start(Config.PacPort, Config.PacText());
        Tunnel.Start(Config);
        var e = ApplySystem(refreshPac);
        if (e != null) Message = e;
        Fire();
        await Task.Delay(3000);
        await Refresh();
    }

    public async Task Toggle()
    {
        if (!Config.IsComplete || Busy) return;
        Enabled = !Enabled;
        Message = Enabled ? "" : "Туннель выключен: Claude Code и браузер ходят напрямую. Перезапустите Claude Code, если он открыт.";
        Fire();
        await StartServices();
    }

    public async Task Reconnect()
    {
        if (Busy || !Enabled) return;
        Message = "Переподключаю туннель…";
        Fire();
        await StartServices(refreshPac: false);
        Message = "";
        Fire();
    }

    public void Apply(Config c)
    {
        Config = c;
        try { c.Save(); } catch (Exception e) { Message = "Настройки не сохранились: " + e.Message; }
        _ = StartServices();
    }

    string? ApplySystem(bool refreshPac)
    {
        var wasSet = ClaudeSettings.Proxy() == Config.ProxyUrl;
        if (!wasSet)
        {
            try { ClaudeSettings.Set(Config.ProxyUrl, Config.HostT); }
            catch (Exception e) { return e.Message; }
            announceOn = true;
        }
        var (foreign, error) = SystemProxy.Apply(Config.PacBase, refreshPac);
        ForeignPac = foreign;
        return error;
    }

    void RemoveSystem()
    {
        try { if (ClaudeSettings.Proxy() == Config.ProxyUrl) ClaudeSettings.Set(null, Config.HostT); } catch { }
        SystemProxy.Remove(Config.PacBase);
    }

    /// При выходе из программы — снять всё.
    public void Shutdown()
    {
        Tunnel.Stop();
        Pac.Stop();
        RemoveSystem();
    }

    // MARK: проверки

    public async Task Refresh(bool quiet = false)
    {
        if (Busy) return;
        if (!(Config.IsComplete && Enabled)) { Steps.Clear(); VerdictOK = false; Fire(); return; }
        Busy = true;
        Checking = !quiet;
        Fire();
        var e = ApplySystem(false);
        if (e != null) Message = e;
        var work = TunnelSteps.Select(t => new Step(t)).ToList();
        var c = Config.Clone();

        var running = Tunnel.Running;
        work[0].Ok = running;
        work[0].Detail = running ? "" : (Tunnel.LastError.Length > 0 ? Tunnel.LastError : "подключаюсь…");

        var (ip, loc) = await Net.Trace(c.ProxyUrl);
        var expected = await Task.Run(() => Net.ResolveIPv4(c.HostT));
        var ipOk = ip.Length > 0 && loc != "RU" && (expected == null || ip == expected);
        work[1].Ok = ipOk;
        work[1].Detail = ip.Length == 0 ? "нет ответа" : $"{ip}, {loc}" + (!ipOk && expected != null ? $" — ожидался {expected}" : "");

        var cc = ClaudeSettings.Proxy();
        work[2].Ok = cc == c.ProxyUrl;
        work[2].Detail = cc == c.ProxyUrl ? "прокси в ~/.claude/settings.json" : "прокси не задан — Claude Code пойдёт мимо туннеля";

        var ours = SystemProxy.IsOurs(c.PacBase);
        var manual = SystemProxy.ManualProxyOn();
        var served = (await Net.Get(c.PacBase)).Contains($"PROXY 127.0.0.1:{c.LocalPort}");
        work[3].Ok = ours && !manual && served;
        if (!ours)
            work[3].Detail = ForeignPac ? "В Windows уже стоит другой PAC — программа его не трогает"
                                        : "Windows не применяет PAC туннеля";
        else if (manual)
            work[3].Detail = "В Windows включён ещё и обычный прокси (другая программа?) — браузер может пойти через него";
        else if (!served)
            work[3].Detail = Pac.Error.Length > 0 ? Pac.Error : "PAC не раздаётся — эти сайты не откроются";
        else
        {
            var list = c.CleanDomains();
            var shown = string.Join(", ", list.Take(3)) + (list.Count > 3 ? $" и ещё {list.Count - 3}" : "");
            work[3].Detail = $"в браузере и приложении Claude: {shown}. Остальные сайты — напрямую, как без туннеля; добавить — Настройки → «Через туннель»";
        }

        Steps = work;
        VerdictOK = work.All(s => s.Ok == true);
        CheckedAt = DateTime.Now;
        if (announceOn)
        {
            announceOn = false;
            Message = VerdictOK ? "Туннель включён для Claude. Перезапустите Claude, если он был открыт." : "";
        }
        Checking = false;
        Busy = false;
        Fire();
        MaybePing();
    }

    // MARK: настройка сервера

    /// Фоновая проверка: пускает ли сервер админа по ключу. Тот же вход читает, включён ли вход по паролю.
    public async Task ProbeAccess(Config c)
    {
        var gen = ++probeGen;
        if (c.HostT.Length == 0) { Access = AccessState.Idle; Fire(); return; }
        Access = AccessState.Checking;
        Fire();
        var r = await Task.Run(() =>
        {
            try
            {
                using var cl = Ssh.Connect(c, c.AdminT, null, null);
                var p = Ssh.ProbeOn(cl);
                bool? pw = p is Probe.Root or Probe.Sudo ? Ssh.PasswordEnabled(cl, p == Probe.Root) : null;
                return (p, pw, "");
            }
            catch (Exception e) { return (Ssh.Classify(e), (bool?)null, Ssh.Explain(e)); }
        });
        if (gen != probeGen) return;   // адрес успели поменять
        var (probe, pwOn, err) = r;
        switch (probe)
        {
            case Probe.Root:
            case Probe.Sudo:
                Access = AccessState.Key;
                AccessText = $"Ваш ключ подходит ({c.AdminT}{(probe == Probe.Sudo ? ", через sudo" : "")}) — пароль не нужен.";
                break;
            case Probe.NoSudo:
                Access = AccessState.Failed;
                AccessText = $"{c.AdminT} входит по ключу, но без sudo без пароля. Укажите логин root.";
                break;
            case Probe.Denied:
                Access = AccessState.NeedPassword;
                AccessText = "Вашего ключа на сервере нет — войдите логином и паролем от сервера.";
                break;
            default:
                Access = AccessState.Failed;
                AccessText = err;
                break;
        }
        // Это настроенный сервер — тот же результат идёт в «Доступ к серверу».
        if (c.HostT == Config.HostT && c.AdminT == Config.AdminT && !AccessBusy)
        {
            if (probe is Probe.Root or Probe.Sudo)
            {
                adminIsRoot = probe == Probe.Root;
                if (!(KeyStable == true && KeyCheckedHow.Length == 0))
                {
                    KeyStable = true;
                    KeyCheckedHow = "проверено при открытии настроек";
                }
                KeyDenied = false;
                if (pwOn != null) PasswordLogin = pwOn;
            }
            else if (probe == Probe.Denied)
            {
                KeyStable = false;
                KeyCheckedHow = "";
                KeyDenied = true;
            }
        }
        Fire();
    }

    void SetupStep(int i, bool ok, string detail = "", bool next = true)
    {
        ui.Post(_ =>
        {
            SetupSteps[i].Ok = ok;
            SetupSteps[i].Running = false;
            SetupSteps[i].Detail = detail;
            if (ok && next && i + 1 < SetupSteps.Count) SetupSteps[i + 1].Running = true;
            Changed?.Invoke();
        }, null);
    }

    /// Всё за один проход: ключ туннеля → вход админом (сначала по ключу; пароль — только если ключа нет)
    /// → скрипт сервера → по желанию ключ входа для админа → сохранить → туннель отвечает.
    /// Команды идут через одно подключение: на сервере может стоять ограничение частоты подключений.
    public async Task SetupServer(Config draft, string password, bool makeAdminKey)
    {
        if (SetupBusy) return;
        SetupBusy = true;
        SetupDone = false;
        var c = draft.Clone();
        c.Host = c.HostT;
        var admin = c.AdminT;
        var wantAdminKey = makeAdminKey && password.Length > 0;
        var titles = new List<string> { "Ключ туннеля", "Вход на сервер", "Прокси на сервере" };
        if (wantAdminKey) titles.Add("Ключ для входа на сервер");
        titles.Add("Туннель работает");
        var last = titles.Count - 1;
        SetupSteps = titles.Select(t => new Step(t)).ToList();
        SetupSteps[0].Running = true;
        Fire();
        var skipKey = Access == AccessState.NeedPassword && password.Length > 0;

        var result = await Task.Run<(bool ok, bool byPassword, bool keyWorks, bool? pw)>(() =>
        {
            var e0 = Keys.Ensure(Paths.TunnelKey, "proxy-tunnel");
            var pub = Keys.Public(Paths.TunnelKey);
            if (e0 != null || pub == null) { SetupStep(0, false, "Не создан: " + (e0 ?? "нет открытого ключа")); return (false, false, false, null); }
            SetupStep(0, true, Paths.TunnelKey);

            SshClient? cl = null;
            var byPassword = false;
            try
            {
                if (!skipKey)
                {
                    try { cl = Ssh.Connect(c, admin, null, null); }
                    catch (Exception e) when (Ssh.Classify(e) == Probe.Denied && password.Length > 0) { cl = null; }
                }
                if (cl == null)
                {
                    if (password.Length == 0)
                    {
                        ui.Post(_ => { Access = AccessState.NeedPassword; AccessText = "Вашего ключа на сервере нет — войдите логином и паролем от сервера."; }, null);
                        SetupStep(1, false, $"Ключа для {admin} на сервере нет — введите пароль.");
                        return (false, false, false, null);
                    }
                    cl = Ssh.Connect(c, admin, password, null);
                    byPassword = true;
                }
            }
            catch (Exception e)
            {
                SetupStep(1, false, Ssh.Classify(e) == Probe.Denied && password.Length > 0 ? "Пароль не подошёл." : Ssh.Explain(e));
                return (false, false, false, null);
            }

            using (cl)
            {
                var p = Ssh.ProbeOn(cl);
                if (p == Probe.NoSudo)
                {
                    SetupStep(1, false, $"{admin} вошёл, но без sudo без пароля. Войдите под root.");
                    return (false, byPassword, false, null);
                }
                var root = p == Probe.Root;
                adminIsRoot = root;
                SetupStep(1, true, $"{admin} {(byPassword ? "по паролю" : "по ключу")}{(root ? "" : ", через sudo")}");

                var e2 = Ssh.RunScript(cl, "setup", root, Ssh.ScriptEnv(c, pub), "сервер готов");
                if (e2 != null) { SetupStep(2, false, e2); return (false, byPassword, false, null); }
                SetupStep(2, true, $"tinyproxy на 127.0.0.1:{c.RemotePort}, пользователь {c.User}");
                var pwOn = byPassword ? true : Ssh.PasswordEnabled(cl, root);

                var keyWorks = !byPassword;
                if (wantAdminKey)
                {
                    if (!byPassword) SetupStep(3, true, "не нужен — вход уже по ключу");
                    else
                    {
                        var e3 = AddAdminKey(c, admin, cl);
                        if (e3 == null) { keyWorks = true; SetupStep(3, true, Paths.AdminKey); }
                        else
                        {
                            SetupStep(3, false, e3, next: false);
                            ui.Post(_ => { SetupSteps[last].Running = true; Changed?.Invoke(); }, null);
                        }
                    }
                }
                return (true, byPassword, keyWorks, pwOn);
            }
        });

        if (!result.ok) { SetupBusy = false; Fire(); return; }

        c.AdminUser = admin;
        Enabled = true;   // сервер только что настроен — туннель включается
        Config = c;
        try { c.Save(); } catch { }
        await StartServices();
        var (ip, loc) = ("", "");
        for (var i = 0; i < 10 && ip.Length == 0; i++)
        {
            (ip, loc) = await Net.Trace(c.ProxyUrl);
            if (ip.Length == 0) await Task.Delay(2000);
        }
        if (ip.Length > 0 && loc != "RU")
        {
            SetupSteps[last].Ok = true;
            SetupSteps[last].Detail = $"выход: {ip}, {loc}";
            SetupDone = true;
        }
        else
        {
            SetupSteps[last].Ok = false;
            SetupSteps[last].Detail = ip.Length == 0 ? (Tunnel.LastError.Length > 0 ? Tunnel.LastError : "нет ответа через туннель")
                                                     : $"выход {ip}, {loc} — это Россия";
        }
        SetupSteps[last].Running = false;

        // «Доступ к серверу» — по тому, что настройка уже проверила, без новых подключений.
        Access = result.keyWorks ? AccessState.Key : AccessState.NeedPassword;
        KeyStable = result.keyWorks;
        KeyCheckedHow = result.keyWorks ? "проверено при настройке" : "";
        KeyDenied = false;
        PasswordLogin = result.pw;
        AccessNote = result.keyWorks ? "Вход по ключу проверен при настройке." : "";
        SetupBusy = false;
        Fire();
    }

    /// Ключ входа программы → админу на сервер (через уже открытое подключение) → проверка новым входом по нему.
    static string? AddAdminKey(Config c, string admin, SshClient cl)
    {
        var e = Keys.Ensure(Paths.AdminKey, "proxy-tunnel-admin");
        var pub = Keys.Public(Paths.AdminKey);
        if (e != null || pub == null) return "Ключ не создан: " + (e ?? "нет открытого ключа");
        var e2 = Ssh.AddKey(cl, pub);
        if (e2 != null) return e2;
        try
        {
            using var check = Ssh.Connect(c, admin, null, new[] { Paths.AdminKey });
            return Ssh.ProbeOn(check) is Probe.Root or Probe.Sudo ? null : "Ключ добавлен, но прав root нет";
        }
        catch (Exception x) { return "Ключ добавлен, но вход по нему не прошёл: " + Ssh.Explain(x); }
    }

    // MARK: доступ к серверу

    public async Task AddAdminKeyNow(string password)
    {
        if (AccessBusy) return;
        AccessBusy = true;
        AccessNote = "Создаю ключ и добавляю его на сервер…";
        Fire();
        var c = Config.Clone();
        var e = await Task.Run(() =>
        {
            try
            {
                using var cl = Ssh.Connect(c, c.AdminT, password, null);
                return AddAdminKey(c, c.AdminT, cl);
            }
            catch (Exception x) { return Ssh.Explain(x); }
        });
        AccessBusy = false;
        if (e != null) { AccessNote = e; Fire(); return; }
        AccessNote = "Ключ добавлен. Проверяю вход по нему…";
        Fire();
        await CheckConnection();
    }

    /// «Проверить соединение»: три входа по ключу подряд; отказ в подключении — ограничение частоты: ждём и повторяем.
    public async Task CheckConnection()
    {
        if (AccessBusy || Config.HostT.Length == 0) return;
        AccessBusy = true;
        KeyStable = null;
        KeyDenied = false;
        KeyCheckedHow = "";
        Fire();
        var c = Config.Clone();
        var admin = c.AdminT;
        int ok = 0, waits = 0, i = 0;
        var fail = "";
        while (i < 3)
        {
            AccessNote = $"Вход по ключу: {i + 1} из 3…";
            Fire();
            var (p, err, pw) = await Task.Run(() =>
            {
                try
                {
                    using var cl = Ssh.Connect(c, admin, null, null);
                    var r = Ssh.ProbeOn(cl);
                    bool? pwOn = r is Probe.Root or Probe.Sudo ? Ssh.PasswordEnabled(cl, r == Probe.Root) : null;
                    return (r, "", pwOn);
                }
                catch (Exception e) { return (Ssh.Classify(e), Ssh.Explain(e), (bool?)null); }
            });
            if (p == Probe.Refused && waits < 2)
            {
                waits++;
                AccessNote = "Сервер ограничивает частоту подключений — жду 30 секунд и повторяю…";
                Fire();
                await Task.Delay(31_000);
                continue;
            }
            if (p is Probe.Root or Probe.Sudo)
            {
                ok++;
                adminIsRoot = p == Probe.Root;
                if (pw != null) PasswordLogin = pw;
            }
            else
            {
                fail = p == Probe.Denied ? "сервер не принял ключ" : p == Probe.NoSudo ? "нет прав root" : err;
                if (p == Probe.Denied) KeyDenied = true;
                break;
            }
            i++;
            if (i < 3) await Task.Delay(3000);   // не упереться в ограничение частоты
        }
        KeyStable = ok == 3;
        if (KeyStable == true) Access = AccessState.Key;
        var (ip, loc) = await Net.Trace(c.ProxyUrl);
        var tunnelText = ip.Length == 0 ? "туннель не отвечает" : $"туннель: выход {ip}, {loc}";
        AccessNote = (KeyStable == true ? "Вход по ключу: 3 из 3." : $"Вход по ключу не прошёл ({ok} из 3): {fail}.") + " " + tunnelText;
        AccessBusy = false;
        Fire();
        _ = Refresh();
    }

    /// «Выключить вход по паролю» — только когда вход по ключу подтверждён.
    public async Task DisablePasswordLogin()
    {
        if (AccessBusy || KeyStable != true) return;
        AccessBusy = true;
        AccessNote = "Выключаю вход по паролю…";
        Fire();
        var c = Config.Clone();
        var root = adminIsRoot;
        var (err, pw) = await Task.Run(() =>
        {
            try
            {
                using var cl = Ssh.Connect(c, c.AdminT, null, null);
                var e = Ssh.RunScript(cl, "no-password", root, "", "вход по паролю выключен");
                if (e != null) return (e, (bool?)null);
                return ((string?)null, Ssh.PasswordEnabled(cl, root));
            }
            catch (Exception x) { return (Ssh.Explain(x), (bool?)null); }
        });
        if (err != null) { AccessNote = "Не выключено: " + err; AccessBusy = false; Fire(); return; }
        // повторный вход по ключу — новым подключением: убедиться, что доступ к серверу остался
        var still = await Task.Run(() =>
        {
            try { using var cl = Ssh.Connect(c, c.AdminT, null, null); return Ssh.ProbeOn(cl) is Probe.Root or Probe.Sudo; }
            catch { return false; }
        });
        PasswordLogin = pw;
        if (!still)
        {
            KeyStable = false;
            AccessNote = "Вход по паролю выключен, но повторный вход по ключу не прошёл. Не закрывайте программу и нажмите «Проверить соединение»; копия прежних настроек ssh — на сервере в /root/proxy-tunnel-backup-…";
        }
        else if (pw == false) AccessNote = "Вход по паролю выключен. Вход по ключу работает.";
        else AccessNote = "Скрипт отработал, но сервер всё ещё принимает пароль — посмотрите журнал.";
        AccessBusy = false;
        Fire();
    }

    public void ForgetHostKey()
    {
        HostKeys.Forget();
        Message = "Ключ сервера забыт — при следующем подключении запомнится заново.";
        Fire();
    }
}
