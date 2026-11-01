// Интерфейс Windows-версии: значок у часов, панель над ним, окно настроек.
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Diagnostics;

namespace ProxyTunnel;

static class Palette
{
    public static readonly Color Green = Color.FromArgb(41, 158, 92);
    public static readonly Color Red = Color.FromArgb(219, 56, 56);
    public static readonly Color Orange = Color.FromArgb(235, 133, 26);
    public static readonly Color Gray = Color.FromArgb(140, 140, 140);
    public static readonly Color Blue = Color.FromArgb(26, 112, 219);
    public static readonly Color Sub = Color.FromArgb(105, 105, 105);
    public static readonly Color Card = Color.FromArgb(240, 240, 240);
    public static readonly Font Text = new("Segoe UI", 9f);
    public static readonly Font Small = new("Segoe UI", 8.5f);
    public static readonly Font Bold = new("Segoe UI", 9.5f, FontStyle.Bold);
    public static readonly Font Header = new("Segoe UI", 11f, FontStyle.Bold);
}

static class Ui
{
    public static Label L(string text, Font? font = null, Color? color = null, int width = 480) => new()
    {
        Text = text, AutoSize = true, MaximumSize = new Size(width, 0), Font = font ?? Palette.Text,
        ForeColor = color ?? SystemColors.ControlText, Margin = new Padding(0, 3, 0, 3)
    };

    public static FlowLayoutPanel Row(params Control[] cs)
    {
        var p = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false,
            Margin = new Padding(0, 2, 0, 2)
        };
        p.Controls.AddRange(cs);
        return p;
    }

    public static Label Caption(string text) => new()
    {
        Text = text, AutoSize = false, Width = 200, Height = 26, TextAlign = ContentAlignment.MiddleLeft, Font = Palette.Text
    };

    public static FlowLayoutPanel Column(int width) => new()
    {
        FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Width = width,
        Margin = new Padding(0)
    };

    public static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    public static string Mark(Step s) => s.Running ? "…" : s.Ok == true ? "✓" : s.Ok == false ? "✗" : "○";
    public static Color MarkColor(Step s) => s.Ok == true ? Palette.Green : s.Ok == false ? Palette.Red : Palette.Gray;

    /// Список шагов: значок, название, пояснение под ним.
    public static void FillSteps(FlowLayoutPanel panel, IEnumerable<Step> steps, int width)
    {
        panel.SuspendLayout();
        panel.Controls.Clear();
        foreach (var s in steps)
        {
            var title = L($"{Mark(s)}  {s.Title}", Palette.Bold, MarkColor(s), width);
            title.Margin = new Padding(0, 4, 0, 0);
            panel.Controls.Add(title);
            if (s.Detail.Length > 0)
            {
                var d = L(s.Detail, Palette.Small, Palette.Sub, width - 18);
                d.Margin = new Padding(18, 0, 0, 2);
                panel.Controls.Add(d);
            }
        }
        panel.ResumeLayout();
    }
}

/// Верхняя карточка — она же выключатель туннеля.
sealed class Card : Control
{
    public string Title = "", Subtitle = "", Glyph = "";
    public Color Accent = Palette.Gray;
    public bool On, ShowPower = true;

