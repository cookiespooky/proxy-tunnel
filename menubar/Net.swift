// Сеть мимо VPN: интерфейс прямого выхода в интернет и адрес сервера без подменённого DNS.
// VPN в режиме TUN забирает маршрут по умолчанию и часто отвечает на DNS-запросы поддельными адресами
// (198.18.x.x). Туннель должен идти мимо него — иначе выход был бы не с нашего сервера, а с VPN.
import Foundation

enum Net {
    /// Синхронный запуск короткой системной команды (netstat, networksetup, curl).
    static func runSync(_ path: String, _ args: [String], timeout: Double = 10) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] { env.removeValue(forKey: k) }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func isVPNInterface(_ i: String) -> Bool {
        ["utun", "ppp", "ipsec", "gif", "stf", "tun", "tap"].contains { i.hasPrefix($0) }
    }

    /// Интерфейс прямого маршрута в интернет — не VPN. На MacBook обычно en0 (Wi-Fi), на Mac mini — кабель.
    static func physicalInterface() -> String? {
        let (code, out) = runSync("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        guard code == 0 else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("default") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4 else { continue }
            let gateway = cols[1], iface = cols[3]
            if !isVPNInterface(iface) && !gateway.hasPrefix("link#") { return iface }
        }
        return nil
    }

    static func isIP(_ host: String) -> Bool {
        host.contains(":") || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
    }

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    private static func store(_ host: String, _ ip: String) {
        lock.lock(); defer { lock.unlock() }
        cache[host] = ip
    }

    /// Адрес, найденный для имени сервера мимо VPN (если сервер задан именем, а не IP).
    static func cached(_ host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[host]
    }

    /// Находит IPv4-адрес имени через DNS-over-HTTPS по прямому интерфейсу (Cloudflare, затем Google).
    /// IP-адрес не трогает. Не нашли — ssh пойдёт по имени, как раньше.
    static func prepare(_ host: String, interface: String) async {
        guard !host.isEmpty, !isIP(host) else { return }
        let ip = await Task.detached { () -> String? in
            var base = ["-s", "--max-time", "6"]
            if !interface.isEmpty { base += ["--interface", interface] }
            let q = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
            for url in ["https://1.1.1.1/dns-query?name=\(q)&type=A", "https://8.8.8.8/resolve?name=\(q)&type=A"] {
                let (_, out) = runSync("/usr/bin/curl", base + ["-H", "accept: application/dns-json", url])
                guard let d = out.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let ans = j["Answer"] as? [[String: Any]] else { continue }
                if let a = ans.first(where: { ($0["type"] as? Int) == 1 })?["data"] as? String, isIP(a) { return a }
            }
            return nil
        }.value
        guard let ip else { return }
        store(host, ip)
    }
}

extension Config {
    /// Интерфейс для ssh: из «Дополнительно» или, если поле пустое, интерфейс прямого выхода.
    var effectiveInterface: String {
        let i = interface.trimmingCharacters(in: .whitespaces)
        return i.isEmpty ? (Net.physicalInterface() ?? "") : i
    }

    /// Куда подключаться ssh: адрес, найденный мимо VPN, а ключ сервера в known_hosts — под его именем.
    func sshDest(_ user: String) -> [String] {
        let h = hostTrimmed
        if let ip = Net.cached(h), ip != h { return ["-o", "HostKeyAlias=\(h)", "\(user)@\(ip)"] }
        return ["\(user)@\(h)"]
    }
}
