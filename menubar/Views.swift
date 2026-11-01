// Окошко в строке меню и окно настроек.
import SwiftUI
import AppKit

/// Приглушённые цвета в духе iOS.
enum Palette {
    static let green = Color(red: 0.16, green: 0.62, blue: 0.36)
    static let blue = Color(red: 0.10, green: 0.44, blue: 0.86)
    static let red = Color(red: 0.86, green: 0.22, blue: 0.22)
    static let orange = Color(red: 0.92, green: 0.52, blue: 0.10)
    static let card = Color.primary.opacity(0.06)
    static let sub = Color.primary.opacity(0.62)
}

struct StatusCard: View {
    @ObservedObject var m: Model

    var body: some View {
        let s = status
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(s.color.opacity(0.16)).frame(width: 38, height: 38)
                if m.checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: s.icon).font(.system(size: 17, weight: .semibold)).foregroundColor(s.color)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.primary)
                if !s.subtitle.isEmpty {
                    Text(s.subtitle).font(.system(size: 12)).foregroundColor(Palette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .animation(.easeInOut(duration: 0.2), value: s.title)
    }

    private var status: (title: String, subtitle: String, icon: String, color: Color) {
        if !m.config.isComplete { return ("Не настроено", "Откройте настройки", "gearshape.fill", Palette.orange) }
        if m.checking { return ("Проверяю…", "", "", .secondary) }
        switch m.mode {
        case "tunnel":
            if m.verdictOK {
                let where_ = m.steps.count > 1 ? m.steps[1].detail : ""
                return ("Соединение через туннель", where_.isEmpty ? "" : "выход: \(where_)",
                        "checkmark.shield.fill", Palette.green)
            }
            return ("Соединение не готово", "Исправьте отмеченное ниже", "xmark.shield.fill", Palette.red)
        case "vpn":
            return m.verdictOK
                ? ("Соединение через VPN", "выход: \(m.directLoc)", "globe", Palette.blue)
                : ("VPN не подключён", "Соединение не установится", "wifi.exclamationmark", Palette.orange)
        default:
            return ("Режим выбран не до конца", "Выберите «Туннель» или «VPN»", "exclamationmark.triangle.fill", Palette.orange)
        }
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                switch step.state {
                case .pending: Image(systemName: "circle").foregroundColor(.primary.opacity(0.3))
                case .running: ProgressView().controlSize(.small).scaleEffect(0.65)
                case .ok: Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Palette.green)
                case .fail: Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Palette.red)
                }
            }
            .font(.system(size: 14))
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 13))
                    .foregroundColor(step.state == .pending ? Palette.sub : .primary)
                if !step.detail.isEmpty {
                    Text(step.detail).font(.system(size: 11.5)).foregroundColor(Palette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .animation(.easeOut(duration: 0.2), value: step.state)
    }
}

