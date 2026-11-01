// Работа с сервером от имени админа: вход по ключу или паролю, скрипты из server/, проверки доступа.
// Пароль передаётся ssh через SSH_ASKPASS (OpenSSH ≥ 8.4) и нигде не сохраняется.
import Foundation

/// Скрипты сервера, вложенные в приложение при сборке (build.sh кладёт server/*.sh в Resources).
enum ServerScript {
    static func text(_ name: String = "setup") -> String? {
        Bundle.main.url(forResource: name, withExtension: "sh").flatMap { try? String(contentsOf: $0) }
    }

    /// Переменные для setup.sh как строка «KEY='…' …».
    static func env(_ c: Config, publicKey: String) -> String {
        "TUNNEL_USER=\(sq(c.user)) PROXY_PORT=\(c.remotePort) PUBKEY=\(sq(publicKey))"
    }

    /// Команда для ручной вставки в консоль сервера: работает и под root, и под пользователем с sudo.
    static func manualCommand(_ c: Config, publicKey: String) -> String? {
        guard let s = text() else { return nil }
        return "sudo env \(env(c, publicKey: publicKey)) bash <<'PROXYTUNNEL'\n\(s)\nPROXYTUNNEL\n"
    }
}

func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Как админ входит на сервер.
enum AdminAuth {
    case key(String?)        // nil — свои ключи из ~/.ssh, агент и ключ входа, созданный приложением
    case password(String)
}

enum ProbeResult: Equatable {
    case root, sudo            // можно настраивать
    case noSudo                // вошли, но прав не хватает
    case denied                // не пустили (ключ не подошёл / неверный пароль)
    case refused               // сервер отклонил само подключение — обычно ограничение частоты (ufw limit)
    case failed(String)        // сервер не отвечает, сменился ключ сервера и т. п.

    var canAdmin: Bool { self == .root || self == .sudo }
}

/// Запускает ssh с данными на stdin и дополнительным окружением; возвращает код выхода и весь вывод.
func runSSH(_ args: [String], env extra: [String: String] = [:], stdin: String? = nil,
            timeout: Double = 600) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
                env.removeValue(forKey: k)
            }
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env.merge(extra) { $1 }
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let inp = Pipe()
            p.standardInput = inp
            do { try p.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription))
                return
            }
            if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)) }
            try? inp.fileHandleForWriting.close()
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
    }
}

