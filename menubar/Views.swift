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

enum SetupTab: String { case password, key, manual }

struct SettingsView: View {
    @ObservedObject var m: Model
    @State private var draft = Config()
    @State private var domainsText = ""
    @State private var note = ""
    @State private var keyExists = false
    @State private var tab = SetupTab.password
    @State private var admin = "root"
    @State private var password = ""
    @State private var adminKey: String?

    private let plainInt = IntegerFormatStyle<Int>().grouping(.never)

    var body: some View {
        Form {
            Section {
                TextField("Адрес сервера", text: $draft.host, prompt: Text("IP или домен"))
                TextField("SSH-порт", value: $draft.sshPort, format: plainInt)
            } header: { StepHeader(n: 1, title: "Сервер", done: m.config.isComplete) }

            Section {
                Picker("", selection: $tab) {
                    Text("Пароль").tag(SetupTab.password)
                    Text("Ключ на сервере").tag(SetupTab.key)
                    Text("Вручную").tag(SetupTab.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch tab {
                case .password: passwordTab
                case .key: keyTab
                case .manual: manualTab
                }

                if tab != .manual && !m.setupSteps.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(m.setupSteps) { StepRow(step: $0) }
                    }
                    if m.setupDone {
                        if m.mode == "tunnel" {
                            Text("Готово. Туннель включён — перезапустите Claude, если он открыт.")
                                .font(.caption).foregroundColor(Palette.green)
                        } else {
                            Button("Включить туннель для Claude") { m.setMode("tunnel") }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } header: { StepHeader(n: 2, title: "Настройка сервера (один раз)", done: m.setupDone) }

            Section("Через туннель") {
                TextEditor(text: $domainsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                Text("По одному домену в строке; поддомены включаются. Остальной трафик идёт напрямую.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Дополнительно") {
                TextField("Пользователь туннеля", text: $draft.user)
                LabeledContent("Ключ туннеля") {
                    Text((draft.keyPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).textSelection(.enabled)
                }
                HStack {
                    Button("Скопировать публичный ключ") { copyPublicKey() }.disabled(!keyExists)
                    Button("Выбрать…") { if let p = pickKey() { draft.keyPath = p; keyExists = draft.keyExists } }
                }
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
        .frame(width: 500)
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.shown)) { _ in load() }
        .onChange(of: m.setupNeedsPassword) { need in if need { tab = .password } }
    }

    // MARK: вкладки

    private var hostEmpty: Bool { draft.hostTrimmed.isEmpty }

    @ViewBuilder private var passwordTab: some View {
        Text("Приложение само зайдёт на сервер (Ubuntu или Debian), поставит прокси и заведёт пользователя, которому разрешён только туннель. Если ваш SSH-ключ уже на сервере, пароль не понадобится. Пароль нигде не сохраняется.")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
        TextField("Логин", text: $admin)
        SecureField("Пароль", text: $password)
        setupButton("Настроить сервер")
    }

    @ViewBuilder private var keyTab: some View {
        Text("Если при создании сервера вы добавили на него свой SSH-ключ: приложение войдёт по нему, без пароля.")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
        TextField("Логин", text: $admin)
        LabeledContent("Ключ для входа") {
            HStack {
                Text(adminKey.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "из ~/.ssh и агента")
                    .font(.caption).foregroundColor(.secondary)
                Button("Выбрать…") { if let p = pickKey() { adminKey = p } }
                if adminKey != nil { Button("Сбросить") { adminKey = nil } }
            }
        }
        setupButton("Проверить и настроить")
    }

    @ViewBuilder private var manualTab: some View {
        Text("Если приложению на сервер не зайти (вход только через консоль хостинга): скопируйте команду, вставьте её в консоль сервера под root или пользователем с sudo и дождитесь строки «сервер готов». Затем «Сохранить» внизу.")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
        HStack {
            if !keyExists { Button("Создать ключ туннеля") { createKey() }.buttonStyle(.borderedProminent) }
            Button("Скопировать команду для сервера") { copyServerScript() }.disabled(!keyExists)
        }
    }

    private func setupButton(_ title: String) -> some View {
        HStack {
            Button(title) { runSetup() }
                .buttonStyle(.borderedProminent)
                .disabled(hostEmpty || m.setupBusy)
            if m.setupBusy { ProgressView().controlSize(.small) }
            if hostEmpty { Text("Сначала адрес сервера").font(.caption).foregroundColor(.secondary) }
        }
    }

    // MARK: действия

    private func currentDraft() -> Config {
        var c = draft
        c.host = c.hostTrimmed
        c.domains = domainsText.split(separator: "\n").map(String.init)
        c.domains = c.cleanDomains
        return c
    }

    private func load() {
        draft = m.config
        domainsText = m.config.domains.joined(separator: "\n")
        keyExists = draft.keyExists
        note = ""
    }

    private func save() {
        let c = currentDraft()
        m.apply(c)
        domainsText = c.domains.joined(separator: "\n")
        note = c.isComplete ? "Сохранено. Туннель переподключается." : "Сохранено. Для подключения нужны адрес и ключ."
    }

    private func runSetup() {
        let c = currentDraft()
        let pw = tab == .password ? password : ""
        let key = tab == .key ? adminKey : nil
        note = ""
        Task {
            await m.setupServer(c, admin: admin, password: pw, adminKey: key)
            if m.setupDone { password = "" }
            draft = m.config
            keyExists = draft.keyExists
        }
    }

    private func createKey() {
        let path = draft.keyPath
        Task {
            if let e = await m.generateKey(at: path) { note = "Ключ не создан: \(e)" }
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
        guard let cmd = ServerScript.manualCommand(currentDraft(), publicKey: k) else {
            note = "В приложении нет скрипта сервера — пересоберите его build.sh."; return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        note = "Команда скопирована. Вставьте её в консоль сервера, дождитесь «сервер готов», затем «Сохранить»."
    }

    /// Выбор закрытого ключа (не .pub); nil — отменили.
    private func pickKey() -> String? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        p.message = "Выберите закрытый ключ (не .pub)"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return u.path.hasSuffix(".pub") ? String(u.path.dropLast(4)) : u.path
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
