// Окошко в строке меню и окно настроек.
import SwiftUI
import AppKit
import Combine

/// Приглушённые цвета в духе iOS.
enum Palette {
    static let green = Color(red: 0.16, green: 0.62, blue: 0.36)
    static let blue = Color(red: 0.10, green: 0.44, blue: 0.86)
    static let red = Color(red: 0.86, green: 0.22, blue: 0.22)
    static let orange = Color(red: 0.92, green: 0.52, blue: 0.10)
    static let yellow = Color(red: 0.93, green: 0.70, blue: 0.08)
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
                    // Знак внутри щита — белый, сам щит — цветом состояния.
                    Image(systemName: s.icon).font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, s.color)
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
            // Карточка — выключатель туннеля.
            Image(systemName: "power")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(m.enabled ? Palette.green : Palette.sub)
                .help(m.enabled ? "Выключить туннель" : "Включить туннель")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { m.toggleTunnel() }
        .animation(.easeInOut(duration: 0.2), value: s.title)
    }

    private var status: (title: String, subtitle: String, icon: String, color: Color) {
        if !m.enabled {
            return ("Туннель выключен", "Нажмите, чтобы включить", "shield.slash.fill", .secondary)
        }
        if m.checking { return ("Проверяю…", "", "", .secondary) }
        if m.verdictOK {
            let where_ = m.steps.count > 1 ? m.steps[1].detail : ""
            if m.hasWarn {
                return ("Туннель работает", "с оговоркой — см. жёлтое ниже", "exclamationmark.shield.fill", Palette.yellow)
            }
            return ("Claude — через туннель", where_.isEmpty ? "" : "выход: \(where_)", "checkmark.shield.fill", Palette.green)
        }
        if m.steps.isEmpty { return ("Подключаюсь…", "", "hourglass", .secondary) }
        // Не работают только сайты из списка (последний пункт) — Claude Code и остальное идут через туннель.
        if let last = m.steps.last, last.state == .fail,
           m.steps.dropLast().allSatisfy({ $0.state == .ok || $0.state == .warn }) {
            return ("Туннель работает", "кроме сайтов из списка в браузере — см. ниже",
                    "exclamationmark.shield.fill", Palette.orange)
        }
        return ("Соединение не готово", "Исправьте отмеченное ниже", "xmark.shield.fill", Palette.red)
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
                case .warn: Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Palette.yellow)
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

/// Пока туннель не настроен: что это и как настроить.
struct TunnelSetupCard: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Palette.orange.opacity(0.16)).frame(width: 38, height: 38)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Туннель не настроен").font(.system(size: 14, weight: .semibold))
                    Text("Свой сервер за границей: через него идут только Claude и выбранные сайты, остальное — напрямую.")
                        .font(.system(size: 12)).foregroundColor(Palette.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button { SettingsWindow.show(m) } label: {
                Text("Настроить туннель…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if m.config.hostTrimmed.isEmpty {
                Link(destination: Config.rentServerURL) {
                    Text("Нет сервера? Арендовать").frame(maxWidth: .infinity)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Palette.blue)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
    }
}

/// Окошко «?»: что это и как пользоваться. Ссылки подчёркнуты: в popover без этого они не отличаются от текста.
struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proxy Tunnel").font(.system(size: 14, weight: .semibold))
            Text("Отправляет Claude и выбранные сайты через ваш сервер за границей. Всё остальное работает напрямую, как без программы.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Настройки → адрес сервера → «Настроить сервер». Это один раз.")
                Text("2. Нажмите на верхнюю карточку — туннель включится.")
                Text("3. Перезапустите Claude Code и браузер.")
                Text("Сайты для туннеля — в настройках, раздел «Через туннель». Если что-то не так — загляните в журнал.")
                    .foregroundColor(Palette.sub)
            }
            .fixedSize(horizontal: false, vertical: true)

            Link(destination: Config.howURL) { Text("Как работает, что идёт через сервер, ограничения").underline() }

            Divider()

            HStack(spacing: 0) {
                Text("Инструмент лаборатории ")
                Link(destination: Config.lifeOSURL) { Text("Life OS").underline() }
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 300)
    }
}

struct PanelView: View {
    @ObservedObject var m: Model
    @State private var showAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Proxy Tunnel").font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Group {
                    Button { showAbout.toggle() } label: { Image(systemName: "questionmark.circle") }
                        .help("О программе")
                        .popover(isPresented: $showAbout, arrowEdge: .bottom) { AboutView() }
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