enum ServerSetup {
    /// Ключи, которые ssh пробует сам, — но только пока не задан ни один -i. Задаём их явно.
    static var defaultIdentities: [String] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return ["id_ed25519", "id_ecdsa", "id_rsa", "id_ed25519_sk", "id_ecdsa_sk"]
            .map { ssh.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Общее соединение для команд админа. На серверах бывает ограничение частоты подключений к ssh
    /// (ufw limit: 6 за 30 секунд с одного адреса, дальше — отказ), а настройка — это несколько команд подряд.
    /// Путь короткий: у сокета предел ~104 байта, временная папка macOS для него слишком длинная.
    static let controlPath = "/tmp/pt-%C"

    /// Общие параметры ssh для входа админом: тот же known_hosts, что у туннеля, и тот же интерфейс.
    /// shared — через общее соединение (команды); без него — отдельный вход (когда проверяем сам вход).
    static func baseArgs(_ c: Config, auth: AdminAuth, shared: Bool = false) -> [String] {
        var a = ["-F", "none", "-T",
                 "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=20", "-o", "LogLevel=ERROR",
                 "-o", "UserKnownHostsFile=\"\(Config.knownHostsURL.path)\"",
                 "-o", "StrictHostKeyChecking=accept-new",
                 "-p", String(c.sshPort)]
        let iface = c.effectiveInterface
        if !iface.isEmpty { a += ["-o", "BindInterface=\(iface)"] }
        a += shared ? ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=60"]
                    : ["-o", "ControlPath=none"]
        switch auth {
        case .key(let path):
            a += ["-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey"]
            if let p = path {
                a += ["-i", p, "-o", "IdentitiesOnly=yes"]
            } else {
                var ids = defaultIdentities
                if FileManager.default.fileExists(atPath: Config.adminKeyPath) { ids.insert(Config.adminKeyPath, at: 0) }
                for p in ids { a += ["-i", p] }
            }
        case .password:
            a += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                  "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        }
        return a
    }

    /// Пароль для ssh: временный askpass-скрипт печатает его из окружения ssh, файл удаляется сразу после.
    static func withPassword<T>(_ auth: AdminAuth, _ body: ([String: String]) async -> T) async -> T {
        guard case .password(let pw) = auth else { return await body([:]) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let helper = dir.appendingPathComponent("askpass")
        try? "#!/bin/sh\nprintf '%s\\n' \"$PT_ASKPASS_SECRET\"\n".write(to: helper, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: dir) }
        return await body(["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force",
                           "DISPLAY": ":0", "PT_ASKPASS_SECRET": pw])
    }

    /// Команда на сервере от имени админа: stdin — текст скрипта или nil. По умолчанию — через общее соединение.
    static func exec(_ c: Config, admin: String, auth: AdminAuth, _ cmd: String, stdin: String? = nil,
                     shared: Bool = true, timeout: Double = 600) async -> (Int32, String) {
        await withPassword(auth) { env in
            await runSSH(baseArgs(c, auth: auth, shared: shared) + c.sshDest(admin) + [cmd],
                         env: env, stdin: stdin, timeout: timeout)
        }
    }

    /// Закрывает общее соединение (после настройки по паролю оно не должно висеть).
    static func closeShared(_ c: Config, admin: String) async {
        _ = await runSSH(["-F", "none", "-o", "ControlPath=\(controlPath)", "-p", String(c.sshPort),
                          "-O", "exit"] + c.sshDest(admin), timeout: 10)
    }

    /// Понятная причина отказа ssh.
    static func explain(_ out: String, code: Int32) -> String {
        let s = out.lowercased()
        if s.contains("identification has changed") {
            return "Ключ сервера изменился (сервер переустановлен?). Нажмите «Забыть ключ сервера» в «Дополнительно» и повторите."
        }
        if s.contains("change your password") || s.contains("password has expired") || s.contains("password change required") {
            return "Сервер требует сменить пароль при первом входе. Войдите один раз через консоль хостинга, смените пароль и повторите."
        }
        if s.contains("permission denied") { return "Вход не прошёл: неверный логин, пароль или ключ." }
        if s.contains("connection refused") {
            return "Сервер отклонил подключение к ssh. Если перед этим было много подключений подряд, подождите полминуты и повторите (на сервере может стоять ограничение частоты подключений); иначе проверьте порт."
        }
        if s.contains("timed out") || s.contains("no route")
            || s.contains("could not resolve") || s.contains("network is unreachable") {
            return "Сервер не отвечает по ssh: проверьте адрес и порт."
        }
        if s.contains("bindinterface") || s.contains("can't assign requested address") {
            return "Не удалось выйти через интерфейс из «Дополнительно» — проверьте его или очистите поле."
        }
        if code == -1 || code == 15 { return "ssh не ответил за отведённое время." }
        let last = out.split(separator: "\n").last.map(String.init) ?? ""
        return last.isEmpty ? "ssh завершился с кодом \(code)" : last
    }

    static func scriptError(_ out: String, code: Int32) -> String {
        if let e = out.split(separator: "\n").first(where: { $0.hasPrefix("PT-ERROR:") }) {
            return String(e.dropFirst("PT-ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return explain(out, code: code)
    }

    /// Пробует войти и узнать, хватит ли прав на настройку.
    /// shared = false — отдельный вход: так проверяется, что пускает именно этот ключ или пароль.
    /// shared = true — удачный вход остаётся общим соединением для следующих команд настройки.
    static func probe(_ c: Config, admin: String, auth: AdminAuth, shared: Bool = false) async -> ProbeResult {
        let cmd = "if [ \"$(id -u)\" = 0 ]; then echo PT-ROOT; elif sudo -n true 2>/dev/null; then echo PT-SUDO; else echo PT-NOSUDO; fi"
        let (code, out) = await exec(c, admin: admin, auth: auth, cmd, shared: shared, timeout: 40)
        if out.contains("PT-ROOT") { return .root }
        if out.contains("PT-SUDO") { return .sudo }
        if out.contains("PT-NOSUDO") { return .noSudo }
        Log.append("вход \(admin)@\(c.hostTrimmed): код \(code)\n\(out)")
        if code == 255 && out.lowercased().contains("permission denied") { return .denied }
        if out.lowercased().contains("connection refused") { return .refused }
        return .failed(explain(out, code: code))
    }

    /// Запускает скрипт из server/ под root (или через sudo); nil — успех, иначе причина.
    static func runScript(_ name: String, _ c: Config, admin: String, auth: AdminAuth, root: Bool,
                          env: String = "", success: String) async -> String? {
        guard let script = ServerScript.text(name) else { return "В приложении нет скрипта \(name).sh — пересоберите его build.sh." }
        let remote = (root ? "" : "sudo -n ") + "env \(env) bash -s"
        let (code, out) = await exec(c, admin: admin, auth: auth, remote, stdin: script)
        Log.append("\(name).sh на \(c.hostTrimmed): код \(code)\n\(out)")
        if code == 0 && out.contains(success) { return nil }
        return scriptError(out, code: code)
    }

    static func install(_ c: Config, admin: String, auth: AdminAuth, root: Bool, publicKey: String) async -> String? {
        await runScript("setup", c, admin: admin, auth: auth, root: root,
                        env: ServerScript.env(c, publicKey: publicKey), success: "сервер готов")
    }

    static func disablePassword(_ c: Config, admin: String, root: Bool) async -> String? {
        await runScript("no-password", c, admin: admin, auth: .key(nil), root: root, success: "вход по паролю выключен")
    }

    /// Добавляет публичный ключ админу в ~/.ssh/authorized_keys (под его же входом); nil — успех.
    static func addAdminKey(_ c: Config, admin: String, auth: AdminAuth, publicKey: String) async -> String? {
        let k = sq(publicKey)
        let cmd = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
            "(grep -qxF \(k) ~/.ssh/authorized_keys || echo \(k) >> ~/.ssh/authorized_keys) && echo PT-OK"
        let (code, out) = await exec(c, admin: admin, auth: auth, cmd, timeout: 40)
        Log.append("ключ входа для \(admin)@\(c.hostTrimmed): код \(code)\n\(out)")
        return out.contains("PT-OK") ? nil : explain(out, code: code)
    }

    /// Включён ли вход по паролю в sshd (по sshd -T на сервере); nil — не удалось узнать.
    static func passwordEnabled(_ c: Config, admin: String, root: Bool) async -> Bool? {
        let cmd = (root ? "" : "sudo -n ") + "sshd -T 2>/dev/null | grep -i '^passwordauthentication '"
        let (_, out) = await exec(c, admin: admin, auth: .key(nil), cmd, timeout: 40)
        let s = out.lowercased()
        if s.contains("passwordauthentication yes") { return true }
        if s.contains("passwordauthentication no") { return false }
        return nil
    }

    /// Снаружи: предлагает ли сервер вход по паролю. Ответ ssh «Permission denied (publickey,password)».
    static func serverOffersPassword(_ c: Config, admin: String) async -> Bool? {
        var a = baseArgs(c, auth: .password(""))
        a += ["-o", "BatchMode=yes"] + c.sshDest(admin) + ["true"]
        let (_, out) = await runSSH(a, timeout: 40)
        guard let r = out.range(of: "Permission denied ("),
              let end = out[r.upperBound...].firstIndex(of: ")") else { return nil }
        let methods = out[r.upperBound..<end]
        return methods.contains("password") || methods.contains("keyboard-interactive")
    }
}