    public Card()
    {
        DoubleBuffered = true;
        Cursor = Cursors.Hand;
        Size = new Size(336, 70);
        Margin = new Padding(0, 6, 0, 6);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        using (var bg = new SolidBrush(Palette.Card))
        using (var path = Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 12))
            g.FillPath(bg, path);
        var circle = new Rectangle(12, (Height - 38) / 2, 38, 38);
        using (var ab = new SolidBrush(Accent)) g.FillEllipse(ab, circle);
        TextRenderer.DrawText(g, Glyph, new Font("Segoe UI", 13f, FontStyle.Bold), circle, Color.White,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        var textWidth = Width - 62 - (ShowPower ? 44 : 10);
        TextRenderer.DrawText(g, Title, Palette.Bold, new Rectangle(62, 12, textWidth, 22), Color.Black,
            TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        TextRenderer.DrawText(g, Subtitle, Palette.Small, new Rectangle(62, 34, textWidth, Height - 36), Palette.Sub,
            TextFormatFlags.Left | TextFormatFlags.WordBreak);
        if (ShowPower)
            TextRenderer.DrawText(g, "", new Font("Segoe MDL2 Assets", 14f), new Rectangle(Width - 46, 0, 36, Height),
                On ? Palette.Green : Palette.Gray, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var d = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

/// Панель над значком: состояние туннеля, проверки, включение по карточке.
sealed class StatusForm : Form
{
    readonly Core core;
    readonly TrayApp app;
    readonly FlowLayoutPanel body = Ui.Column(340);
    const int W = 336;

    public StatusForm(Core core, TrayApp app)
    {
        this.core = core;
        this.app = app;
        Text = "Proxy Tunnel";
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        BackColor = Color.White;
        Padding = new Padding(14);
        Font = Palette.Text;
        Controls.Add(body);
        Deactivate += (_, _) => Hide();
        core.Changed += Rebuild;
        Rebuild();
    }

    public void ShowNearTray()
    {
        Rebuild();
        Show();
        var wa = Screen.PrimaryScreen!.WorkingArea;
        Location = new Point(wa.Right - Width - 12, wa.Bottom - Height - 12);
        Activate();
    }

    void Rebuild()
    {
        if (IsDisposed) return;
        body.SuspendLayout();
        body.Controls.Clear();

        var settings = new LinkLabel { Text = "Настройки", AutoSize = true, Font = Palette.Text };
        settings.LinkClicked += (_, _) => { Hide(); app.ShowSettings(); };
        var log = new LinkLabel { Text = "Журнал", AutoSize = true, Font = Palette.Text };
        log.LinkClicked += (_, _) => app.OpenLog();
        var header = Ui.L("Proxy Tunnel", Palette.Header);
        header.Width = 170;
        body.Controls.Add(Ui.Row(header, settings, log));

        var card = new Card { Width = W };
        if (!core.Config.IsComplete)
        {
            card.Title = "Туннель не настроен";
            card.Subtitle = "Свой сервер за границей: через него идут только Claude и выбранные сайты, остальное — напрямую.";
            card.Glyph = "⚙";
            card.Accent = Palette.Orange;
            card.ShowPower = false;
            card.Cursor = Cursors.Default;
            body.Controls.Add(card);
            var setup = new Button { Text = "Настроить туннель…", Width = W, Height = 34, Font = Palette.Bold };
            setup.Click += (_, _) => { Hide(); app.ShowSettings(); };
            body.Controls.Add(setup);
            if (core.Config.HostT.Length == 0)
            {
                var rent = new LinkLabel { Text = "Нет сервера? Арендовать", AutoSize = true, Font = Palette.Text, Margin = new Padding(0, 8, 0, 0) };
                rent.LinkClicked += (_, _) => Ui.Open(Config.RentServerUrl);
                body.Controls.Add(rent);
            }
        }
        else
        {
            Status(card);
            card.Click += async (_, _) => await core.Toggle();
            body.Controls.Add(card);
            if (core.Enabled && core.Steps.Count > 0)
            {
                var steps = Ui.Column(W);
                Ui.FillSteps(steps, core.Steps, W);
                body.Controls.Add(steps);
            }
        }

        if (core.Message.Length > 0) body.Controls.Add(Ui.L(core.Message, Palette.Small, Palette.Sub, W));

        if (core.Config.IsComplete && core.Enabled)
        {
            var when = Ui.L(core.CheckedAt is { } t && !core.Checking ? $"Проверено в {t:HH:mm}" : "", Palette.Small, Palette.Sub);
            when.Width = 150;
            var reconnect = new LinkLabel { Text = "Переподключить", AutoSize = true, Font = Palette.Text };
            reconnect.LinkClicked += async (_, _) => await core.Reconnect();
            var check = new LinkLabel { Text = "Проверить", AutoSize = true, Font = Palette.Text };
            check.LinkClicked += async (_, _) => await core.Refresh();
            body.Controls.Add(Ui.Row(when, reconnect, check));
        }
        body.ResumeLayout();
        if (Visible)
        {
            var wa = Screen.PrimaryScreen!.WorkingArea;
            Location = new Point(wa.Right - Width - 12, wa.Bottom - Height - 12);
        }
    }

    void Status(Card c)
    {
        c.On = core.Enabled;
        if (!core.Enabled)
        {
            (c.Title, c.Subtitle, c.Glyph, c.Accent) = ("Туннель выключен", "Нажмите, чтобы включить", "–", Palette.Gray);
            return;
        }
        if (core.Checking) { (c.Title, c.Subtitle, c.Glyph, c.Accent) = ("Проверяю…", "", "…", Palette.Gray); return; }
        if (core.VerdictOK)
        {
            var where = core.Steps.Count > 1 ? core.Steps[1].Detail : "";
            (c.Title, c.Subtitle, c.Glyph, c.Accent) = ("Claude — через туннель", where.Length > 0 ? $"выход: {where}" : "", "✓", Palette.Green);
            return;
        }
        if (core.Steps.Count == 0) { (c.Title, c.Subtitle, c.Glyph, c.Accent) = ("Подключаюсь…", "", "…", Palette.Gray); return; }
        if (core.Steps.Count == 4 && core.Steps.Take(3).All(s => s.Ok == true) && core.Steps[3].Ok == false)
        {
            (c.Title, c.Subtitle, c.Glyph, c.Accent) = ("Claude Code — через туннель", "Сайты из списка в браузере — нет, см. ниже", "!", Palette.Orange);
            return;
        }
        (c.Title, c.Subtitle, c.Glyph, c.Accent) = ("Соединение не готово", "Исправьте отмеченное ниже", "✕", Palette.Red);
    }
}

/// Окно настроек: сервер, настройка сервера, доступ к серверу, список сайтов, дополнительно.
sealed class SettingsForm : Form
{
    readonly Core core;
    readonly TrayApp app;
    const int W = 500;

    readonly TextBox host = new() { Width = 280 };
    readonly NumericUpDown sshPort = Num(22);
    readonly LinkLabel rent = new() { Text = "Нет сервера? Подойдёт любой зарубежный VPS на Ubuntu или Debian — арендовать", AutoSize = true, MaximumSize = new Size(W, 0) };

    readonly RadioButton autoMode = new() { Text = "Автоматически", AutoSize = true, Checked = true };
    readonly RadioButton manualMode = new() { Text = "Вручную", AutoSize = true };
    readonly FlowLayoutPanel autoPanel = Ui.Column(W);
    readonly FlowLayoutPanel manualPanel = Ui.Column(W);
    readonly Label access = Ui.L("", Palette.Text, null, W);
    readonly FlowLayoutPanel pwPanel = Ui.Column(W);
    readonly TextBox login = new() { Width = 200, Text = "root" };
    readonly TextBox password = new() { Width = 200, UseSystemPasswordChar = true };
    readonly CheckBox makeKey = new() { Text = "Создать ключ для входа и добавить его на сервер", AutoSize = true, Checked = true };
    readonly Button setupButton = new() { Width = 200, Height = 32, Font = Palette.Bold };
    readonly FlowLayoutPanel setupSteps = Ui.Column(W);
    readonly Label setupDone = Ui.L("", Palette.Text, Palette.Green, W);
    readonly Button createTunnelKey = new() { Text = "Создать ключ туннеля", AutoSize = true };

    readonly FlowLayoutPanel accessSection = Ui.Column(W);
    readonly Label keyState = Ui.L("");
    readonly Label pwState = Ui.L("");
    readonly Button checkConn = new() { Text = "Проверить соединение", AutoSize = true };
    readonly Button disablePw = new() { Text = "Выключить вход по паролю", AutoSize = true };
    readonly FlowLayoutPanel addKeyRow = Ui.Column(W);
    readonly TextBox accessPassword = new() { Width = 200, UseSystemPasswordChar = true };
    readonly Label accessNote = Ui.L("", Palette.Small, Palette.Sub, W);

    readonly TextBox domains = new() { Multiline = true, Width = W, Height = 130, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9.5f) };
    readonly TextBox tunnelUser = new() { Width = 160 };
    readonly NumericUpDown localPort = Num(8888), remotePort = Num(8888), pacPort = Num(8889);
    readonly CheckBox autostart = new() { Text = "Запускать при входе в Windows", AutoSize = true };
    readonly Label note = Ui.L("", Palette.Small, Palette.Sub, W);
    readonly System.Windows.Forms.Timer probeTimer = new() { Interval = 900 };
    bool loaded;

    static NumericUpDown Num(int v) => new() { Minimum = 1, Maximum = 65535, Value = v, Width = 90 };

    public SettingsForm(Core core, TrayApp app)
    {
        this.core = core;
        this.app = app;
        Text = "Настройки Proxy Tunnel";
        Font = Palette.Text;
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(580, 820);
        MinimumSize = new Size(580, 400);
        AutoScroll = true;
        BackColor = Color.White;

        var root = Ui.Column(W + 20);
        root.Padding = new Padding(20, 16, 20, 20);
        Controls.Add(root);

        // 1. Сервер
        root.Controls.Add(Ui.L("1. Сервер", Palette.Header));
        root.Controls.Add(Ui.Row(Ui.Caption("Адрес сервера"), host));
        root.Controls.Add(Ui.Row(Ui.Caption("SSH-порт"), sshPort));
        rent.LinkClicked += (_, _) => Ui.Open(Config.RentServerUrl);
        root.Controls.Add(rent);

        // 2. Настройка сервера
        var h2 = Ui.L("2. Настройка сервера (один раз)", Palette.Header);
        h2.Margin = new Padding(0, 18, 0, 4);
        root.Controls.Add(h2);
        root.Controls.Add(Ui.Row(autoMode, manualMode));
        autoMode.CheckedChanged += (_, _) => Sync();

        autoPanel.Controls.Add(Ui.L("Программа сама зайдёт на сервер (Ubuntu или Debian), поставит прокси и заведёт пользователя, которому разрешён только туннель.", Palette.Text, null, W));
        autoPanel.Controls.Add(access);
        pwPanel.Controls.Add(Ui.Row(Ui.Caption("Логин"), login));
        pwPanel.Controls.Add(Ui.Row(Ui.Caption("Пароль"), password));
        pwPanel.Controls.Add(makeKey);
        pwPanel.Controls.Add(Ui.L("Тогда в следующий раз пароль не понадобится, а вход по паролю можно будет выключить. Пароль нигде не сохраняется.", Palette.Small, Palette.Sub, W));
        autoPanel.Controls.Add(pwPanel);
        setupButton.Click += async (_, _) => await SetupClicked();
        autoPanel.Controls.Add(setupButton);
        autoPanel.Controls.Add(setupSteps);
        autoPanel.Controls.Add(setupDone);
        root.Controls.Add(autoPanel);

        manualPanel.Controls.Add(Ui.L("Если программе на сервер не зайти (вход только через консоль хостинга): скопируйте команду, вставьте её в консоль сервера под root или пользователем с sudo и дождитесь строки «сервер готов». Затем «Сохранить» внизу.", Palette.Text, null, W));
        var copyCmd = new Button { Text = "Скопировать команду для сервера", AutoSize = true };
        copyCmd.Click += (_, _) => CopyCommand();
        createTunnelKey.Click += (_, _) => { var e = Keys.Ensure(Paths.TunnelKey, "proxy-tunnel"); note.Text = e == null ? "Ключ создан. Теперь скопируйте команду для сервера." : "Ключ не создан: " + e; Sync(); };
        manualPanel.Controls.Add(Ui.Row(createTunnelKey, copyCmd));
        root.Controls.Add(manualPanel);

        // Доступ к серверу
        var h3 = Ui.L("Доступ к серверу", Palette.Header);
        h3.Margin = new Padding(0, 18, 0, 4);
        accessSection.Controls.Add(h3);
        accessSection.Controls.Add(Ui.Row(Ui.Caption("Вход по ключу"), keyState));
        accessSection.Controls.Add(Ui.Row(Ui.Caption("Вход по паролю"), pwState));
        checkConn.Click += async (_, _) => await core.CheckConnection();
        disablePw.Click += async (_, _) => await core.DisablePasswordLogin();
        accessSection.Controls.Add(Ui.Row(checkConn, disablePw));
        addKeyRow.Controls.Add(Ui.L("Входа по ключу нет — его можно создать: программа сделает ключ и добавит его на сервер по паролю.", Palette.Small, null, W));
        var addKey = new Button { Text = "Создать ключ и добавить", AutoSize = true };
        addKey.Click += async (_, _) => { var pw = accessPassword.Text; accessPassword.Text = ""; if (pw.Length > 0) await core.AddAdminKeyNow(pw); };
        addKeyRow.Controls.Add(Ui.Row(Ui.Caption("Пароль"), accessPassword, addKey));
        accessSection.Controls.Add(addKeyRow);
        accessSection.Controls.Add(accessNote);
        accessSection.Controls.Add(Ui.L("Выключить вход по паролю можно только когда вход по ключу подтверждён — иначе легко потерять доступ к серверу.", Palette.Small, Palette.Sub, W));
        root.Controls.Add(accessSection);

        // Через туннель
        var h4 = Ui.L("Через туннель", Palette.Header);
        h4.Margin = new Padding(0, 18, 0, 4);
        root.Controls.Add(h4);
        root.Controls.Add(domains);
        root.Controls.Add(Ui.L("В браузере и приложении Claude через туннель идут только эти сайты; остальные открываются напрямую, как без туннеля, — сайт, которого нет в списке, через туннель не пойдёт. По одному домену в строке, поддомены включаются. Claude Code ходит через туннель целиком, кроме российских доменов.", Palette.Small, Palette.Sub, W));

        // Дополнительно
        var h5 = Ui.L("Дополнительно", Palette.Header);
        h5.Margin = new Padding(0, 18, 0, 4);
        root.Controls.Add(h5);
        root.Controls.Add(Ui.Row(Ui.Caption("Пользователь туннеля"), tunnelUser));
        root.Controls.Add(Ui.Row(Ui.Caption("Порт туннеля на компьютере"), localPort));
        root.Controls.Add(Ui.Row(Ui.Caption("Порт прокси на сервере"), remotePort));
        root.Controls.Add(Ui.Row(Ui.Caption("Порт PAC"), pacPort));
        var forget = new Button { Text = "Забыть ключ сервера…", AutoSize = true };
        forget.Click += (_, _) =>
        {
            if (MessageBox.Show(this,
                    "Это нужно, только если сервер переустановили и программа пишет, что ключ сервера изменился. При следующем подключении программа примет ключ сервера заново — если в этот момент кто-то подменит сервер, подмену она не заметит.",
                    "Забыть ключ сервера?", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK)
            {
                core.ForgetHostKey();
                note.Text = core.Message;
            }
        };
        root.Controls.Add(forget);

        autostart.Margin = new Padding(0, 14, 0, 4);
        autostart.CheckedChanged += (_, _) => { if (!loaded) return; try { Autostart.On = autostart.Checked; } catch (Exception e) { note.Text = "Автозапуск: " + e.Message; } };
        root.Controls.Add(autostart);

        var save = new Button { Text = "Сохранить", AutoSize = true, Font = Palette.Bold };
        save.Click += (_, _) => Save();
        var cancel = new Button { Text = "Отменить", AutoSize = true };
        cancel.Click += (_, _) => LoadFromConfig();
        root.Controls.Add(Ui.Row(save, cancel));
        root.Controls.Add(note);
        var quit = new LinkLabel { Text = "Выйти из Proxy Tunnel", AutoSize = true, LinkColor = Palette.Red, Margin = new Padding(0, 14, 0, 0) };
        quit.LinkClicked += (_, _) => app.Quit();
        root.Controls.Add(quit);
        root.Controls.Add(Ui.L("Туннель закроется, прокси для Claude и браузера снимутся.", Palette.Small, Palette.Sub, W));

        // фоновая проверка входа по ключу — через секунду после того, как адрес или порт перестали меняться
        host.TextChanged += (_, _) => { if (loaded) { probeTimer.Stop(); probeTimer.Start(); } Sync(); };
        sshPort.ValueChanged += (_, _) => { if (loaded) { probeTimer.Stop(); probeTimer.Start(); } };
        probeTimer.Tick += async (_, _) => { probeTimer.Stop(); await core.ProbeAccess(Draft()); };

        FormClosing += (_, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
        core.Changed += Sync;
        LoadFromConfig();
    }

    /// Показ окна: сохранённые настройки подставляются, только если в окне нет несохранённых правок.
    public void ShowWindow()
    {
        if (!Edited()) LoadFromConfig();
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        if (Draft().HostT.Length > 0) _ = core.ProbeAccess(Draft());
    }

    bool Edited() =>
        System.Text.Json.JsonSerializer.Serialize(Draft()) != System.Text.Json.JsonSerializer.Serialize(Clean(core.Config));

    static Config Clean(Config c)
    {
        var x = c.Clone();
        x.Host = x.HostT;
        x.Domains = x.CleanDomains();
        return x;
    }

    Config Draft()
    {
        var c = core.Config.Clone();
        c.Host = host.Text.Trim();
        c.SshPort = (int)sshPort.Value;
        c.User = tunnelUser.Text.Trim().Length > 0 ? tunnelUser.Text.Trim() : "tunnel";
        c.AdminUser = login.Text.Trim().Length > 0 ? login.Text.Trim() : c.AdminUser;
        c.LocalPort = (int)localPort.Value;
        c.RemotePort = (int)remotePort.Value;
        c.PacPort = (int)pacPort.Value;
        c.Domains = domains.Lines.ToList();
        c.Domains = c.CleanDomains();
        return c;
    }

    void LoadFromConfig()
    {
        loaded = false;
        var c = core.Config;
        host.Text = c.Host;
        sshPort.Value = Math.Clamp(c.SshPort, 1, 65535);
        login.Text = c.AdminT;
        tunnelUser.Text = c.User;
        localPort.Value = Math.Clamp(c.LocalPort, 1, 65535);
        remotePort.Value = Math.Clamp(c.RemotePort, 1, 65535);
        pacPort.Value = Math.Clamp(c.PacPort, 1, 65535);
        domains.Lines = c.Domains.ToArray();
        try { autostart.Checked = Autostart.On; } catch { }
        note.Text = "";
        loaded = true;
        Sync();
    }

    void Save()
    {
        var c = Draft();
        core.Apply(c);
        domains.Lines = c.Domains.ToArray();
        note.Text = c.IsComplete ? "Сохранено. Туннель переподключается." : "Сохранено. Для подключения нужен настроенный сервер.";
    }

    bool AlreadySetUp => core.Config.IsComplete && host.Text.Trim() == core.Config.HostT;

    async Task SetupClicked()
    {
        if (host.Text.Trim().Length == 0)
        {
            // без адреса — коротко подсветить поле адреса и поставить в него курсор
            host.Focus();
            host.BackColor = Color.MistyRose;
            await Task.Delay(900);
            host.BackColor = SystemColors.Window;
            return;
        }
        if (AlreadySetUp && MessageBox.Show(this,
                "Прокси на сервере поставится заново, его настройки перезапишутся. Ключи и вход на сервер не пропадут, но туннель прервётся на несколько секунд. Нужно, если туннель перестал работать или сервер переустановили.",
                "Сервер уже настроен", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        var pw = core.Access == AccessState.NeedPassword ? password.Text : "";
        note.Text = "";
        await core.SetupServer(Draft(), pw, makeKey.Checked);
        if (core.SetupDone) password.Text = "";
        LoadFromConfig();
    }

    void CopyCommand()
    {
        var pub = Keys.Public(Paths.TunnelKey);
        if (pub == null) { note.Text = "Сначала создайте ключ туннеля."; return; }
        try
        {
            Clipboard.SetText(Ssh.ManualCommand(Draft(), pub).Replace("\n", "\r\n"));
            note.Text = "Команда скопирована. Вставьте её в консоль сервера, дождитесь «сервер готов», затем «Сохранить».";
        }
        catch (Exception e) { note.Text = "Не скопировалось: " + e.Message; }
    }

    /// Обновить видимость и надписи по состоянию программы.
    void Sync()
    {
        if (IsDisposed) return;
        SuspendLayout();
        rent.Visible = core.Config.HostT.Length == 0;
        autoPanel.Visible = autoMode.Checked;
        manualPanel.Visible = manualMode.Checked;
        createTunnelKey.Visible = !File.Exists(Paths.TunnelKey);

        var hostSet = host.Text.Trim().Length > 0;
        (access.Text, access.ForeColor) = !hostSet ? ("", Palette.Sub) : core.Access switch
        {
            AccessState.Checking => ("Проверяю вход по ключу…", Palette.Sub),
            AccessState.Key => ("✓ " + core.AccessText, Palette.Green),
            AccessState.NeedPassword => ("🔑 " + core.AccessText, Palette.Orange),
            AccessState.Failed => ("✗ " + core.AccessText, Palette.Red),
            _ => ("", Palette.Sub)
        };
        access.Visible = access.Text.Length > 0;
        pwPanel.Visible = core.Access == AccessState.NeedPassword;
        setupButton.Text = core.SetupBusy ? "Настраиваю…" : AlreadySetUp ? "Настроить заново…" : "Настроить сервер";
        setupButton.Enabled = !core.SetupBusy && (!hostSet || core.Access == AccessState.Key ||
                              (core.Access == AccessState.NeedPassword && password.Text.Length > 0) || core.Access == AccessState.Failed);
        Ui.FillSteps(setupSteps, core.SetupSteps, W);
        setupSteps.Visible = core.SetupSteps.Count > 0;
        setupDone.Text = core.SetupDone ? "Готово. Туннель включён — перезапустите Claude, если он был открыт." : "";
        setupDone.Visible = core.SetupDone;

        accessSection.Visible = core.Config.IsComplete;
        (keyState.Text, keyState.ForeColor) = core.KeyStable switch
        {
            null => ("не проверен", Palette.Sub),
            true => (core.KeyCheckedHow.Length == 0 ? "стабилен, 3 из 3" : $"работает ({core.KeyCheckedHow})", Palette.Green),
            false => ("не прошёл", Palette.Red)
        };
        (pwState.Text, pwState.ForeColor) = core.PasswordLogin switch
        {
            null => ("неизвестно", Palette.Sub),
            true => ("включён", Palette.Orange),
            false => ("выключен", Palette.Green)
        };
        checkConn.Enabled = !core.AccessBusy;
        disablePw.Enabled = !core.AccessBusy && core.KeyStable == true && core.PasswordLogin != false;
        addKeyRow.Visible = core.KeyDenied || (core.Access == AccessState.NeedPassword && !core.SetupBusy && core.Config.IsComplete);
        accessNote.Text = core.AccessNote;
        accessNote.Visible = core.AccessNote.Length > 0;
        ResumeLayout();
    }
}

/// Значок у часов: левый щелчок — панель, правый — меню.
public sealed class TrayApp : ApplicationContext
{
    readonly Core core;
    readonly NotifyIcon icon;
    readonly StatusForm status;
    SettingsForm? settings;
    readonly Dictionary<string, Icon> icons = new();
    bool quitting;

    public TrayApp()
    {
        core = new Core();
        status = new StatusForm(core, this);
        var menu = new ContextMenuStrip();
        menu.Items.Add("Открыть", null, (_, _) => status.ShowNearTray());
        menu.Items.Add("Настройки…", null, (_, _) => ShowSettings());
        menu.Items.Add("Журнал", null, (_, _) => OpenLog());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Выйти", null, (_, _) => Quit());
        icon = new NotifyIcon { Visible = true, Text = "Proxy Tunnel", ContextMenuStrip = menu };
        icon.MouseClick += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            if (status.Visible) status.Hide(); else status.ShowNearTray();
        };
        core.Changed += UpdateIcon;
        UpdateIcon();
        Application.ApplicationExit += (_, _) => { if (!quitting) core.Shutdown(); };
        Microsoft.Win32.SystemEvents.SessionEnding += (_, _) => core.Shutdown();

        _ = core.StartServices();   // туннель при запуске выключен — снимет настройки, оставшиеся после аварийного закрытия
        if (core.Config.IsComplete) status.ShowNearTray();   // сразу показать панель: включают по карточке
        else ShowSettings();
    }

    public void ShowSettings()
    {
        settings ??= new SettingsForm(core, this);
        settings.ShowWindow();
    }

    public void OpenLog()
    {
        if (!File.Exists(Paths.LogFile)) Log.Append("журнал создан");
        Ui.Open(Paths.LogFile);
    }

    public void Quit()
    {
        quitting = true;
        core.Shutdown();
        icon.Visible = false;
        ExitThread();
    }

    void UpdateIcon()
    {
        string state;
        if (!core.Config.IsComplete) state = "setup";
        else if (!core.Enabled) state = "off";
        else if (core.VerdictOK) state = "ok";
        else if (core.Steps.Count == 4 && core.Steps.Take(3).All(s => s.Ok == true)) state = "partial";
        else if (core.Steps.Count == 0) state = "off";
        else state = "fail";
        icon.Icon = Make(state);
        icon.Text = state switch
        {
            "ok" => "Proxy Tunnel — Claude через туннель",
            "off" => "Proxy Tunnel — выключен",
            "setup" => "Proxy Tunnel — не настроен",
            "partial" => "Proxy Tunnel — Claude Code через туннель",
            _ => "Proxy Tunnel — соединение не готово"
        };
    }

    Icon Make(string state)
    {
        if (icons.TryGetValue(state, out var ic)) return ic;
        var (color, glyph) = state switch
        {
            "ok" => (Palette.Green, "✓"),
            "partial" => (Palette.Orange, "!"),
            "fail" => (Palette.Red, "✕"),
            "setup" => (Palette.Orange, "?"),
            _ => (Palette.Gray, "")
        };
        using var b = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(b))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);
            using var br = new SolidBrush(color);
            g.FillEllipse(br, 2, 2, 28, 28);
            if (glyph.Length > 0)
            {
                using var f = new Font("Segoe UI", 15f, FontStyle.Bold, GraphicsUnit.Pixel);
                var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(glyph, f, Brushes.White, new RectangleF(0, 0, 32, 32), sf);
            }
            else
            {
                using var pen = new Pen(Color.White, 3f);
                g.DrawLine(pen, 10, 16, 22, 16);
            }
        }
        ic = Icon.FromHandle(b.GetHicon());
        icons[state] = ic;
        return ic;
    }
}

static class Program
{
    [STAThread]
    static void Main()
    {
        using var mutex = new Mutex(true, "ProxyTunnel-single-instance", out var first);
        if (!first)
        {
            MessageBox.Show("Proxy Tunnel уже запущен — его значок возле часов.", "Proxy Tunnel");
            return;
        }
        ApplicationConfiguration.Initialize();
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        Application.Run(new TrayApp());
    }
}
