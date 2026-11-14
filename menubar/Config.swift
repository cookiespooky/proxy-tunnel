// Настройки приложения: ~/Library/Application Support/Proxy Tunnel/config.json
import Foundation

struct Config: Codable, Equatable {
    var host = ""
    var sshPort = 22
    var user = "tunnel"
    var keyPath = ""
    var localPort = 8888      // порт туннеля на Маке
    var remotePort = 8888     // порт прокси на сервере
    var pacPort = 8889
    var interface = ""        // пусто — интерфейс прямого выхода (Net.physicalInterface)
    var networkService = "Wi-Fi"   // не используется с 2026-11-01: PAC ставится на все службы
    var adminUser = "root"    // кто настраивает сервер
    var adminKey = ""         // свой ключ входа на сервер; пусто — ~/.ssh, агент и ключ входа приложения
    /// Стандартный список. Добавленный сюда адрес появится и у тех, кто ставил программу раньше, — один раз
    /// (см. seenDefaults); удалённый человеком из своего списка обратно не вернётся.
    static let defaultDomains = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com", "claude.site",
                                 "threads.net", "threads.com", "gemini.google.com", "aistudio.google.com",
                                 "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]
    var domains = Config.defaultDomains
    /// Стандартные адреса, которые уже предлагались этой установке. В старых настройках поля нет — значит, пусто.
    var seenDefaults = Config.defaultDomains
    /// Что идёт через туннель, кроме сайтов из списка (Terminal.swift). Галочки действуют сразу, не через «Сохранить».
    var claudeCode = true     // прокси в ~/.claude/settings.json
    var codexCLI = true       // codex в терминале
    var geminiCLI = true      // gemini в терминале
    var vscodeCodex = false   // расширение Codex в VS Code — через посредник
    var vscodeAll = false     // весь VS Code — через переменные при его запуске

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? d.sshPort
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? d.keyPath
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? d.localPort
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? d.remotePort
        pacPort = try c.decodeIfPresent(Int.self, forKey: .pacPort) ?? d.pacPort
        interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? d.interface
        networkService = try c.decodeIfPresent(String.self, forKey: .networkService) ?? d.networkService
        adminUser = try c.decodeIfPresent(String.self, forKey: .adminUser) ?? d.adminUser
        adminKey = try c.decodeIfPresent(String.self, forKey: .adminKey) ?? d.adminKey
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? d.domains
        seenDefaults = try c.decodeIfPresent([String].self, forKey: .seenDefaults) ?? []
        claudeCode = try c.decodeIfPresent(Bool.self, forKey: .claudeCode) ?? d.claudeCode
        // До разделения была одна галочка cliProxy на codex и gemini — переносим её значение.
        let legacy = try? AnyKey.decodeBool(decoder, "cliProxy")
        codexCLI = try c.decodeIfPresent(Bool.self, forKey: .codexCLI) ?? legacy ?? d.codexCLI
        geminiCLI = try c.decodeIfPresent(Bool.self, forKey: .geminiCLI) ?? legacy ?? d.geminiCLI
        vscodeCodex = try c.decodeIfPresent(Bool.self, forKey: .vscodeCodex) ?? d.vscodeCodex
        vscodeAll = try c.decodeIfPresent(Bool.self, forKey: .vscodeAll) ?? d.vscodeAll
    }

    /// Галочки «что через туннель» и служебные поля, которых нет в окне настроек: «Сохранить» их не меняет.
    func keepingToggles(of c: Config) -> Config {
        var r = self
        r.claudeCode = c.claudeCode; r.codexCLI = c.codexCLI; r.geminiCLI = c.geminiCLI
        r.vscodeCodex = c.vscodeCodex; r.vscodeAll = c.vscodeAll; r.seenDefaults = c.seenDefaults
        return r
    }

    var shell: CLIProxy.Shell { CLIProxy.Shell(codex: codexCLI, gemini: geminiCLI, vscodeAll: vscodeAll) }

    static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Proxy Tunnel")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// Где взять сервер — показывается, пока сервер не задан (реферальная ссылка автора).
    static let rentServerURL = URL(string: "https://cloud4box.com/?from=108671")!
    /// Ссылки окошка «?»: страница инструмента, Life OS, автор.
    static let toolPageURL = URL(string: "https://antonlozhkin.ru/cases/proxy-tunnel/")!
    /// Разделы статьи — для кнопок «i» в настройках.
    static let howURL = URL(string: "https://antonlozhkin.ru/cases/proxy-tunnel/#kak-rabotaet")!
    static let routesURL = URL(string: "https://antonlozhkin.ru/cases/proxy-tunnel/#chto-idiot-cherez-server")!
    static let limitsURL = URL(string: "https://antonlozhkin.ru/cases/proxy-tunnel/#ogranicheniia")!
    static let lifeOSURL = URL(string: "https://lifeos.antonlozhkin.ru/")!

    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }
    static var knownHostsURL: URL { supportDir.appendingPathComponent("known_hosts") }
    static var defaultKeyPath: String { supportDir.appendingPathComponent("id_ed25519").path }
    /// Ключ входа на сервер админом, который приложение создаёт по просьбе пользователя (не ключ туннеля).
    static var adminKeyPath: String { supportDir.appendingPathComponent("admin_ed25519").path }
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Proxy Tunnel.log")
    }

    static func load() -> Config {
        var c = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
        if c.keyPath.isEmpty { c.keyPath = defaultKeyPath }
        let fresh = defaultDomains.filter { !c.seenDefaults.contains($0) }
        if !fresh.isEmpty {
            let added = fresh.filter { !c.cleanDomains.contains($0) }
            c.domains += added
            c.seenDefaults += fresh
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? c.save()
                if !added.isEmpty { Log.append("В список сайтов добавлены новые стандартные: \(added.joined(separator: ", "))") }
            }
        }
        return c
    }

    func save() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(self).write(to: Config.fileURL, options: .atomic)
    }

    var hostTrimmed: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var adminTrimmed: String { let a = adminUser.trimmingCharacters(in: .whitespaces); return a.isEmpty ? "root" : a }
    var adminAuth: AdminAuth { adminKey.isEmpty ? .key(nil) : .key(adminKey) }
    var keyExists: Bool { FileManager.default.fileExists(atPath: keyPath) }
    var isComplete: Bool { !hostTrimmed.isEmpty && keyExists }
    var proxyURL: String { "http://127.0.0.1:\(localPort)" }
    var pacURL: String { "http://127.0.0.1:\(pacPort)/proxy.pac" }
    var forwardSpec: String { "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)" }

    var cleanDomains: [String] {
        domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty && !$0.contains(" ") && !$0.contains("\"") }
    }

    /// PAC без запасного DIRECT: нет туннеля — нет соединения с этими доменами.
    var pacText: String {
        let list = cleanDomains.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        // Proxy Tunnel: эти домены идут через туннель, остальное напрямую.
        function FindProxyForURL(url, host) {
          var viaTunnel = [\(list)];
          for (var i = 0; i < viaTunnel.length; i++) {
            if (host == viaTunnel[i] || dnsDomainIs(host, "." + viaTunnel[i])) {
              return "PROXY 127.0.0.1:\(localPort)";
            }
          }
          return "DIRECT";
        }

        """
    }
}

enum Log {
    private static let q = DispatchQueue(label: "log")
    static func append(_ s: String) {
        q.async {
            let url = Config.logURL
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = Data(s.split(separator: "\n").map { "\(stamp) \($0)\n" }.joined().utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}

/// Чтение поля, которого больше нет среди свойств Config (для переноса старых настроек).
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    static func decodeBool(_ d: Decoder, _ k: String) throws -> Bool? {
        try d.container(keyedBy: AnyKey.self).decodeIfPresent(Bool.self, forKey: AnyKey(stringValue: k))
    }
}
