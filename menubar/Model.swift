// Режим (туннель / VPN), проверки по шагам, применение настроек.
import SwiftUI
import ServiceManagement

enum StepState { case pending, running, ok, fail }

struct Step: Identifiable {
    let id: Int
    let title: String
    var state: StepState = .pending
    var detail = ""
}

func makeSteps(_ titles: [String]) -> [Step] {
    titles.enumerated().map { Step(id: $0.offset, title: $0.element) }
}

/// Запускает команду без прокси в окружении и возвращает код выхода и вывод.
func run(_ args: [String]) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
            var env = ProcessInfo.processInfo.environment
            for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"] {
                env.removeValue(forKey: k)
            }
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
    }
}

func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res, let sa = r.pointee.ai_addr else { return nil }
    defer { freeaddrinfo(res) }
    var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
    let ip = String(cString: buf)
    return ip.hasPrefix("198.18.") ? nil : ip   // поддельный DNS VPN-клиента — не настоящий адрес
}

/// ~/.claude/settings.json: трогаем только env.HTTPS_PROXY и env.NO_PROXY.
enum ClaudeSettings {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    struct Unreadable: LocalizedError {
        var errorDescription: String? { "~/.claude/settings.json не читается как JSON — не трогаю его" }
    }

    static func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unreadable() }
        return d
    }

    static func proxy() -> String? {
        ((try? load())?["env"] as? [String: Any])?["HTTPS_PROXY"] as? String
    }

    static func set(proxy: String?, host: String) throws {
        var d = try load()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        var env = d["env"] as? [String: Any] ?? [:]
        if let p = proxy {
            env["HTTPS_PROXY"] = p
            env["NO_PROXY"] = "localhost,127.0.0.1,::1,.ru,.xn--p1ai,\(host)"
        } else {
            env.removeValue(forKey: "HTTPS_PROXY")
            env.removeValue(forKey: "NO_PROXY")
        }
        if env.isEmpty { d.removeValue(forKey: "env") } else { d["env"] = env }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

let tunnelSteps = ["Туннель подключён", "Выход через туннель", "PAC включён", "PAC раздаётся", "Прокси в Claude Code"]

@MainActor
final class Model: ObservableObject {
    static var current: Model?

    @Published var config: Config
    @Published var mode = "?"            // tunnel | happ | mixed
    @Published var steps: [Step] = makeSteps(tunnelSteps)
    @Published var verdictOK = false
    @Published var directLoc = ""
    @Published var busy = false
    @Published var checking = false
    @Published var message = ""
    @Published var checkedAt: Date?
    private var work: [Step] = []
    private var quiet = false
    let tunnel = Tunnel()
    let pac = PacServer()

    init() {
        config = Config.load()
        Model.current = self
        Task { await self.startServices() }
        if !config.isComplete {
            // Первый запуск: сразу открыть настройки с шагами.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                SettingsWindow.show(self)
            }
        }
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self else { return }
                self.refresh(quiet: true)
            }
        }
    }

    var icon: String {
        if !config.isComplete { return "questionmark.circle" }
        switch mode {
        case "tunnel": return verdictOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
        case "vpn": return "shield.lefthalf.filled"
        default: return "questionmark.circle"
        }
    }

    /// Запускает PAC и туннель по текущим настройкам; старый ssh на том же пробросе гасит.
    func startServices() async {
        pac.start(port: config.pacPort, text: config.pacText)
        tunnel.stop()
        _ = await run(["/usr/bin/pkill", "-f", "--", "ssh -N -F none .*-L \(config.forwardSpec) "])
        if config.isComplete { tunnel.start(config) }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        refresh()
    }

    func apply(_ c: Config) {
        let wasTunnel = (mode == "tunnel")
        config = c
        do { try c.save() } catch { message = "Настройки не сохранились: \(error.localizedDescription)" }
        Task {
            if wasTunnel, let e = await applyTunnelMode() { message = e }
            await startServices()
        }
    }

    // MARK: режимы

    private func pacState() async -> (String, Bool) {
        let (_, out) = await run(["/usr/sbin/networksetup", "-getautoproxyurl", config.networkService])
        var url = "", on = false
        for line in out.split(separator: "\n") {
            if line.hasPrefix("URL: ") { url = String(line.dropFirst(5)) }
            if line.hasPrefix("Enabled: ") { on = line.hasSuffix("Yes") }
        }
        return (url, on)
    }

    private func detectMode() async {
        let cc = ClaudeSettings.proxy()
        let (url, on) = await pacState()
        if cc == config.proxyURL && on && url == config.pacURL { mode = "tunnel" }
        else if cc == nil && !on { mode = "vpn" }
        else { mode = "mixed" }
    }

    private func applyTunnelMode() async -> String? {
        do { try ClaudeSettings.set(proxy: config.proxyURL, host: config.hostTrimmed) }
        catch { return error.localizedDescription }
        let a = await run(["/usr/sbin/networksetup", "-setautoproxyurl", config.networkService, config.pacURL])
        let b = await run(["/usr/sbin/networksetup", "-setautoproxystate", config.networkService, "on"])
        if a.0 != 0 || b.0 != 0 { return "Не удалось включить PAC: " + (a.1 + b.1).trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    private func applyVPNMode() async -> String? {
        do { try ClaudeSettings.set(proxy: nil, host: config.hostTrimmed) }
        catch { return error.localizedDescription }
        let b = await run(["/usr/sbin/networksetup", "-setautoproxystate", config.networkService, "off"])
        if b.0 != 0 { return "Не удалось выключить PAC: " + b.1.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    func setMode(_ target: String) {
        guard target != mode, !busy else { return }
        if target == "tunnel" && !config.isComplete {
            message = "Сначала укажите сервер и ключ в настройках."
            return
        }
        busy = true
        message = ""
        Task {
            let err = target == "tunnel" ? await applyTunnelMode() : await applyVPNMode()
            busy = false
            message = err ?? "Перезапустите программы, которые ходят через туннель (например, Claude), чтобы они подхватили режим."
            refresh()
        }
    }

    func reconnect() {
        guard !busy else { return }
        message = "Переподключаю туннель…"
        Task {
            await startServices()
            message = ""
        }
    }

    // MARK: проверки

    /// quiet — фоновая проверка: окошко не мигает, результат появляется целиком в конце.
    func refresh(quiet: Bool = false) {
        guard !busy else { return }
        busy = true
        self.quiet = quiet
        if !quiet { checking = true }
        Task {
            await detectMode()
            if !config.isComplete {
                work = [Step(id: 0, title: "Настройки", state: .fail,
                             detail: "Укажите сервер и ключ: «Настройки…»")]
                verdictOK = false
            } else if mode == "vpn" {
                await checkVPN()
            } else {
                await checkTunnel()
            }
            steps = work
            checkedAt = Date()
            checking = false
            busy = false
        }
    }

    private func step(_ i: Int, _ ok: Bool, _ detail: String = "") async {
        work[i].state = ok ? .ok : .fail
        work[i].detail = detail
        if i + 1 < work.count { work[i + 1].state = .running }
        publish()
        if !quiet { try? await Task.sleep(nanoseconds: 150_000_000) }   // чтобы шаги было видно
    }

    private func publish() {
        if !quiet { steps = work }
    }

    private func checkTunnel() async {
        work = makeSteps(tunnelSteps)
        work[0].state = .running
        publish()
        if !quiet { try? await Task.sleep(nanoseconds: 150_000_000) }

        let port = await run(["/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", String(config.localPort)]).0 == 0
        let t1: String
        if !tunnel.running { t1 = tunnel.lastError.isEmpty ? "ssh не запущен" : tunnel.lastError }
        else if !port { t1 = "порт \(config.localPort) не отвечает" }
        else { t1 = "" }
        await step(0, tunnel.running && port, t1)

        let (_, trace) = await run(["/usr/bin/curl", "-s", "-x", config.proxyURL, "--max-time", "10",
                                    "https://claude.ai/cdn-cgi/trace"])
        var ip = "", loc = ""
        for line in trace.split(separator: "\n") {
            if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
            if line.hasPrefix("loc=") { loc = String(line.dropFirst(4)) }
        }
        let host = config.hostTrimmed
        let expected = await Task.detached { resolveIPv4(host) }.value
        let ipOK = !ip.isEmpty && loc != "RU" && (expected == nil || ip == expected)
        var t2 = ip.isEmpty ? "нет ответа" : "\(ip), \(loc)"
        if !ip.isEmpty && !ipOK, let e = expected { t2 += " — ожидался \(e)" }
        await step(1, ipOK, t2)

        let (url, on) = await pacState()
        await step(2, on && url == config.pacURL, on ? (url == config.pacURL ? "" : "другой PAC: \(url)") : "выключен")

        let (_, pacBody) = await run(["/usr/bin/curl", "-s", "--noproxy", "*", "--max-time", "3", config.pacURL])
        let served = pacBody.contains("PROXY 127.0.0.1:\(config.localPort)")
        await step(3, served, served ? "" : (pac.error.isEmpty ? "не отвечает — браузер пойдёт напрямую" : pac.error))

        let cc = ClaudeSettings.proxy()
        await step(4, cc == config.proxyURL, cc == config.proxyURL ? "" : "не задан — Claude Code пойдёт напрямую")

        verdictOK = mode == "tunnel" && work.allSatisfy { $0.state == .ok }
    }

    private func checkVPN() async {
        work = makeSteps(["VPN подключён"])
        work[0].state = .running
        publish()
        let (_, out) = await run(["/bin/bash", "-c",
            "curl -s --noproxy '*' --max-time 5 https://claude.ai/cdn-cgi/trace | sed -n 's/^loc=//p'"])
        directLoc = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !directLoc.isEmpty && directLoc != "RU"
        await step(0, ok, ok ? "выход: \(directLoc)" : "claude.ai не отвечает — включите VPN")
        verdictOK = ok
    }

    // MARK: ключ и прочее

    func generateKey() async -> String? {
        let path = config.keyPath
        guard !FileManager.default.fileExists(atPath: path) else { return nil }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let (code, out) = await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "proxy-tunnel",
                                     "-f", path])
        return code == 0 ? nil : out
    }

    func publicKey(for path: String) -> String? {
        (try? String(contentsOfFile: path + ".pub"))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func forgetHostKey() {
        try? FileManager.default.removeItem(at: Config.knownHostsURL)
        message = "Ключ сервера забыт — при следующем подключении запомнится заново."
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: Config.logURL.path) { Log.append("журнал создан") }
        NSWorkspace.shared.open(Config.logURL)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = "Автозапуск: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
