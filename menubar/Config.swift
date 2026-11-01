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
    var domains = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com", "claude.site",
                   "threads.net", "threads.com"]

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
    }

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
    static let lifeOSURL = URL(string: "https://lifeos.antonlozhkin.ru/")!
    static let authorSiteURL = URL(string: "https://antonlozhkin.ru/")!
    static let authorTelegramURL = URL(string: "https://t.me/cookiespooky")!

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
