// Туннель для Claude: системные настройки, проверки по шагам, настройка сервера.
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

let tunnelSteps = ["Туннель подключён", "Выход через туннель", "Claude Code → туннель", "Браузер и приложение Claude → туннель"]

@MainActor
final class Model: ObservableObject {
    static var current: Model?

    @Published var config: Config
    /// Прокси для Claude Code и PAC включены — система ходит к выбранным доменам через туннель.
    /// Включаются сами, как только сервер настроен; снимаются при выходе из приложения.
    @Published var applied = false
    /// Туннель включён пользователем (нажатием на верхнюю карточку). При запуске приложения — выключен.
    @Published var enabled = false
    @Published var steps: [Step] = []
    @Published var verdictOK = false
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
            // Первый запуск: сразу открыть настройки.
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
        guard config.isComplete else { return "questionmark.circle" }
        guard enabled else { return "shield.slash" }
        return verdictOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    /// Нажатие на верхнюю карточку: включить или выключить туннель.
    func toggleTunnel() {
        guard config.isComplete, !busy else { return }
        enabled.toggle()
        message = enabled ? "" : "Туннель выключен: Claude Code и браузер ходят напрямую. Перезапустите Claude Code, если он открыт."
        Task { await startServices() }
    }

    /// Запускает PAC и туннель по текущим настройкам; старый ssh на том же пробросе гасит.
    /// Туннель выключен — гасит его и снимает системные настройки (в том числе оставшиеся после аварийного закрытия).
    func startServices() async {
        tunnel.stop()
        _ = await run(["/usr/bin/pkill", "-f", "--", "ssh -N -F none .*-L \(config.forwardSpec) "])
        guard config.isComplete && enabled else {
            pac.stop()
            await removeSystemSettings()
            steps = []
            verdictOK = false
            checkedAt = nil
            return
        }
        pac.start(port: config.pacPort, text: config.pacText)
        if config.isComplete {
            await Net.prepare(config.hostTrimmed, interface: config.effectiveInterface)
            tunnel.start(config)
            if let e = await applySystemSettings() { message = e }
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        refresh()
    }

    func apply(_ c: Config) {
        config = c
        do { try c.save() } catch { message = "Настройки не сохранились: \(error.localizedDescription)" }
        Task { await startServices() }
    }

    // MARK: системные настройки: прокси для Claude Code и PAC

    // PAC — на всех включённых сетевых службах, VPN тоже: подключённый VPN становится основной службой, и macOS
    // берёт настройки прокси у него, а не у Wi-Fi. Служба с чужим включённым PAC не трогается. Прежнее состояние
    // каждой изменённой службы запоминается в pac-services.json и возвращается при выходе.

    struct PacPrior: Codable { var url: String; var enabled: Bool }
    nonisolated static var pacStateURL: URL { Config.supportDir.appendingPathComponent("pac-services.json") }
    /// Службы, где уже включён чужой PAC — их не трогаем, проверка о них говорит.
    @Published var foreignPAC: [String] = []

    nonisolated static func services() -> [String] {
        let (_, out) = Net.runSync("/usr/sbin/networksetup", ["-listallnetworkservices"])
        return out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    nonisolated static func autoProxy(_ svc: String) -> (url: String, on: Bool) {
        let (_, out) = Net.runSync("/usr/sbin/networksetup", ["-getautoproxyurl", svc])
        var url = "", on = false
        for line in out.split(separator: "\n") {
            if line.hasPrefix("URL: ") { url = String(line.dropFirst(5)) }
            if line.hasPrefix("Enabled: ") { on = line.hasSuffix("Yes") }
        }
        return (url, on)
    }

    nonisolated static func loadPriors() -> [String: PacPrior] {
        (try? Data(contentsOf: pacStateURL)).flatMap { try? JSONDecoder().decode([String: PacPrior].self, from: $0) } ?? [:]
    }

    /// Ставит PAC на службы, где его ещё нет. changed — хоть одну службу поменяли.
    nonisolated static func applyPAC(_ url: String) -> (changed: Bool, foreign: [String], error: String?) {
        var priors = loadPriors()
        var changed = false, foreign: [String] = [], errors: [String] = []
        for svc in services() {
            let cur = autoProxy(svc)
            if cur.on && cur.url == url { continue }
            if cur.on { foreign.append(svc); continue }
            if priors[svc] == nil { priors[svc] = PacPrior(url: cur.url, enabled: false) }
            let a = Net.runSync("/usr/sbin/networksetup", ["-setautoproxyurl", svc, url])
            let b = Net.runSync("/usr/sbin/networksetup", ["-setautoproxystate", svc, "on"])
            if a.0 == 0 && b.0 == 0 { changed = true } else { errors.append("\(svc): \((a.1 + b.1).trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        if let d = try? JSONEncoder().encode(priors) { try? d.write(to: pacStateURL, options: .atomic) }
        if !changed && errors.isEmpty { Log.append("PAC: все службы уже на туннеле") }
        return (changed, foreign, errors.isEmpty ? nil : "Не удалось включить PAC — " + errors.joined(separator: "; "))
    }

    /// Возвращает прежнее состояние тем службам, где стоит наш PAC.
    nonisolated static func removePAC(_ url: String) {
        let priors = loadPriors()
        for svc in services() {
            let cur = autoProxy(svc)
            guard cur.url == url else { continue }
            let p = priors[svc] ?? PacPrior(url: "(null)", enabled: false)
            if p.url != url && p.url != "(null)" && !p.url.isEmpty {
                _ = Net.runSync("/usr/sbin/networksetup", ["-setautoproxyurl", svc, p.url])
            }
            _ = Net.runSync("/usr/sbin/networksetup", ["-setautoproxystate", svc, p.enabled ? "on" : "off"])
        }
        try? FileManager.default.removeItem(at: pacStateURL)
    }

    /// Включает прокси для Claude Code и PAC на всех службах, если чего-то нет (сбросили, появился новый VPN).
    private func applySystemSettings() async -> String? {
        let ccWasSet = ClaudeSettings.proxy() == config.proxyURL
        if !ccWasSet {
            do { try ClaudeSettings.set(proxy: config.proxyURL, host: config.hostTrimmed) }
            catch { return error.localizedDescription }
        }
        let url = config.pacURL
        let r = await Task.detached { Model.applyPAC(url) }.value
        foreignPAC = r.foreign
        if !applied || !ccWasSet {
            message = "Туннель включён для Claude. Перезапустите Claude, если он был открыт."
        }
        applied = true
        return r.error
    }

    /// Выключение туннеля: снять прокси для Claude Code и вернуть службам прежний PAC.
    func removeSystemSettings() async {
        if ClaudeSettings.proxy() == config.proxyURL { try? ClaudeSettings.set(proxy: nil, host: config.hostTrimmed) }
        let url = config.pacURL
        await Task.detached { Model.removePAC(url) }.value
        applied = false
    }

    /// При выходе из приложения: снять прокси для Claude Code и вернуть службам прежний PAC.
    /// Синхронно — приложение уже закрывается.
    func removeSystemSettingsSync() {
        if ClaudeSettings.proxy() == config.proxyURL { try? ClaudeSettings.set(proxy: nil, host: config.hostTrimmed) }
        Model.removePAC(config.pacURL)
        applied = false
    }

    func reconnect() {
        guard !busy, enabled else { return }
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
        guard config.isComplete && enabled else { steps = []; verdictOK = false; return }
        busy = true
        self.quiet = quiet
        if !quiet { checking = true }
        Task {
            if let e = await applySystemSettings() { message = e }
            await checkTunnel()
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
        var t1: String
        if !tunnel.running { t1 = tunnel.lastError.isEmpty ? "ssh не запущен" : tunnel.lastError }
        else if !port { t1 = "порт \(config.localPort) не отвечает" }
        else { t1 = await tunnelRoute() }
        await step(0, tunnel.running && port, t1)

        // Доказательство для всего, что идёт через прокси: claude.ai видит адрес сервера, а не VPN и не Россию.
        let (ip, loc) = await traceViaTunnel()
        let host = config.hostTrimmed
        let expected = await Task.detached { Net.cached(host) ?? (Net.isIP(host) ? host : resolveIPv4(host)) }.value
        let ipOK = !ip.isEmpty && loc != "RU" && (expected == nil || ip == expected)
        var t2 = ip.isEmpty ? "нет ответа" : "\(ip), \(loc)"
        if !ip.isEmpty && !ipOK, let e = expected { t2 += " — ожидался \(e)" }
        await step(1, ipOK, t2)

        // Claude Code берёт прокси из своих настроек — VPN на это не влияет.
        let cc = ClaudeSettings.proxy()
        await step(2, cc == config.proxyURL, cc == config.proxyURL ? "прокси в ~/.claude/settings.json" : "прокси не задан — Claude Code пойдёт мимо туннеля")

        // Браузер и приложение Claude берут прокси из системы. Смотрим не настройку Wi-Fi, а то, что система
        // применяет на самом деле: VPN-клиент в режиме TUN становится основным интерфейсом, и PAC Wi-Fi игнорируется.
        let (_, eff) = await run(["/usr/sbin/scutil", "--proxy"])
        func flag(_ k: String) -> Bool { eff.contains("\(k) : 1") }
        let pacOn = flag("ProxyAutoConfigEnable") && eff.contains("ProxyAutoConfigURLString : \(config.pacURL)")
        let manual = flag("HTTPEnable") || flag("HTTPSEnable") || flag("SOCKSEnable")
        let (_, pacBody) = await run(["/usr/bin/curl", "-s", "--noproxy", "*", "--max-time", "3", config.pacURL])
        let served = pacBody.contains("PROXY 127.0.0.1:\(config.localPort)")
        let viaVPN = await defaultRouteIsVPN()
        let t4: String
        if !pacOn {
            t4 = viaVPN
                ? "Включён VPN, и система не применяет PAC: браузер и приложение Claude идут через VPN, а не через туннель. Выключите VPN — Claude Code при этом и так идёт через туннель."
                : (foreignPAC.isEmpty ? "Система не применяет PAC туннеля"
                   : "На службе «\(foreignPAC.joined(separator: "», «"))» уже стоит другой PAC — приложение его не трогает")
        } else if manual {
            t4 = "В системе включён ещё и обычный прокси (VPN-клиент?) — браузер может пойти через него"
        } else if !served {
            t4 = pac.error.isEmpty ? "PAC не раздаётся — эти сайты не откроются" : pac.error
        } else {
            t4 = "через PAC; остальные сайты — напрямую"
        }
        await step(3, pacOn && !manual && served, t4)

        verdictOK = work.allSatisfy { $0.state == .ok }
    }

    // MARK: настройка сервера из приложения

    enum Access: Equatable {
        case idle, checking
        case key(root: Bool)        // админ входит по ключу — пароль не нужен
        case needPassword           // ни один ключ не подошёл
        case failed(String)
    }

    /// Фоновая проверка входа по ключу: идёт, как только в настройках указан адрес.
    @Published var access: Access = .idle
    private var probeGen = 0

    @Published var setupSteps: [Step] = []
    @Published var setupBusy = false
    @Published var setupDone = false
    /// Вошли по паролю — после настройки напомнить, что вход по паролю на сервере остался включён.
    @Published var setupByPassword = false

    // «Доступ к серверу» после настройки
    @Published var accessBusy = false
    @Published var keyStable: Bool?        // три входа по ключу подряд прошли
    @Published var passwordLogin: Bool?    // сервер принимает вход по паролю
    @Published var accessNote = ""
    /// Сервер именно не принял ключ (а не отклонил подключение) — тогда предлагаем создать ключ.
    @Published var keyDenied = false
    /// Вход по ключу известен по настройке (одна проверка), а не по кнопке «Проверить соединение» (три подряд).
    @Published var keyVerifiedBySetup = false
    private var adminIsRoot = true

    func probeAccess(_ c: Config) async {
        probeGen += 1
        let gen = probeGen
        guard !c.hostTrimmed.isEmpty else { access = .idle; return }
        access = .checking
        await Net.prepare(c.hostTrimmed, interface: c.effectiveInterface)
        let r = await ServerSetup.probe(c, admin: c.adminTrimmed, auth: c.adminAuth)
        guard gen == probeGen else { return }   // адрес успели поменять
        access = Model.access(from: r, admin: c.adminTrimmed)
    }

    private static func access(from r: ProbeResult, admin: String) -> Access {
        switch r {
        case .root: return .key(root: true)
        case .sudo: return .key(root: false)
        case .noSudo: return .failed("\(admin) входит по ключу, но без sudo без пароля. Укажите логин root.")
        case .denied: return .needPassword
        case .refused: return .failed(ServerSetup.explain("connection refused", code: 255))
        case .failed(let e): return .failed(e)
        }
    }

    private func setupStep(_ i: Int, _ ok: Bool, _ detail: String = "", next: Bool = true) {
        setupSteps[i].state = ok ? .ok : .fail
        setupSteps[i].detail = detail
        if ok && next && i + 1 < setupSteps.count { setupSteps[i + 1].state = .running }
    }

    /// Всё за один проход: ключ туннеля → вход админом (сначала по ключу, пароль — только если ключа нет)
    /// → скрипт сервера → по желанию ключ входа для админа → сохранить настройки → туннель отвечает.
    func setupServer(_ draft: Config, password: String, makeAdminKey: Bool) async {
        guard !setupBusy else { return }
        setupBusy = true
        setupDone = false
        setupByPassword = false
        defer { setupBusy = false }
        var c = draft
        c.host = c.hostTrimmed
        if c.keyPath.isEmpty { c.keyPath = Config.defaultKeyPath }
        let admin = c.adminTrimmed
        let wantAdminKey = makeAdminKey && !password.isEmpty
        var titles = ["Ключ туннеля", "Вход на сервер", "Прокси на сервере"]
        if wantAdminKey { titles.append("Ключ для входа на сервер") }
        titles.append("Туннель работает")
        let last = titles.count - 1
        setupSteps = makeSteps(titles)
        setupSteps[0].state = .running
        guard !c.host.isEmpty else { setupStep(0, false, "Укажите адрес сервера"); return }
        await Net.prepare(c.host, interface: c.effectiveInterface)

        // 1. ключ туннеля
        if let e = await generateKey(at: c.keyPath) { setupStep(0, false, "Не создан: \(e)"); return }
        guard let pub = publicKey(for: c.keyPath) else { setupStep(0, false, "Нет файла \(c.keyPath).pub"); return }
        setupStep(0, true, (c.keyPath as NSString).abbreviatingWithTildeInPath)

        // 2. вход: сначала ключ — если он уже на сервере, пароль не нужен.
        // Удачный вход становится общим соединением для всех команд настройки (shared: true): на сервере
        // может стоять ограничение частоты подключений, а их иначе было бы пять-шесть за полминуты.
        let hostForClose = c
        defer { Task { await ServerSetup.closeShared(hostForClose, admin: admin) } }
        var auth = c.adminAuth
        var probe = ProbeResult.denied
        // Фоновая проверка уже сказала, что ключа нет, и пароль введён — лишнее подключение не нужно.
        if !(access == .needPassword && !password.isEmpty) {
            probe = await ServerSetup.probe(c, admin: admin, auth: auth, shared: true)
        }
        if probe == .denied && !password.isEmpty {
            auth = .password(password)
            probe = await ServerSetup.probe(c, admin: admin, auth: auth, shared: true)
        }
        var byPassword = false
        if case .password = auth { byPassword = true }
        let how = byPassword ? "по паролю" : "по ключу"
        switch probe {
        case .root: setupStep(1, true, "\(admin) \(how)")
        case .sudo: setupStep(1, true, "\(admin) \(how), через sudo")
        case .noSudo:
            setupStep(1, false, "\(admin) вошёл, но без sudo без пароля. Войдите под root.")
            return
        case .denied:
            if password.isEmpty {
                access = .needPassword
                setupStep(1, false, "Ключа для \(admin) на сервере нет — введите пароль.")
            } else {
                setupStep(1, false, "Пароль не подошёл.")
            }
            return
        case .refused: setupStep(1, false, ServerSetup.explain("connection refused", code: 255)); return
        case .failed(let e): setupStep(1, false, e); return
        }
        adminIsRoot = probe == .root

        // 3. скрипт сервера
        if let e = await ServerSetup.install(c, admin: admin, auth: auth, root: adminIsRoot, publicKey: pub) {
            setupStep(2, false, e)
            return
        }
        setupStep(2, true, "tinyproxy на 127.0.0.1:\(c.remotePort), пользователь \(c.user)")
        let passwordOn = byPassword ? true : await ServerSetup.passwordEnabled(c, admin: admin, root: adminIsRoot)

        // 4. ключ входа для админа — не обязателен: неудача не останавливает настройку
        if wantAdminKey {
            if !byPassword {
                setupStep(3, true, "не нужен — вход уже по ключу")
            } else if let e = await addAdminKey(c, admin: admin, password: password) {
                setupStep(3, false, e, next: false)
                setupSteps[4].state = .running
            } else {
                c.adminKey = ""   // дальше входим ключом приложения (он в списке по умолчанию)
                setupStep(3, true, (Config.adminKeyPath as NSString).abbreviatingWithTildeInPath)
            }
        }

        // 5. сохранить и дождаться туннеля
        c.adminUser = admin
        enabled = true   // сервер только что настроен — туннель включается
        apply(c)
        setupByPassword = byPassword
        keyStable = nil
        passwordLogin = byPassword ? true : nil
        var ip = "", loc = ""
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            (ip, loc) = await traceViaTunnel()
            if !ip.isEmpty { break }
        }
        if !ip.isEmpty && loc != "RU" {
            setupStep(last, true, "выход: \(ip), \(loc)")
            setupDone = true
        } else {
            let why = tunnel.lastError.isEmpty ? "нет ответа через туннель" : tunnel.lastError
            setupStep(last, false, ip.isEmpty ? why : "выход \(ip), \(loc) — это Россия")
        }
        // «Доступ к серверу» — по тому, что настройка уже проверила, без новых подключений
        // (на сервере может быть ограничение частоты). Повторная проверка — кнопкой «Проверить соединение».
        let keyWorks = !byPassword || (wantAdminKey && setupSteps[3].state == .ok)
        access = keyWorks ? .key(root: adminIsRoot) : .needPassword
        keyStable = keyWorks
        keyVerifiedBySetup = keyWorks
        keyDenied = false
        passwordLogin = byPassword ? true : passwordOn
        accessNote = keyWorks ? "Вход по ключу проверен при настройке." : ""
    }

    /// Создаёт ключ входа приложения (если нет), кладёт его админу на сервер по паролю и проверяет вход по нему.
    private func addAdminKey(_ c: Config, admin: String, password: String) async -> String? {
        if let e = await generateKey(at: Config.adminKeyPath, comment: "proxy-tunnel-admin") { return "Ключ не создан: \(e)" }
        guard let pub = publicKey(for: Config.adminKeyPath) else { return "Нет файла \(Config.adminKeyPath).pub" }
        if let e = await ServerSetup.addAdminKey(c, admin: admin, auth: .password(password), publicKey: pub) { return e }
        let r = await ServerSetup.probe(c, admin: admin, auth: .key(Config.adminKeyPath))
        return r.canAdmin ? nil : "Ключ добавлен, но вход по нему не прошёл"
    }

    /// Кнопка «Создать ключ и добавить на сервер» после настройки (нужен пароль ещё раз).
    func addAdminKeyNow(password: String) async {
        guard !accessBusy else { return }
        accessBusy = true
        accessNote = "Создаю ключ и добавляю его на сервер…"
        var c = config
        let e = await addAdminKey(c, admin: c.adminTrimmed, password: password)
        accessBusy = false
        if let e { accessNote = e; return }
        c.adminKey = ""
        apply(c)
        accessNote = "Ключ добавлен. Проверяю вход по нему…"
        await checkConnection()
    }

    /// «Проверить соединение»: три входа по ключу подряд, включён ли вход по паролю, выход через туннель.
    func checkConnection() async {
        guard !accessBusy, !config.hostTrimmed.isEmpty else { return }
        accessBusy = true
        defer { accessBusy = false }
        keyStable = nil
        keyDenied = false
        keyVerifiedBySetup = false
        let c = config, admin = c.adminTrimmed
        await Net.prepare(c.hostTrimmed, interface: c.effectiveInterface)
        var ok = 0
        var fail = ""
        var waits = 0
        var i = 0
        while i < 3 {
            accessNote = "Вход по ключу: \(i + 1) из 3…"
            let r = await ServerSetup.probe(c, admin: admin, auth: c.adminAuth)
            if r == .refused && waits < 2 {
                // Не провал ключа: сервер ограничивает частоту подключений. Ждём, пока окно лимита освободится.
                waits += 1
                accessNote = "Сервер ограничивает частоту подключений — жду 30 секунд и повторяю…"
                try? await Task.sleep(nanoseconds: 31_000_000_000)
                continue
            }
            if r.canAdmin { ok += 1; adminIsRoot = r == .root } else {
                switch r {
                case .failed(let e): fail = e
                case .refused: fail = ServerSetup.explain("connection refused", code: 255)
                case .denied: fail = "сервер не принял ключ"; keyDenied = true
                default: fail = "нет прав root"
                }
                break
            }
            i += 1
            if i < 3 { try? await Task.sleep(nanoseconds: 3_000_000_000) }   // не упереться в ограничение частоты
        }
        keyStable = ok == 3
        access = keyStable == true ? .key(root: adminIsRoot) : access
        if keyStable == true {
            passwordLogin = await ServerSetup.passwordEnabled(c, admin: admin, root: adminIsRoot)
        } else {
            passwordLogin = await ServerSetup.serverOffersPassword(c, admin: admin)
        }
        let (ip, loc) = await traceViaTunnel()
        let tunnelText = ip.isEmpty ? "туннель не отвечает" : "туннель: выход \(ip), \(loc)"
        accessNote = (keyStable == true ? "Вход по ключу: 3 из 3." : "Вход по ключу не прошёл (\(ok) из 3): \(fail).") + " " + tunnelText
        refresh()
    }

    /// «Выключить вход по паролю» — только после того, как вход по ключу прошёл три раза подряд.
    func disablePasswordLogin() async {
        guard !accessBusy, keyStable == true else { return }
        accessBusy = true
        defer { accessBusy = false }
        let c = config, admin = c.adminTrimmed
        accessNote = "Выключаю вход по паролю…"
        if let e = await ServerSetup.disablePassword(c, admin: admin, root: adminIsRoot) {
            accessNote = "Не выключено: \(e)"
            return
        }
        let r = await ServerSetup.probe(c, admin: admin, auth: c.adminAuth)
        let offers = await ServerSetup.serverOffersPassword(c, admin: admin)
        passwordLogin = offers
        if !r.canAdmin {
            keyStable = false
            accessNote = "Вход по паролю выключен, но повторный вход по ключу не прошёл. Не закрывайте приложение и нажмите «Проверить соединение»; копия прежних настроек ssh — на сервере в /root/proxy-tunnel-backup-…"
        } else if offers == false {
            setupByPassword = false
            accessNote = "Вход по паролю выключен. Вход по ключу работает."
        } else {
            accessNote = "Скрипт отработал, но сервер всё ещё предлагает вход по паролю — посмотрите журнал."
        }
    }

    /// Через какой интерфейс идёт само ssh-соединение туннеля: напрямую (интерфейс из настроек) или через VPN.
    private func tunnelRoute() async -> String {
        let (_, out) = await run(["/usr/sbin/lsof", "-nP", "-a", "-c", "ssh",
                                  "-iTCP@\(config.hostTrimmed):\(config.sshPort)", "-sTCP:ESTABLISHED", "-F", "n"])
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("n") && $0.contains("->") }),
              let local = line.dropFirst().split(separator: "->").first?.split(separator: ":").first.map(String.init)
        else { return "" }
        let iface = config.effectiveInterface
        guard !iface.isEmpty else { return "с адреса \(local)" }
        let (_, ifIP) = await run(["/usr/sbin/ipconfig", "getifaddr", iface])
        return ifIP.trimmingCharacters(in: .whitespacesAndNewlines) == local
            ? "напрямую через \(iface), мимо VPN"
            : "с адреса \(local), не через \(iface) — возможно, через VPN"
    }

    /// Основной маршрут — через VPN (utun/ppp/ipsec)?
    private func defaultRouteIsVPN() async -> Bool {
        let (_, out) = await run(["/sbin/route", "-n", "get", "default"])
        guard let l = out.split(separator: "\n").first(where: { $0.contains("interface:") }) else { return false }
        let i = l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return i.hasPrefix("utun") || i.hasPrefix("ppp") || i.hasPrefix("ipsec")
    }

    func traceViaTunnel() async -> (String, String) {
        let (_, trace) = await run(["/usr/bin/curl", "-s", "-x", config.proxyURL, "--max-time", "8",
                                    "https://claude.ai/cdn-cgi/trace"])
        var ip = "", loc = ""
        for line in trace.split(separator: "\n") {
            if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
            if line.hasPrefix("loc=") { loc = String(line.dropFirst(4)) }
        }
        return (ip, loc)
    }

    // MARK: ключ и прочее

    /// Имя этого Мака для комментария ключа: на сервере видно, чей ключ («proxy-tunnel@MacBook-Anton»).
    static var machineName: String {
        let h = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let clean = h.replacingOccurrences(of: ".local", with: "")
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
        return clean.isEmpty ? "mac" : clean
    }

    /// Ключ по этому пути готов к работе: есть годный закрытый ключ без пароля и его .pub.
    /// Годный уже лежит — используется он (повторная настройка не плодит ключи). Под этим именем лежит что-то
    /// негодное (не ключ, ключ с паролем) или только .pub — это откладывается в «<имя>.old-<время>», не удаляясь,
    /// и создаётся новый ключ. Ключи пользователя в ~/.ssh приложение не трогает: его ключи — в своей папке.
    func generateKey(at path: String, comment: String = "proxy-tunnel") async -> String? {
        let fm = FileManager.default
        let label = "\(comment)@\(Model.machineName)"
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        func moveAside(_ p: String) {
            guard fm.fileExists(atPath: p) else { return }
            try? fm.moveItem(atPath: p, toPath: "\(p).old-\(stamp)")
            Log.append("ключ \(p) не годится — отложен как \(p).old-\(stamp)")
        }
        if fm.fileExists(atPath: path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)   // ssh-keygen не читает ключ с открытыми правами
            let (code, out) = await run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", path])
            let pub = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0, pub.hasPrefix("ssh-") || pub.hasPrefix("ecdsa-") {
                // .pub нет или он от другого ключа — восстановить из закрытого
                let body = pub.split(separator: " ").prefix(2).joined(separator: " ")
                let existing = (try? String(contentsOfFile: path + ".pub")) ?? ""
                if !existing.hasPrefix(body) {
                    moveAside(path + ".pub")
                    try? (body + " " + label + "\n").write(toFile: path + ".pub", atomically: true, encoding: .utf8)
                }
                return nil
            }
            moveAside(path)
            moveAside(path + ".pub")
        } else {
            moveAside(path + ".pub")   // .pub без закрытого ключа: ssh-keygen спросил бы «перезаписать?» и встал
        }
        let (code, out) = await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", label, "-f", path])
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
