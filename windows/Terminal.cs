// codex и gemini в терминале — через туннель (Windows). По смыслу — menubar/Terminal.swift версии для Mac.
//
// Терминальные программы не читают системный прокси (PAC): им нужен HTTPS_PROXY. Программа кладёт в свою папку
// (%APPDATA%\Proxy Tunnel\bin) обёртки codex.cmd и gemini.cmd — для cmd, PowerShell, Windows Terminal и терминала
// VS Code — и такие же скрипты без расширения для Git Bash, а папку ставит первой в PATH пользователя. Обёртка находит
// настоящую программу дальше по PATH и запускает её с HTTPS_PROXY из файла cli-proxy в папке программы. Файл есть,
// пока туннель включён, и убирается при выключении и выходе — уже открытые окна узнают о переключении сразу.
// Туннель включён, а соединение упало — отказ соединения, а не прямой выход. PATH подхватывают окна, открытые после
// включения.
//
// Профиль PowerShell не трогаем: на многих Windows выполнение скриптов PowerShell запрещено, профиль не загрузится.
// VS Code на Windows не покрыт: расширение Codex запускает программу без оболочки, а Node так не запускает .cmd;
// окружение из оболочки VS Code на Windows не читает.
// Тексты в обёртках — латиницей: cmd выводит кириллицу в чужой кодировке.
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace ProxyTunnel;

public static class CliProxy
{
    public static string BinDir => Path.Combine(Paths.Dir, "bin");
    public static string StateFile => Path.Combine(Paths.Dir, "cli-proxy");
    const string EnvKey = "Environment";
    static readonly string[] Names = { "codex", "gemini" };

    // MARK: обёртки

    public static string CmdWrapper(string name) => string.Join("\r\n", new[]
    {
        "@echo off",
        $"rem Proxy Tunnel: {name} goes through the tunnel while it is on. Written by Proxy Tunnel, removed by its checkbox.",
        "setlocal",
        "set \"PT_SELF=%~dp0\"",
        "set \"PT_REAL=\"",
        $"for /f \"delims=\" %%i in ('where {name}.cmd {name}.exe {name}.bat 2^>nul') do call :pick \"%%i\"",
        "if not defined PT_REAL goto missing",
        "set \"PT_STATE=%~dp0..\\cli-proxy\"",
        "if not exist \"%PT_STATE%\" goto run",
        "set /p PT_PROXY=<\"%PT_STATE%\"",
        "set \"HTTPS_PROXY=%PT_PROXY%\"",
        "set \"https_proxy=%PT_PROXY%\"",
        "set \"NO_PROXY=localhost,127.0.0.1,::1\"",
        "set \"no_proxy=localhost,127.0.0.1,::1\"",
        ":run",
        "call \"%PT_REAL%\" %*",
        "exit /b %ERRORLEVEL%",
        ":pick",
        "if defined PT_REAL goto :eof",
        "if /i \"%~dp1\"==\"%PT_SELF%\" goto :eof",
        "set \"PT_REAL=%~1\"",
        "goto :eof",
        ":missing",
        $"echo Proxy Tunnel: {name} not found in PATH 1>&2",
        "exit /b 9009",
        ""
    });

    public static string ShWrapper(string name) => string.Join("\n", new[]
    {
        "#!/bin/sh",
        $"# Proxy Tunnel: {name} goes through the tunnel while it is on (Git Bash). Written by Proxy Tunnel, removed by its checkbox.",
        "self_dir=$(cd \"$(dirname \"$0\")\" && pwd)",
        "real=\"\"",
        "old_ifs=$IFS; IFS=:",
        "for d in $PATH; do",
        "  [ \"$d\" = \"$self_dir\" ] && continue",
        $"  if [ -f \"$d/{name}\" ]; then real=\"$d/{name}\"; break; fi",
        "done",
        "IFS=$old_ifs",
        $"[ -z \"$real\" ] && {{ echo \"Proxy Tunnel: {name} not found in PATH\" >&2; exit 127; }}",
        "state=\"$self_dir/../cli-proxy\"",
        "if [ -s \"$state\" ]; then",
        "  p=$(cat \"$state\")",
        "  export HTTPS_PROXY=\"$p\" https_proxy=\"$p\" NO_PROXY=\"localhost,127.0.0.1,::1\" no_proxy=\"localhost,127.0.0.1,::1\"",
        "fi",
        "exec \"$real\" \"$@\"",
        ""
    });

