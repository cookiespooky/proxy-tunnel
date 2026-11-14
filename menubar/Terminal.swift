// Codex и Gemini в терминале, расширения VS Code — через туннель.
//
// Терминальные программы не читают список сайтов (PAC): им нужен HTTPS_PROXY. Программа вписывает в файлы,
// которые читает терминал, блок между метками: команды codex и gemini берут адрес прокси из файла cli-proxy
// в папке программы. Файл есть, пока туннель включён, и убирается при выключении и выходе — так уже открытые окна
// терминала узнают о включении и выключении без перезапуска. Туннель включён, но соединение упало — команды
// получают отказ соединения, а не идут напрямую.
//
// VS Code — два способа, каждый своей галочкой:
// - «Codex в VS Code»: расширение openai.chatgpt запускает codex само, мимо терминала. В настройках VS Code
//   (chatgpt.cliExecutable — служебная настройка расширения) ему подставляется посредник codex-vscode: он находит
//   codex, встроенный в самую новую версию расширения, и запускает его с HTTPS_PROXY из cli-proxy.
// - «Весь VS Code»: при запуске из Dock VS Code берёт переменные окружения из оболочки и ставит при этом
//   VSCODE_RESOLVING_ENVIRONMENT. Блок в этот момент выставляет HTTPS_PROXY, если туннель включён, — его получают
//   все расширения (Gemini, Copilot и любые), загрузки VS Code и команды в его терминале. Действует до перезапуска VS Code.
//
// Флаг Codex respect_system_proxy (~/.codex/config.toml) не ставим: с ним Codex 0.169 берёт прокси только из системы
// и HTTPS_PROXY не слушает — проверено 14.11, запросы шли мимо туннеля. Если флаг включил сам человек, проверка
// об этом говорит. Gemini CLI берёт прокси только из HTTPS_PROXY — проверено на 0.68.
import Foundation

enum CLIProxy {
    static let begin = "# >>> Proxy Tunnel >>>"
    static let end = "# <<< Proxy Tunnel <<<"

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var stateURL: URL { Config.supportDir.appendingPathComponent("cli-proxy") }
    private static let statePath = "$HOME/Library/Application Support/Proxy Tunnel/cli-proxy"

    /// Что вписывать в файлы терминала.
    struct Shell: Equatable {
        var codex = false, gemini = false, vscodeAll = false
        var any: Bool { codex || gemini || vscodeAll }
    }

    static func block(_ o: Shell) -> String {
        var l = [begin,
                 "# Вписано программой Proxy Tunnel и убирается ею же — галочками в её настройках.",
                 "# Пока туннель включён, программы ниже идут через него, выключен — напрямую."]
        if o.codex || o.gemini {
            l += ["__proxy_tunnel() {",
                  "  local f=\"\(statePath)\" p",
                  "  if [ -s \"$f\" ]; then",
                  "    p=$(cat \"$f\")",
                  "    HTTPS_PROXY=\"$p\" https_proxy=\"$p\" NO_PROXY=\"localhost,127.0.0.1,::1\" no_proxy=\"localhost,127.0.0.1,::1\" command \"$@\"",
                  "  else",
                  "    command \"$@\"",
                  "  fi",
                  "}"]
            if o.codex { l.append("function codex { __proxy_tunnel codex \"$@\"; }") }
            if o.gemini { l.append("function gemini { __proxy_tunnel gemini \"$@\"; }") }
        }
        if o.vscodeAll {
            l += ["# Весь VS Code: переменные берутся при его запуске из Dock.",
                  "if [ -n \"$VSCODE_RESOLVING_ENVIRONMENT\" ] && [ -s \"\(statePath)\" ]; then",
                  "  export HTTPS_PROXY=\"$(cat \"\(statePath)\")\"",
                  "  export https_proxy=\"$HTTPS_PROXY\" NO_PROXY=\"localhost,127.0.0.1,::1\" no_proxy=\"localhost,127.0.0.1,::1\"",
                  "fi"]
        }
        l.append(end)
        return l.joined(separator: "\n")
    }

    // MARK: файлы терминала