            if !m.config.isComplete {
                TunnelSetupCard(m: m)
            } else {
                StatusCard(m: m)
            }

            if m.config.isComplete && m.enabled && !m.steps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(m.steps.enumerated()), id: \.element.id) { i, step in
                        StepRow(step: step)
                        if i < m.steps.count - 1 { Divider().padding(.leading, 40) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            }

            if !m.message.isEmpty {
                Text(m.message).font(.system(size: 12)).foregroundColor(Palette.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let v = m.updateAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(Palette.blue)
                    Text("Доступна версия \(v)").font(.system(size: 13))
                    Spacer()
                    Link("Скачать", destination: Update.downloadURL).font(.system(size: 13, weight: .medium))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            }

            HStack {
                if let t = m.checkedAt, !m.checking {
                    Text("Проверено в \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundColor(Palette.sub)
                }
                Spacer()
                if m.config.isComplete && m.enabled {
                    Button("Переподключить") { m.reconnect() }.disabled(m.busy)
                    Button("Проверить") { m.refresh() }.disabled(m.busy)
                }
            }
            .buttonStyle(.borderless)
            .foregroundColor(Palette.blue)
            .font(.system(size: 13, weight: .medium))
        }
        .padding(14)
        .frame(width: 340)
    }
}

enum SetupTab: String { case auto, manual }

/// Подпись под настройкой: что произойдёт, коротко.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Кнопка «i» — раздел статьи о программе на сайте.
struct InfoLink: View {
    let url: URL
    let help: String
    var body: some View {
        Link(destination: url) { Image(systemName: "info.circle") }
            .help(help)
            .foregroundColor(.secondary)
    }
}