    static bool WriteIfChanged(string path, string text)
    {
        var bytes = new UTF8Encoding(false).GetBytes(text);
        if (File.Exists(path) && File.ReadAllBytes(path).SequenceEqual(bytes)) return false;
        File.WriteAllBytes(path, bytes);
        return true;
    }

    static void Delete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }

    // MARK: PATH пользователя

    static string? UserPath()
    {
        using var k = Registry.CurrentUser.OpenSubKey(EnvKey);
        return k?.GetValue("Path", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
    }

    static bool Same(string a, string b) =>
        string.Equals(Environment.ExpandEnvironmentVariables(a.Trim()).TrimEnd('\\'), b.TrimEnd('\\'),
                      StringComparison.OrdinalIgnoreCase);

    /// Папка обёрток — первая в PATH пользователя (до папки npm, где лежат настоящие codex и gemini).
    public static bool FirstOnPath() =>
        (UserPath() ?? "").Split(';').FirstOrDefault(x => x.Trim().Length > 0) is { } f && Same(f, BinDir);

    static void SetUserPath(bool ours)
    {
        using var k = Registry.CurrentUser.CreateSubKey(EnvKey);
        var cur = k.GetValue("Path", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? "";
        var kind = k.GetValueNames().Any(v => v.Equals("Path", StringComparison.OrdinalIgnoreCase))
            ? k.GetValueKind("Path") : RegistryValueKind.ExpandString;
        var rest = cur.Split(';').Where(x => x.Trim().Length > 0 && !Same(x, BinDir)).ToList();
        if (ours) rest.Insert(0, BinDir);
        var next = string.Join(";", rest);
        if (next == cur) return;
        if (next.Length == 0) k.DeleteValue("Path", false);
        else k.SetValue("Path", next, kind == RegistryValueKind.String ? RegistryValueKind.String : RegistryValueKind.ExpandString);
        Log.Append(ours ? $"Терминал: {BinDir} — первой в PATH пользователя" : "Терминал: папка обёрток убрана из PATH");
        // Сказать Windows, что окружение изменилось: новые окна терминала возьмут новый PATH.
        Task.Run(() => SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, "Environment", 0x0002, 2000, out _));
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout,
                                            out UIntPtr result);

    // MARK: установка

    static bool Want(Config c, string name) => name == "codex" ? c.CodexCLI : c.GeminiCLI;

    /// Обёртки под включённые галочки и папка в PATH; ни одной галочки — всё убирается.
    public static void Install(Config c)
    {
        var any = Names.Any(n => Want(c, n));
        if (!any) { Uninstall(); return; }
        Directory.CreateDirectory(BinDir);
        foreach (var n in Names)
        {
            var cmd = Path.Combine(BinDir, n + ".cmd");
            var sh = Path.Combine(BinDir, n);
            if (Want(c, n))
            {
                if (WriteIfChanged(cmd, CmdWrapper(n)) | WriteIfChanged(sh, ShWrapper(n)))
                    Log.Append($"Терминал: обёртка {n} записана в {BinDir}");
            }
            else { Delete(cmd); Delete(sh); }
        }
        if (!FirstOnPath()) SetUserPath(true);
    }

    public static void Uninstall()
    {
        foreach (var n in Names) { Delete(Path.Combine(BinDir, n + ".cmd")); Delete(Path.Combine(BinDir, n)); }
        SetUserPath(false);
    }

    public static bool Installed(Config c) =>
        FirstOnPath() && Names.Where(n => Want(c, n)).All(n =>
            File.Exists(Path.Combine(BinDir, n + ".cmd")) && File.Exists(Path.Combine(BinDir, n)));

    /// Адрес прокси для обёрток; null — туннель выключен, codex и gemini идут напрямую.
    public static void SetState(string? proxy)
    {
        try
        {
            if (proxy == null) { Delete(StateFile); return; }
            if (File.Exists(StateFile) && File.ReadAllText(StateFile) == proxy) return;
            File.WriteAllText(StateFile, proxy);
        }
        catch { }
    }

    public static string? State() { try { return File.Exists(StateFile) ? File.ReadAllText(StateFile) : null; } catch { return null; } }

    // MARK: есть ли codex и gemini на компьютере

    /// Настоящая программа где-то в PATH (без папки обёрток) или в папке npm.
    public static bool Detected(string name)
    {
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';')
            .Concat(new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm") })
            .Where(d => d.Trim().Length > 0 && !Same(d, BinDir));
        return dirs.Any(d => new[] { ".cmd", ".exe", ".bat" }.Any(ext =>
        {
            try { return File.Exists(Path.Combine(d.Trim(), name + ext)); } catch { return false; }
        }));
    }
}