    /// zsh — всегда (оболочка macOS по умолчанию). bash — первый из файлов, которые он читает при входе:
    /// новый ~/.bash_profile рядом с ~/.profile отключил бы ~/.profile, поэтому создаём его, только если нет ни одного.
    static func rcFiles() -> [URL] {
        let fm = FileManager.default
        var r = [home.appendingPathComponent(".zshrc")]
        let bash = [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
        if let first = bash.first(where: { fm.fileExists(atPath: $0.path) }) {
            r.append(first)
        } else if loginShell().hasSuffix("/bash") {
            r.append(bash[0])
        }
        return r
    }

    static func loginShell() -> String {
        guard let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell else { return "" }
        return String(cString: sh)
    }

    /// Текст без нашего блока (и без пустой строки, которую мы ставим перед ним).
    static func strip(_ text: String) -> String {
        var out: [Substring] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == begin {
                inside = true
                if out.last?.isEmpty == true { out.removeLast() }
                continue
            }
            if inside { if line == end { inside = false }; continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Пишет через символическую ссылку (файлы настроек часто — ссылки в репозиторий dotfiles), а не вместо неё.
    private static func rewrite(_ url: URL, _ change: (String) -> String) throws {
        let real = url.resolvingSymlinksInPath()
        let old = (try? String(contentsOf: real, encoding: .utf8)) ?? ""
        let new = change(old)
        guard new != old else { return }
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: real, atomically: true, encoding: .utf8)
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8)) ?? ""
    }

    static func installed(_ o: Shell) -> Bool {
        rcFiles().allSatisfy { read($0).contains(block(o)) }
    }

    /// Ставит блок под нужные галочки; ни одной — убирает.
    static func install(_ o: Shell) throws {
        guard o.any else { uninstall(); return }
        guard !installed(o) else { return }
        for f in rcFiles() {
            try rewrite(f) { old in
                var s = strip(old)
                if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
                return s + (s.isEmpty ? "" : "\n") + block(o) + "\n"
            }
        }
        Log.append("Терминал: блок Proxy Tunnel вписан в \(rcFiles().map(\.lastPathComponent).joined(separator: ", "))")
    }

    static func uninstall() {
        let had = rcFiles().contains { read($0).contains(begin) }
        for f in rcFiles() { try? rewrite(f, strip) }
        if had { Log.append("Терминал: блок Proxy Tunnel убран") }
    }

    /// Адрес прокси для терминала и VS Code; nil — туннель выключен, они идут напрямую.
    static func setState(_ proxy: String?) {
        if let p = proxy {
            if (try? String(contentsOf: stateURL, encoding: .utf8)) != p { try? p.write(to: stateURL, atomically: true, encoding: .utf8) }
        } else {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    static func state() -> String? { try? String(contentsOf: stateURL, encoding: .utf8) }

    // MARK: Codex и Gemini на этом компьютере

    static var codexDir: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return home.appendingPathComponent(".codex")
    }
    static var codexConfig: URL { codexDir.appendingPathComponent("config.toml") }

    private static func binaryInstalled(_ name: String) -> Bool {
        let fm = FileManager.default
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
        dirs += [".npm-global/bin", ".local/bin", ".bun/bin", ".volta/bin"].map { home.appendingPathComponent($0) }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        dirs += ((try? fm.contentsOfDirectory(atPath: nvm.path)) ?? []).map { nvm.appendingPathComponent("\($0)/bin") }
        return dirs.contains { fm.fileExists(atPath: $0.appendingPathComponent(name).path) }
    }

    /// Codex в терминале есть: установлен в обычное место. Папка ~/.codex бывает и от расширения VS Code — она не в счёт.
    static func codexDetected() -> Bool { binaryInstalled("codex") }
    /// Gemini — установленная программа или его настоящие файлы (вход, настройки), а не любая папка ~/.gemini.
    static func geminiDetected() -> Bool {
        let g = home.appendingPathComponent(".gemini")
        return binaryInstalled("gemini")
            || ["settings.json", "oauth_creds.json"].contains { FileManager.default.fileExists(atPath: g.appendingPathComponent($0).path) }
    }

    /// Человек сам включил respect_system_proxy — тогда Codex не слушает HTTPS_PROXY и идёт мимо туннеля.
    static func codexIgnoresEnv() -> Bool {
        read(codexConfig).split(separator: "\n").contains { l in
            let s = l.replacingOccurrences(of: " ", with: "")
            return s == "respect_system_proxy=true" || s == "features.respect_system_proxy=true"
        }
    }

    // MARK: VS Code

    static var vscodeSettings: URL { home.appendingPathComponent("Library/Application Support/Code/User/settings.json") }
    static var vscodeExtensions: URL { home.appendingPathComponent(".vscode/extensions") }
    static var codexWrapper: URL { Config.supportDir.appendingPathComponent("codex-vscode") }
    static let vscodeKey = "chatgpt.cliExecutable"
    static let vscodeMark = "// Proxy Tunnel: Codex расширения — через туннель (убирается галочкой «Codex в VS Code»)"

    static func vscodeInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Visual Studio Code.app")
            || FileManager.default.fileExists(atPath: vscodeExtensions.path)
    }

