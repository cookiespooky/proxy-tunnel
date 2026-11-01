// Проверка новой версии и анонимная статистика: раз в день один запрос на stats.antonlozhkin.ru/pt/ping
// (и ещё один — при первом за день включении туннеля). Статистика выключена — запрос только узнаёт версию.
import Foundation

enum Update {
    static let endpoint = "https://stats.antonlozhkin.ru/pt/ping"
    static let downloadURL = URL(string: "https://github.com/cookiespooky/proxy-tunnel/releases/latest/download/ProxyTunnel-mac.dmg")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Галочка «Отправлять анонимную статистику» (по умолчанию включена).
    static var sendStats: Bool {
        get { UserDefaults.standard.object(forKey: "sendStats") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sendStats") }
    }

    /// id — случайный номер установки, с компьютером не связан; day / onDay — когда отмечались; latest — что ответил
    /// сервер в последний раз (чтобы строка о новой версии была видна и после перезапуска в тот же день).
    /// Поля необязательные: файл от старой версии читается, номер установки не меняется.
    struct State: Codable { var id: String?; var day: String?; var onDay: String?; var latest: String? }
    private static var stateURL: URL { Config.supportDir.appendingPathComponent("stats.json") }

    private static func load() -> State {
        var s = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State(id: nil, day: nil, onDay: nil, latest: nil)
        if (s.id ?? "").count != 32 {
            s.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            save(s)
        }
        return s
    }

    private static func save(_ s: State) {
        try? JSONEncoder().encode(s).write(to: stateURL, options: .atomic)
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Пора ли отметиться: сегодня ещё не спрашивали, или туннель включён, а сегодня об этом ещё не говорили.
    static func due(tunnelOn: Bool) -> Bool {
        let s = load(), d = today()
        return s.day != d || (tunnelOn && sendStats && s.onDay != d)
    }

    /// Один запрос. -> последняя версия или nil, если сервер не ответил.
    static func ping(tunnelOn: Bool) async -> String? {
        var s = load()
        let d = today()
        var q = [URLQueryItem(name: "os", value: "mac"), URLQueryItem(name: "v", value: version)]
        if sendStats {
            q += [URLQueryItem(name: "id", value: s.id ?? ""), URLQueryItem(name: "on", value: tunnelOn ? "1" : "0")]
        }
        var c = URLComponents(string: endpoint)!
        c.queryItems = q
        var req = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("ProxyTunnel/\(version) mac", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        s.day = d
        if tunnelOn && sendStats { s.onDay = d }
        s.latest = obj["latest"] as? String ?? ""
        save(s)
        return s.latest
    }

    /// Последняя версия, которую называл сервер (без запроса).
    static var knownLatest: String? { load().latest }

    /// «1.10» новее «1.9»: сравнение по числам через точку.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
