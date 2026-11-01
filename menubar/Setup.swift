// Настройка сервера из приложения: вход под админом (по ключу или паролю) и запуск server/setup.sh.
// Пароль передаётся ssh через SSH_ASKPASS (OpenSSH ≥ 8.4) и нигде не сохраняется.
import Foundation

/// Скрипт сервера, вложенный в приложение при сборке (build.sh кладёт server/setup.sh в Resources).
enum ServerScript {
    static var text: String? {
        Bundle.main.url(forResource: "setup", withExtension: "sh").flatMap { try? String(contentsOf: $0) }
    }

    /// Переменные для скрипта как строка «KEY='…' …».
    static func env(_ c: Config, publicKey: String) -> String {
        "TUNNEL_USER=\(sq(c.user)) PROXY_PORT=\(c.remotePort) PUBKEY=\(sq(publicKey))"
    }

    /// Команда для ручной вставки в консоль сервера: работает и под root, и под пользователем с sudo.
    static func manualCommand(_ c: Config, publicKey: String) -> String? {
        guard let s = text else { return nil }
        return "sudo env \(env(c, publicKey: publicKey)) bash <<'PROXYTUNNEL'\n\(s)\nPROXYTUNNEL\n"
    }
}

func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Как админ может войти на сервер.
enum AdminAuth {
    case key(String?)        // nil — ключи по умолчанию из ~/.ssh и агент
    case password(String)
}

enum ProbeResult: Equatable {
    case root, sudo            // можно настраивать
    case noSudo                // вошли, но прав не хватает
    case denied                // ключ не подошёл
    case failed(String)        // сервер не отвечает, сменился ключ сервера и т. п.
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
    /// Общие параметры ssh для входа админом: тот же known_hosts, что у туннеля, и тот же интерфейс.
    static func baseArgs(_ c: Config, auth: AdminAuth) -> [String] {
        var a = ["-F", "none", "-T",
                 "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=20", "-o", "LogLevel=ERROR",
                 "-o", "UserKnownHostsFile=\"\(Config.knownHostsURL.path)\"",
                 "-o", "StrictHostKeyChecking=accept-new",
                 "-p", String(c.sshPort)]
        let iface = c.interface.trimmingCharacters(in: .whitespaces)
        if !iface.isEmpty { a += ["-o", "BindInterface=\(iface)"] }
        switch auth {
        case .key(let path):
            a += ["-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey"]
            if let p = path { a += ["-i", p, "-o", "IdentitiesOnly=yes"] }
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
        if s.contains("timed out") || s.contains("no route") || s.contains("connection refused")
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

    /// Пробует войти и узнать, хватит ли прав на настройку.
    static func probe(_ c: Config, admin: String, auth: AdminAuth) async -> ProbeResult {
        let cmd = "if [ \"$(id -u)\" = 0 ]; then echo PT-ROOT; elif sudo -n true 2>/dev/null; then echo PT-SUDO; else echo PT-NOSUDO; fi"
        let (code, out) = await withPassword(auth) { env in
            await runSSH(baseArgs(c, auth: auth) + ["\(admin)@\(c.hostTrimmed)", cmd], env: env, timeout: 40)
        }
        if out.contains("PT-ROOT") { return .root }
        if out.contains("PT-SUDO") { return .sudo }
        if out.contains("PT-NOSUDO") { return .noSudo }
        Log.append("вход \(admin)@\(c.hostTrimmed): код \(code)\n\(out)")
        if code == 255 && out.lowercased().contains("permission denied") { return .denied }
        return .failed(explain(out, code: code))
    }

    /// Запускает скрипт сервера; nil — успех, иначе причина.
    static func install(_ c: Config, admin: String, auth: AdminAuth, root: Bool, publicKey: String) async -> String? {
        guard let script = ServerScript.text else { return "В приложении нет скрипта сервера — пересоберите его build.sh." }
        let remote = (root ? "" : "sudo -n ") + "env \(ServerScript.env(c, publicKey: publicKey)) bash -s"
        let (code, out) = await withPassword(auth) { env in
            await runSSH(baseArgs(c, auth: auth) + ["\(admin)@\(c.hostTrimmed)", remote], env: env, stdin: script)
        }
        Log.append("настройка сервера \(c.hostTrimmed): код \(code)\n\(out)")
        if code == 0 && out.contains("сервер готов") { return nil }
        if let e = out.split(separator: "\n").first(where: { $0.hasPrefix("PT-ERROR:") }) {
            return String(e.dropFirst("PT-ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return explain(out, code: code)
    }
}