    static func codexExtensionInstalled() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: vscodeExtensions.path)) ?? []).contains { $0.hasPrefix("openai.chatgpt-") }
    }

    static var wrapperScript: String {
        """
        #!/bin/sh
        # Proxy Tunnel: Codex расширения VS Code — через туннель, пока он включён. Вписан программой Proxy Tunnel
        # (галочка «Codex в VS Code»): запускает codex, встроенный в самую новую версию расширения.
        real=$(ls -td "$HOME"/.vscode/extensions/openai.chatgpt-*/bin/*/codex 2>/dev/null | head -1)
        if [ -z "$real" ]; then echo "Proxy Tunnel: не найден codex расширения openai.chatgpt" >&2; exit 127; fi
        f="\(statePath)"
        if [ -s "$f" ]; then
          p=$(cat "$f")
          export HTTPS_PROXY="$p" https_proxy="$p" NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
        fi
        exec "$real" "$@"

        """
    }

    struct VSCodeSettingsBusy: LocalizedError {
        let value: String
        var errorDescription: String? { "в настройках VS Code уже задан \(vscodeKey) = \(value) — не трогаю его" }
    }

    /// Значение chatgpt.cliExecutable в настройках VS Code (строкой, как записано), nil — не задано.
    static func vscodeCodexValue() -> String? {
        let t = read(vscodeSettings)
        guard let r = t.range(of: "\"\(vscodeKey)\"") else { return nil }
        let rest = t[r.upperBound...].drop { $0 == " " || $0 == ":" || $0 == "\t" }
        guard rest.first == "\"" else { return String(rest.prefix(40)) }
        return String(rest.dropFirst().prefix { $0 != "\"" })
    }

    static func vscodeCodexOn() -> Bool {
        vscodeCodexValue() == codexWrapper.path && FileManager.default.isExecutableFile(atPath: codexWrapper.path)
    }

    /// Строка вставляется сразу после «{» вместе с пометкой: настройки VS Code — JSON с комментариями,
    /// поэтому файл не разбирается и не переписывается целиком.
    static func enableVSCodeCodex() throws {
        let fm = FileManager.default
        if read(codexWrapper) != wrapperScript {
            try wrapperScript.write(to: codexWrapper, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexWrapper.path)
        if let v = vscodeCodexValue() {
            if v == codexWrapper.path { return }
            throw VSCodeSettingsBusy(value: v)
        }
        let line = "  \"\(vscodeKey)\": \"\(codexWrapper.path)\""
        try rewrite(vscodeSettings) { old in
            let t = old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{\n}\n" : old
            guard let open = t.firstIndex(of: "{") else { return old }
            let after = t[t.index(after: open)...]
            let empty = after.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
            let ins = "\n  \(vscodeMark)\n" + line + (empty ? "\n" : ",")
            return String(t[...open]) + ins + String(after)
        }
        Log.append("VS Code: Codex расширения — через посредник \(codexWrapper.path)")
    }

    /// Убирает только свою строку и пометку над ней; посредника оставляет — VS Code мог ещё не перечитать настройки.
    static func disableVSCodeCodex() {
        guard vscodeCodexValue() == codexWrapper.path else { return }
        try? rewrite(vscodeSettings) { old in
            // Убираем саму запись (с запятой после неё, если есть), а не строку целиком: на строке может быть ещё что-то.
            let entry = "\"\(vscodeKey)\": \"\(codexWrapper.path)\""
            var lines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == vscodeMark }
            lines = lines.compactMap { l in
                guard l.contains(entry) else { return l }
                let rest = l.replacingOccurrences(of: entry + ",", with: "").replacingOccurrences(of: entry, with: "")
                return rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest
            }
            return lines.joined(separator: "\n")
        }
        Log.append("VS Code: Codex расширения — снова напрямую")
    }

    /// Окружение запущенных процессов: есть ли у них наш прокси. nil — таких процессов нет.
    static func processesUseProxy(matching needle: String, proxy: String) -> Bool? {
        let (_, out) = Net.runSync("/bin/ps", ["-axww", "-E", "-o", "command="])
        let lines = out.split(separator: "\n").filter { $0.contains(needle) && !$0.contains("/bin/ps ") }
        guard !lines.isEmpty else { return nil }
        return lines.allSatisfy { $0.contains("HTTPS_PROXY=\(proxy)") }
    }
}
