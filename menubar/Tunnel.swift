// SSH-туннель как дочерний процесс приложения: запуск, переподключение с паузой, остановка.
import Foundation
import Network

@MainActor
final class Tunnel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var lastError = ""
    private var process: Process?
    private var wanted = false
    private var config: Config?
    private var backoff: Double = 3
    private var startedAt = Date()

    func start(_ c: Config) {
        config = c
        wanted = true
        backoff = 3
        lastError = ""
        launch()
    }

    func stop() {
        wanted = false
        process?.terminate()
        process = nil
        running = false
    }

    private func launch() {
        guard wanted, process == nil, let c = config, c.isComplete else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-N", "-F", "none", "-i", c.keyPath,
                    "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                    "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=3",
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=15",
                    "-o", "UserKnownHostsFile=\"\(Config.knownHostsURL.path)\"",   // в пути пробел
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-p", String(c.sshPort),
                    "-L", c.forwardSpec]
        // ssh — мимо VPN: через интерфейс прямого выхода и по адресу, найденному без DNS VPN.
        let iface = c.effectiveInterface
        if !iface.isEmpty { args += ["-o", "BindInterface=\(iface)"] }
        args += c.sshDest(c.user)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            Log.append(s)
            let last = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
            Task { @MainActor [weak self] in self?.lastError = last }
        }
        p.terminationHandler = { proc in
            err.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in self?.exited(proc) }
        }
        do {
            try p.run()
            process = p
            running = true
            startedAt = Date()
            Log.append("ssh запущен: \(c.user)@\(c.hostTrimmed):\(c.sshPort), \(c.forwardSpec), через \(iface.isEmpty ? "маршрут по умолчанию" : iface)")
        } catch {
            lastError = error.localizedDescription
            scheduleRetry()
        }
    }

    private func exited(_ p: Process) {
        guard p === process else { return }
        process = nil
        running = false
        Log.append("ssh завершился, код \(p.terminationStatus)")
        if Date().timeIntervalSince(startedAt) > 60 { backoff = 3 }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard wanted else { return }
        let delay = backoff
        backoff = min(backoff * 2, 60)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.launch()
        }
    }
}

/// Раздаёт PAC-файл на 127.0.0.1:<порт> из памяти приложения.
final class PacServer {
    private var listener: NWListener?
    private var text = ""
    private let q = DispatchQueue(label: "pac")
    private(set) var error = ""

    func start(port: Int, text: String) {
        stop()
        q.sync { self.text = text }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st {
                    self?.error = "PAC: \(e)"
                    Log.append("PAC-сервер: \(e) — повтор через 3 с")
                    // Порт может ещё держать старый процесс — пробуем снова, пока нас не остановили.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.listener === l else { return }
                        self.start(port: port, text: self.q.sync { self.text })
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: q)
            listener = l
            error = ""
        } catch {
            self.error = "PAC: \(error)"
            Log.append("PAC-сервер не запустился: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            let body = Data((self?.text ?? "").utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n" +
                "Content-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