struct PanelView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Proxy Tunnel").font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Group {
                    Button { m.openLog() } label: { Image(systemName: "doc.text") }
                        .help("Журнал")
                    Button {
                        SettingsWindow.show(m)
                    } label: { Image(systemName: "gearshape") }
                        .help("Настройки")
                }
                .buttonStyle(.borderless)
                .foregroundColor(Palette.sub)
                .font(.system(size: 15))
            }

            Picker("", selection: Binding(
                get: { m.mode == "vpn" ? "vpn" : "tunnel" },
                set: { m.setMode($0) }
            )) {
                Text("Туннель").tag("tunnel")
                Text("VPN").tag("vpn")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(m.busy)

            StatusCard(m: m)

            if !m.config.isComplete {
                Button { SettingsWindow.show(m) } label: {
                    Text("Настроить…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            VStack(spacing: 0) {
                ForEach(Array(m.steps.enumerated()), id: \.element.id) { i, step in
                    StepRow(step: step)
                    if i < m.steps.count - 1 { Divider().padding(.leading, 40) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))

            if !m.message.isEmpty {
                Text(m.message).font(.system(size: 12)).foregroundColor(Palette.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let t = m.checkedAt, !m.checking {
                    Text("Проверено в \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundColor(Palette.sub)
                }
                Spacer()
                Button("Переподключить") { m.reconnect() }.disabled(m.busy || !m.config.isComplete)
                Button("Проверить") { m.refresh() }.disabled(m.busy)
            }
            .buttonStyle(.borderless)
            .foregroundColor(Palette.blue)
            .font(.system(size: 13, weight: .medium))
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    @State private var draft = Config()
    @State private var domainsText = ""
    @State private var note = ""
    @State private var keyExists = false

    private let plainInt = IntegerFormatStyle<Int>().grouping(.never)

    var body: some View {
        Form {
            Section {
                Text(draft.keyPath).font(.caption).textSelection(.enabled)
                HStack {
                    if !keyExists {
                        Button("Создать ключ") { createKey() }.buttonStyle(.borderedProminent)
                    }
                    Button("Скопировать публичный ключ") { copyPublicKey() }.disabled(!keyExists)
                    Button("Выбрать…") { chooseKey() }
                }
                Text(keyExists ? "Ключ на месте." : "Ключа ещё нет — создайте его. Он нужен, чтобы входить на сервер без пароля.")
                    .font(.caption).foregroundColor(keyExists ? .secondary : Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { StepHeader(n: 1, title: "Ключ SSH", done: keyExists) }

            Section {
                Text("Нужен сервер на Ubuntu или Debian. Скопируйте команду, войдите на сервер под root (консоль в панели хостинга или ssh) и вставьте её. Она поставит прокси, доступный только через туннель, и пользователя «\(draft.user)», которому разрешён только туннель. Дождитесь строки «сервер готов».")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("Скопировать команду для сервера") { copyServerScript() }.disabled(!keyExists)
            } header: { StepHeader(n: 2, title: "Настройка сервера (один раз)", done: false, optionalDone: true) }

            Section {
                TextField("Адрес сервера", text: $draft.host, prompt: Text("IP или домен"))
                TextField("SSH-порт", value: $draft.sshPort, format: plainInt)
                TextField("Пользователь", text: $draft.user)
                Text("Затем «Сохранить» внизу и в окошке значка переключите на «Туннель».")
                    .font(.caption).foregroundColor(.secondary)
            } header: { StepHeader(n: 3, title: "Подключение", done: m.config.isComplete) }

            Section("Через туннель") {
                TextEditor(text: $domainsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                Text("По одному домену в строке; поддомены включаются. Остальной трафик идёт напрямую.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Дополнительно") {
                TextField("Интерфейс", text: $draft.interface, prompt: Text("en0 — Wi-Fi"))
                TextField("Сетевая служба macOS", text: $draft.networkService)
                TextField("Порт туннеля на Маке", value: $draft.localPort, format: plainInt)
                TextField("Порт прокси на сервере", value: $draft.remotePort, format: plainInt)
                TextField("Порт PAC", value: $draft.pacPort, format: plainInt)
                Button("Забыть ключ сервера") { m.forgetHostKey(); note = m.message }
            }

            if !note.isEmpty {
                Text(note).font(.caption).foregroundColor(.primary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отменить") { load() }
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction)
            }

            Section {
                Toggle("Запускать при входе", isOn: Binding(
                    get: { m.launchAtLogin },
                    set: { m.launchAtLogin = $0 }
                ))
            }

            Section {
                Button { NSApp.terminate(nil) } label: {
                    Text("Выйти из Proxy Tunnel").foregroundColor(Palette.red).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                Text("Туннель и PAC закроются. В режиме «Туннель» соединение пропадёт.")
                    .font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.shown)) { _ in load() }
    }

    private func load() {
        draft = m.config
        domainsText = m.config.domains.joined(separator: "\n")
        keyExists = draft.keyExists
        note = ""
    }

    private func save() {
        var c = draft
        c.host = c.hostTrimmed
        c.domains = domainsText.split(separator: "\n").map(String.init)
        c.domains = c.cleanDomains
        m.apply(c)
        domainsText = c.domains.joined(separator: "\n")
        note = c.isComplete ? "Сохранено. Туннель переподключается." : "Сохранено. Для подключения нужны адрес и ключ."
    }

    private func createKey() {
        let path = draft.keyPath
        Task {
            var c = m.config; c.keyPath = path; m.config = c
            if let e = await m.generateKey() { note = "Ключ не создан: \(e)" }
            keyExists = FileManager.default.fileExists(atPath: path)
            if keyExists { note = "Ключ создан. Теперь скопируйте команду для сервера." }
        }
    }

    private func copyPublicKey() {
        guard let k = m.publicKey(for: draft.keyPath) else { note = "Нет файла \(draft.keyPath).pub"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(k, forType: .string)
        note = "Публичный ключ скопирован."
    }

    private func copyServerScript() {
        guard let k = m.publicKey(for: draft.keyPath) else { note = "Нет файла \(draft.keyPath).pub"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.serverScript(publicKey: k), forType: .string)
        note = "Команда скопирована. Вставьте её в консоль сервера под root, дождитесь «сервер готов», затем «Сохранить»."
    }

    private func chooseKey() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        p.message = "Выберите закрытый ключ (не .pub)"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url {
            draft.keyPath = u.path.hasSuffix(".pub") ? String(u.path.dropLast(4)) : u.path
            keyExists = draft.keyExists
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Model.current?.tunnel.stop()
        Model.current?.pac.stop()
    }
}

@main
struct ProxyTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var m = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView(m: m)
        } label: {
            Image(systemName: m.icon)
        }
        .menuBarExtraStyle(.window)

    }
}

struct StepHeader: View {
    let n: Int
    let title: String
    let done: Bool
    var optionalDone = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, done ? Palette.green : Palette.blue)
            Text(title)
        }
    }
}

/// Окно настроек на AppKit: его можно открыть и из кода (при первом запуске), а не только из окошка значка.
@MainActor
enum SettingsWindow {
    static let shown = Notification.Name("ProxyTunnelSettingsShown")
    private static var window: NSWindow?

    static func show(_ m: Model) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(m: m)))
            w.title = "Настройки Proxy Tunnel"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        } else {
            NotificationCenter.default.post(name: shown, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