/// Заголовок раздела настроек с кнопкой «i» справа.
struct InfoHeader: View {
    let title: String
    let url: URL
    let help: String
    var body: some View {
        HStack { Text(title); Spacer(); InfoLink(url: url, help: help) }
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    @State private var draft = Config()
    @State private var domainsText = ""
    @State private var note = ""
    @State private var keyExists = false
    @State private var tab = SetupTab.auto
    @State private var password = ""
    @State private var makeAdminKey = true
    @State private var accessPassword = ""
    @State private var flashHost = false
    @State private var loaded = false
    @State private var confirmForget = false
    @State private var confirmResetup = false
    @FocusState private var hostFocused: Bool

    private let plainInt = IntegerFormatStyle<Int>().grouping(.never)

    /// Галочка «что через туннель»: сохраняется сразу, туннель не переподключается.
    private func toggle(_ title: String, _ k: WritableKeyPath<Config, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { m.config[keyPath: k] }, set: { m.setToggle(k, $0) }))
    }

    var body: some View {
        Form {
            Section {
                TextField("Адрес сервера", text: $draft.host, prompt: Text("IP или домен"))
                    .focused($hostFocused)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.red.opacity(flashHost ? 0.18 : 0)))
                    .animation(.easeInOut(duration: 0.25), value: flashHost)
                Hint("Ваш сервер за границей. Через него пойдут Claude и сайты из списка.")
                TextField("SSH-порт", value: $draft.sshPort, format: plainInt)
                Hint("Порт входа на сервер. Обычно 22 — менять, только если хостинг дал другой.")
                if m.config.hostTrimmed.isEmpty {
                    HStack {
                        Text("Нет сервера? Подойдёт любой зарубежный VPS на Ubuntu или Debian.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Link("Арендовать сервер", destination: Config.rentServerURL)
                    }
                }
            } header: {
                HStack {
                    StepHeader(n: 1, title: "Сервер", done: m.config.isComplete)
                    Spacer()
                    InfoLink(url: Config.howURL, help: "Как работает туннель — статья на сайте")
                }
            }

            Section {
                Picker("", selection: $tab) {
                    Text("Автоматически").tag(SetupTab.auto)
                    Text("Вручную").tag(SetupTab.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch tab {
                case .auto: autoTab
                case .manual: manualTab
                }
            } header: { StepHeader(n: 2, title: "Настройка сервера (один раз)", done: m.setupDone) }

            if m.config.isComplete { accessSection }

            Section {
                toggle("Claude Code — через туннель", \.claudeCode)
                Hint("Claude Code в терминале и в VS Code идёт через сервер целиком, кроме российских сайтов. Программа пишет адрес в ~/.claude/settings.json. Выключено — напрямую. После переключения перезапустите Claude Code.")
                toggle("Codex в терминале — через туннель", \.codexCLI)
                Hint("Команда codex идёт через сервер целиком, пока туннель включён, — и при VPN тоже. В окнах терминала, открытых после включения. Программа добавляет строки в ~/.zshrc; выключите — уберёт.")
                toggle("Gemini в терминале — через туннель", \.geminiCLI)
                Hint("Команда gemini — так же, как codex.")
                TextEditor(text: $domainsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                Hint("Браузер и приложение Claude: эти сайты — через сервер, остальные — напрямую. Один домен в строке, поддомены включаются. Пока включён VPN, список не действует. Изменения — после «Сохранить».")
            } header: {
                InfoHeader(title: "Через туннель", url: Config.routesURL, help: "Что идёт через сервер — статья на сайте")
            }

            Section {
                Hint("Claude Code в VS Code — по галочке «Claude Code» выше. Остальное в VS Code само по себе идёт напрямую.")
                toggle("Codex в VS Code — через туннель", \.vscodeCodex)
                Hint("Расширение Codex запускается через посредника Proxy Tunnel и идёт через сервер, пока туннель включён. Программа пишет одну строку в настройки VS Code (служебная настройка расширения — может перестать работать после его обновления, проверка это покажет). После переключения перезапустите VS Code.")
                toggle("Весь VS Code — через туннель", \.vscodeAll)
                Hint("Всё, что делает VS Code, — любые расширения (Gemini, Copilot и другие), их загрузка и команды в его терминале — идёт через сервер. Действует, если открыть VS Code из Dock при включённом туннеле. Выключили туннель при открытом VS Code — он останется без сети до перезапуска.")
            } header: {
                InfoHeader(title: "VS Code", url: Config.routesURL, help: "Что идёт через сервер — статья на сайте")
            }

            Section {
                Hint("Менять не нужно, если всё работает. Любое изменение — после «Сохранить», туннель переподключится.")
                Group {
                    TextField("Пользователь туннеля", text: $draft.user)
                    Hint("Под этим именем программа держит туннель. На сервере ему разрешён только туннель.")
                    TextField("Интерфейс для туннеля", text: $draft.interface, prompt: Text("автоматически"))
                    Hint("Через какую сеть идёт связь с сервером. Пусто — программа сама выбирает прямую сеть, мимо VPN.")
                    TextField("Порт туннеля на Маке", value: $draft.localPort, format: plainInt)
                    Hint("Адрес 127.0.0.1:порт на этом Маке — через него идут Claude Code, codex и gemini. Менять, если порт занят.")
                    TextField("Порт прокси на сервере", value: $draft.remotePort, format: plainInt)
                    Hint("Куда на сервере ведёт туннель. Должен совпадать с настройкой сервера.")
                }
                TextField("Порт PAC", value: $draft.pacPort, format: plainInt)
                Hint("Отсюда браузер берёт список сайтов для туннеля.")
                Button("Забыть ключ сервера…") { confirmForget = true }
                Hint("Только если сервер переустановили и программа пишет, что его ключ изменился.")
            } header: {
                InfoHeader(title: "Дополнительно", url: Config.limitsURL, help: "Ограничения — статья на сайте")
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
                Hint("Программа откроется сама после включения Мака. Туннель при этом выключен — включается нажатием на карточку.")
                Toggle("Отправлять анонимную статистику", isOn: Binding(
                    get: { Update.sendStats },
                    set: { Update.sendStats = $0; m.objectWillChange.send() }
                ))
                Text("Раз в день программа узнаёт, нет ли новой версии. Со статистикой она сообщает ещё случайный номер установки, версию, систему и включали ли сегодня туннель — чтобы автор видел, сколькими людьми программа пользуется. Адрес сервера, список сайтов и IP не сохраняются.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button { NSApp.terminate(nil) } label: {
                    Text("Выйти из Proxy Tunnel").foregroundColor(Palette.red).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                Text("Туннель закроется: всё пойдёт напрямую.")
                    .font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, idealWidth: 500, maxWidth: 500, minHeight: 420, idealHeight: 760, maxHeight: .infinity)
        // Введённое не теряется: при повторном показе окна (из значка, после переключения на другое окно)
        // сохранённые настройки подставляются, только если правок нет. Сбросить правки — «Отменить».
        .onAppear { loadIfUntouched() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.shown)) { _ in loadIfUntouched() }
        .alert("Сервер уже настроен", isPresented: $confirmResetup) {
            Button("Настроить заново") { runSetup() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Прокси на сервере поставится заново, его настройки перезапишутся. Ключи и вход на сервер не пропадут, но туннель прервётся на несколько секунд. Нужно, если туннель перестал работать или сервер переустановили.")
        }
        .alert("Забыть ключ сервера?", isPresented: $confirmForget) {
            Button("Забыть", role: .destructive) { m.forgetHostKey(); note = m.message }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это нужно, только если сервер переустановили и приложение пишет, что ключ сервера изменился. При следующем подключении приложение примет ключ сервера заново — если в этот момент кто-то подменит сервер, подмену оно не заметит.")
        }
        // Фоновая проверка входа по ключу: через секунду после того, как адрес, порт, логин или ключ перестали меняться.
        .task(id: "\(draft.hostTrimmed)|\(draft.sshPort)|\(draft.adminTrimmed)|\(draft.adminKey)") {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await m.probeAccess(currentDraft())
        }
    }

    // MARK: настройка

    private var needPassword: Bool { m.access == .needPassword }
    private var hostEmpty: Bool { draft.hostTrimmed.isEmpty }
    /// В поле адреса — уже настроенный сервер: повторная настройка только после подтверждения.
    private var alreadySetUp: Bool { m.config.isComplete && draft.hostTrimmed == m.config.hostTrimmed }

    /// «Настроить сервер» без адреса: коротко подсветить поле адреса и поставить в него курсор.
    private func showHostMissing() {
        hostFocused = true
        flashHost = true
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            flashHost = false
        }
    }

    /// Кнопка доступна всегда, кроме самой настройки: ключ или пароль выберет сама настройка
    /// (сначала ключ, затем пароль, если он введён).
    private var canSetup: Bool { !draft.hostTrimmed.isEmpty && !m.setupBusy }

    @ViewBuilder private var accessRow: some View {
        switch m.access {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Проверяю вход по ключу…").font(.caption) }
        case .key(let root):
            Label("Ваш ключ подходит (\(draft.adminTrimmed)\(root ? "" : ", через sudo")) — пароль не нужен.",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(Palette.green)
        case .needPassword:
            Label("Вашего ключа на сервере нет — войдите логином и паролем от сервера.", systemImage: "key")
                .font(.caption).foregroundColor(Palette.orange)
        case .failed(let e):
            HStack {
                Label(e, systemImage: "xmark.circle.fill").font(.caption).foregroundColor(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Повторить") { Task { await m.probeAccess(currentDraft()) } }
            }
        }
    }

    @ViewBuilder private var autoTab: some View {
        Text("Приложение само зайдёт на сервер (Ubuntu или Debian), поставит прокси и заведёт пользователя, которому разрешён только туннель.")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
        accessRow
        if needPassword {
            TextField("Логин", text: $draft.adminUser)
            SecureField("Пароль", text: $password)
            Toggle("Создать ключ для входа и добавить его на сервер", isOn: $makeAdminKey)
            Text("Тогда в следующий раз пароль не понадобится, а вход по паролю можно будет выключить. Пароль нигде не сохраняется.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button {
                if hostEmpty { showHostMissing() } else if alreadySetUp { confirmResetup = true } else { runSetup() }
            } label: {
                HStack(spacing: 6) {
                    if m.setupBusy { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                    Text(m.setupBusy ? "Настраиваю…" : (alreadySetUp ? "Настроить заново…" : "Настроить сервер"))
                }
            }
                .buttonStyle(.borderedProminent)
                .disabled(!hostEmpty && !canSetup)
        }
        if !m.setupSteps.isEmpty {
            VStack(spacing: 0) { ForEach(m.setupSteps) { StepRow(step: $0) } }
            if m.setupDone {
                Text("Готово. Туннель включён — перезапустите Claude, если он был открыт.")
                    .font(.caption).foregroundColor(Palette.green)
            }
        }
    }

    @ViewBuilder private var manualTab: some View {
        Text("Если приложению на сервер не зайти (вход только через консоль хостинга): скопируйте команду, вставьте её в консоль сервера под root или пользователем с sudo и дождитесь строки «сервер готов». Затем «Сохранить» внизу.")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
        HStack {
            if !keyExists { Button("Создать ключ туннеля") { createKey() }.buttonStyle(.borderedProminent) }
            Button("Скопировать команду для сервера") { copyServerScript() }.disabled(!keyExists)
        }
    }

    // MARK: доступ к серверу

    private var accessSection: some View {
        Section {
            LabeledContent("Вход по ключу") {
                switch m.keyStable {
                case .none: Text("не проверен").foregroundColor(.secondary)
                case .some(true): Text(m.keyCheckedHow.isEmpty ? "стабилен, 3 из 3" : "работает (\(m.keyCheckedHow))")
                    .foregroundColor(Palette.green)
                case .some(false): Text("не прошёл").foregroundColor(Palette.red)
                }
            }
            LabeledContent("Вход по паролю") {
                switch m.passwordLogin {
                case .none: Text("неизвестно").foregroundColor(.secondary)
                case .some(true): Text("включён").foregroundColor(Palette.orange)
                case .some(false): Text("выключен").foregroundColor(Palette.green)
                }
            }
            HStack {
                Button("Проверить соединение") { Task { await m.checkConnection() } }
                Button("Выключить вход по паролю") { Task { await m.disablePasswordLogin() } }
                    .disabled(m.keyStable != true || m.passwordLogin == false)
                if m.accessBusy { ProgressView().controlSize(.small).padding(.leading, 6) }
            }
            .disabled(m.accessBusy)
            if m.keyDenied || (m.access == .needPassword && !m.setupBusy) {
                Text("Входа по ключу нет — его можно создать: приложение сделает ключ и добавит его на сервер по паролю.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Пароль \(m.config.adminTrimmed)", text: $accessPassword)
                    Button("Создать ключ и добавить") {
                        let pw = accessPassword
                        Task { await m.addAdminKeyNow(password: pw); accessPassword = "" }
                    }
                    .disabled(accessPassword.isEmpty || m.accessBusy)
                }
            }
            if !m.accessNote.isEmpty {
                Text(m.accessNote).font(.caption).foregroundColor(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Выключить вход по паролю можно только после трёх успешных входов по ключу подряд — иначе легко потерять доступ к серверу.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: { Text("Доступ к серверу") }
    }

    // MARK: действия

    private func currentDraft() -> Config {
        var c = draft
        c.host = c.hostTrimmed
        c.domains = domainsText.split(separator: "\n").map(String.init)
        c.domains = c.cleanDomains
        return c.keepingToggles(of: m.config)   // галочки — не часть черновика, действуют сразу
    }

    /// Есть ли в окне несохранённые правки (пароль в настройки не входит и не сбрасывается вовсе).
    private var edited: Bool { loaded && currentDraft() != m.config }

    private func loadIfUntouched() {
        if !edited { load() }
    }

    private func load() {
        loaded = true
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
        let pw = needPassword ? password : ""
        let addKey = makeAdminKey
        note = ""
        Task {
            await m.setupServer(c, password: pw, makeAdminKey: addKey)
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

    private func copyServerScript() {
        guard let k = m.publicKey(for: draft.keyPath) else { note = "Нет файла \(draft.keyPath).pub"; return }
        guard let cmd = ServerScript.manualCommand(currentDraft(), publicKey: k) else {
            note = "В приложении нет скрипта сервера — пересоберите его build.sh."; return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        note = "Команда скопирована. Вставьте её в консоль сервера, дождитесь «сервер готов», затем «Сохранить»."
    }

}

/// Только один экземпляр. «Открывать при входе» запоминается за каждой копией приложения отдельно
/// (SMAppService — по пути), поэтому после обновления или пересборки при входе стартуют сразу две копии:
/// два значка, два ssh на одном пробросе гасят друг друга, PAC-порт держит та, что успела первой.
/// Все копии выбирают одного победителя одинаково: новее сборка → лежит в /Applications → раньше запущена (меньше pid).
/// Проигравший молча выходит до создания Model; победитель закрывает остальных — и старые копии без этой проверки —
/// и ждёт их выхода: старая копия при выходе снимает системные настройки, это должно случиться до наших.
@MainActor
enum SingleInstance {
    private struct Rank: Comparable {
        let build: Int, inApplications: Bool, pid: pid_t
        static func < (a: Rank, b: Rank) -> Bool {
            if a.build != b.build { return a.build < b.build }
            if a.inApplications != b.inApplications { return !a.inApplications }
            return a.pid > b.pid
        }
    }

    private static func rank(_ a: NSRunningApplication) -> Rank {
        let url = a.bundleURL
        let info = url.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
        let build = Int(info?["CFBundleVersion"] as? String ?? "") ?? 0
        let inApps = url?.path.hasPrefix("/Applications/") ?? false
        return Rank(build: build, inApplications: inApps, pid: a.processIdentifier)
    }

    static func resolve(then proceed: @escaping @MainActor () -> Void) {
        let me = NSRunningApplication.current
        guard let id = Bundle.main.bundleIdentifier else { return proceed() }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return proceed() }

        let mine = rank(me)
        if others.contains(where: { rank($0) > mine }) {
            Log.append("Уже запущена более новая или основная копия Proxy Tunnel — эта (\(Bundle.main.bundlePath)) выходит")
            exit(0)
        }
        for o in others {
            Log.append("Закрываю вторую копию Proxy Tunnel: \(o.bundleURL?.path ?? "pid \(o.processIdentifier)")")
            o.terminate()
        }
        let pids = others.map(\.processIdentifier)
        DispatchQueue.global().async {
            let alive = { pids.filter { kill($0, 0) == 0 } }
            for _ in 0..<50 where !alive().isEmpty { usleep(100_000) }
            for p in alive() { kill(p, SIGKILL) }
            DispatchQueue.main.async { proceed() }
        }
    }
}

/// Значок в строке меню и панель под ним — своими силами, а не MenuBarExtra:
/// панель MenuBarExtra нельзя открыть из кода, а её нужно показать сразу при запуске.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var watch: AnyCancellable?
    private var dotView: NSView?
    private var model: Model?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstance.resolve { [weak self] in self?.setUp() }
    }

    private func setUp() {
        let m = Model()
        model = m
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        self.item = item

        let hc = NSHostingController(rootView: PanelView(m: m))
        hc.sizingOptions = [.preferredContentSize]   // панель растёт и сжимается вместе с содержимым
        popover.contentViewController = hc
        popover.behavior = .transient                 // щелчок мимо — закрывается, как у меню
        popover.animates = false

        setIcon(m.icon, m.dot)
        watch = m.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.setIcon(m.icon, m.dot) }
        }
        // Настроенный туннель: сразу показать панель (туннель при запуске выключен — включают по карточке).
        // Ненастроенный: как раньше, откроется окно настроек.
        if m.config.isComplete {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPanel() }
        }
    }

    /// Значок — как был (шаблонный, его рисует система); точка состояния — отдельным слоем в правом нижнем углу.
    private func setIcon(_ name: String, _ dot: Model.Dot?) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Proxy Tunnel")
        img?.isTemplate = true
        guard let b = item?.button else { return }
        b.image = img
        let d: CGFloat = 7
        if dotView == nil {
            let v = NSView(frame: .zero)
            v.wantsLayer = true
            v.layer?.cornerRadius = d / 2
            b.addSubview(v)
            dotView = v
        }
        guard let v = dotView else { return }
        v.frame = NSRect(x: b.bounds.maxX - d - 2, y: b.isFlipped ? b.bounds.maxY - d - 2 : 2, width: d, height: d)
        v.isHidden = dot == nil
        let c: NSColor
        switch dot {
        case .green: c = NSColor(srgbRed: 0.20, green: 0.70, blue: 0.40, alpha: 1)
        case .yellow: c = NSColor(srgbRed: 0.96, green: 0.74, blue: 0.10, alpha: 1)
        case .red, .none: c = NSColor(srgbRed: 0.90, green: 0.25, blue: 0.25, alpha: 1)
        }
        v.layer?.backgroundColor = c.cgColor
        b.setAccessibilityLabel("Proxy Tunnel: " + (dot == .green ? "всё через туннель" : dot == .yellow ? "туннель работает с оговоркой" : dot == .red ? "туннель выключен или не работает" : "не настроен"))
    }

    func showPanel() {
        guard let b = item?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePanel() {
        popover.isShown ? popover.performClose(nil) : showPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Model.current?.removeSystemSettingsSync()
        Model.current?.tunnel.stop()
        Model.current?.pac.stop()
    }
}

@main
struct ProxyTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }   // окон у приложения нет: значок и панель — в AppDelegate
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
            // Form в окне не сообщает свою высоту — без явного размера окно сжимается до одной шапки.
            let hc = NSHostingController(rootView: SettingsView(m: m))
            hc.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: hc)
            w.title = "Настройки Proxy Tunnel"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 500, height: 760))
            w.isReleasedWhenClosed = false   // закрыли — окно и введённое в нём остаются до следующего показа
            w.hidesOnDeactivate = false      // переключились на другое окно — настройки не прячутся
            w.center()
            window = w
        } else {
            NotificationCenter.default.post(name: shown, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
