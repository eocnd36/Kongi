import ClaudeUsageCore
import SwiftUI

// Kongi 창의 설정 화면들과 공통 부품. 모두 같은 UserDefaults 키를 씁니다.

// MARK: - 공통 부품

/// 한 화면: 제목, 설명, 내용 (세로 스크롤)
struct KPage<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: title)
                            .font(.system(size: 24, weight: .bold))
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(KongiTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    trailing()
                }
                content()
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

extension KPage where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// 어두운 둥근 카드
struct KCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(KongiTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KongiTheme.line))
    }
}

/// 카드 위의 작은 대문자 제목
struct KLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text.uppercased(with: Formatters.appLocale))
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(KongiTheme.muted)
    }
}

/// 설정 한 줄: 왼쪽에 제목과 설명, 오른쪽에 조작
struct KRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 13.5, weight: .medium))
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(KongiTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

struct KDivider: View {
    var body: some View { Rectangle().fill(KongiTheme.line).frame(height: 1) }
}

/// 켜고 끄는 줄
struct KToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        KRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(KongiTheme.accent)
                .controlSize(.small)
        }
    }
}

/// 둥근 알약 버튼: 강조(민트) 또는 기본(유리)
struct KButton: View {
    let title: String
    var symbol: String?
    var style: Style = .secondary
    let action: () -> Void

    enum Style { case primary, secondary, destructive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(style == .primary ? KongiTheme.onAccent : style == .destructive ? KongiTheme.red : KongiTheme.text)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .kongiGlass(Capsule(), tint: style == .primary ? KongiTheme.accent : nil, interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
    }
}

/// 메뉴로 고르는 칸
struct KMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(verbatim: option.1).tag(option.0)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(AppSettings.menuBarStyle) private var styleRaw = MenuBarStyle.sessionAndWeekly.rawValue
    @AppStorage(AppSettings.refreshMinutes) private var refreshMinutes = 5
    @AppStorage(AppSettings.menuBarCodex) private var showCodex = true
    @ObservedObject private var tasks = AppServices.shared.tasks
    @AppStorage(AppSettings.checkForUpdates) private var checkForUpdates = true
    @AppStorage(AppSettings.autoInstallUpdates) private var autoInstallUpdates = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var language = AppLanguage.override ?? ""

    var body: some View {
        KPage(title: String(localized: "General")) {
            KLabel(String(localized: "Account"))
            KCard { AccountSection() }

            KLabel(String(localized: "Menu bar"))
            KCard {
                KRow(title: String(localized: "Menu bar")) {
                    KMenu(selection: $styleRaw, options: MenuBarStyle.allCases.map { ($0.rawValue, $0.title) })
                }
                if styleRaw == MenuBarStyle.hidden.rawValue {
                    Text("To open Settings later, use the gear in the island or open Kongi again from Applications.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if tasks.widgets.contains(where: { $0.id == "codex-5h" }) {
                    KDivider()
                    KToggleRow(title: String(localized: "Show Codex usage"),
                               detail: String(localized: "Adds your Codex 5-hour limit from the Codex extension."), isOn: $showCodex)
                }
                KDivider()
                KRow(title: String(localized: "Refresh every")) {
                    KMenu(selection: $refreshMinutes, options: AppSettings.refreshOptions.map { minutes in (minutes, String(localized: "\(minutes) min")) })
                }
            }

            KLabel(String(localized: "App"))
            KCard {
                KRow(title: String(localized: "Language")) {
                    KMenu(selection: $language, options: [("", String(localized: "System default"))]
                        + AppLanguage.supported.map { ($0, AppLanguage.nativeName($0)) })
                }
                KDivider()
                KToggleRow(title: String(localized: "Launch at login"), detail: loginItemError, isOn: $launchAtLogin)
                KDivider()
                KToggleRow(title: String(localized: "Update notifications"),
                           detail: String(localized: "Tell me when a new version of Kongi is out."), isOn: $checkForUpdates)
                KDivider()
                KToggleRow(title: String(localized: "Install updates automatically"),
                           detail: String(localized: "Downloads and installs new versions, then reopens Kongi. Waits until Claude isn't working."),
                           isOn: $autoInstallUpdates)
            }
        }
        .onChange(of: language) { code in AppLanguage.set(code.isEmpty ? nil : code) }
        .onChange(of: refreshMinutes) { _ in store.startPolling() }
        .onChange(of: checkForUpdates) { _ in AppServices.shared.updater.start() }
        .onChange(of: autoInstallUpdates) { _ in AppServices.shared.updater.start() }
        .onChange(of: launchAtLogin) { enabled in
            guard enabled != LoginItem.isEnabled else { return }
            do {
                try LoginItem.setEnabled(enabled)
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
                launchAtLogin = LoginItem.isEnabled
            }
        }
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(AppSettings.notificationsEnabled) private var usageAlertsEnabled = true
    @AppStorage(AppSettings.alertThresholdsKey) private var thresholdsRaw = "80,95"
    @AppStorage(AppSettings.resetReminderEnabled) private var resetReminderEnabled = true
    @AppStorage(AppSettings.resetReminderMinutes) private var resetReminderMinutes = 15
    @AppStorage(AppSettings.notifyOnReset) private var notifyOnReset = false
    @AppStorage(AppSettings.resetReminderMinimumPercent) private var minimumPercent = 50
    @AppStorage(AppSettings.statusAlertsEnabled) private var statusAlertsEnabled = true
    @AppStorage(AppSettings.notificationSound) private var notificationSound = true
    @AppStorage(AppSettings.agentNotifications) private var agentNotifications = true
    @State private var testSent = false

    var body: some View {
        KPage(title: String(localized: "Notifications")) {
            if store.notificationsDenied {
                PermissionWarning()
            }
            KLabel(String(localized: "Usage"))
            KCard {
                KToggleRow(title: String(localized: "Usage alerts"), isOn: $usageAlertsEnabled)
                if usageAlertsEnabled {
                    KRow(title: String(localized: "Alert at")) { ThresholdEditor(raw: $thresholdsRaw) }
                }
                KDivider()
                KToggleRow(title: String(localized: "Remind before a limit resets"), isOn: $resetReminderEnabled)
                if resetReminderEnabled {
                    KRow(title: String(localized: "Minutes before")) {
                        NumberField(value: $resetReminderMinutes, range: AppSettings.resetReminderMinutesRange)
                    }
                }
                KDivider()
                KToggleRow(title: String(localized: "Notify when a limit resets"), isOn: $notifyOnReset)
                if resetReminderEnabled || notifyOnReset {
                    KRow(title: String(localized: "Only for limits used at least")) {
                        HStack(spacing: 4) {
                            NumberField(value: $minimumPercent, range: AppSettings.minimumPercentRange)
                            Text(verbatim: "%").foregroundStyle(KongiTheme.secondary)
                        }
                    }
                }
            }
            KLabel(String(localized: "Claude"))
            KCard {
                KToggleRow(title: String(localized: "Notify when Claude finishes or needs you"), isOn: $agentNotifications)
                KDivider()
                KToggleRow(title: String(localized: "Alert me when Claude has an outage"), isOn: $statusAlertsEnabled)
            }
            KLabel(String(localized: "Sound"))
            KCard {
                KToggleRow(title: String(localized: "Play a sound with notifications"), isOn: $notificationSound)
                KDivider()
                HStack {
                    Spacer()
                    KButton(title: testSent ? String(localized: "Sent") : String(localized: "Send test notification"), symbol: "bell") {
                        Notifier.requestAuthorization()
                        Notifier.post(
                            title: String(localized: "Test notification"),
                            body: String(localized: "Notifications from Kongi are working.")
                        )
                        testSent = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await store.refreshNotificationPermission()
                            testSent = false
                        }
                    }
                }
            }
        }
        .task { await store.refreshNotificationPermission() }
        .onChange(of: resetReminderEnabled) { _ in changed() }
        .onChange(of: resetReminderMinutes) { _ in changed() }
        .onChange(of: notifyOnReset) { _ in changed() }
        .onChange(of: minimumPercent) { _ in changed() }
        .onChange(of: usageAlertsEnabled) { _ in changed() }
        .onChange(of: statusAlertsEnabled) { _ in changed() }
    }

    private func changed() {
        if AppSettings.wantsNotifications { Notifier.requestAuthorization() }
        store.scheduleResetReminders()
        Task { await store.refreshNotificationPermission() }
    }
}

// MARK: - Island

struct IslandPane: View {
    @AppStorage(AppSettings.islandEnabled) private var islandEnabled = true
    @AppStorage(AppSettings.islandAutoHide) private var islandAutoHide = false
    @AppStorage(AppSettings.islandModeKey) private var islandMode = IslandMode.claude.rawValue
    @AppStorage(AppSettings.showSystemStats) private var showSystemStats = true
    @AppStorage(AppSettings.islandShowsDevices) private var showsDevices = true
    @AppStorage(AppSettings.islandShowsCharging) private var showsCharging = true
    @AppStorage(AppSettings.islandShowsPrivacy) private var showsPrivacy = true
    @AppStorage(AppSettings.islandShowsVolume) private var showsVolume = false

    var body: some View {
        KPage(title: String(localized: "Island"), subtitle: String(localized: "The island lives where the notch is and widens when something needs you.")) {
            KCard {
                KToggleRow(title: String(localized: "Show the island"), isOn: $islandEnabled)
                if islandEnabled {
                    KDivider()
                    IslandModePicker(selection: $islandMode)
                    if islandMode == IslandMode.claude.rawValue {
                        KDivider()
                        KToggleRow(title: String(localized: "Hide it when no sessions are running"), isOn: $islandAutoHide)
                    }
                    KDivider()
                    KToggleRow(title: String(localized: "Show CPU, GPU, memory and storage in the island"), isOn: $showSystemStats)
                }
            }
            if islandEnabled, islandMode == IslandMode.dynamic.rawValue {
                KLabel(String(localized: "Also show on the island"))
                KCard {
                    KToggleRow(title: String(localized: "AirPods and other audio devices connecting"), isOn: $showsDevices)
                    KDivider()
                    KToggleRow(title: String(localized: "Charging and low battery"), isOn: $showsCharging)
                    KDivider()
                    KToggleRow(title: String(localized: "Microphone or camera in use"), isOn: $showsPrivacy)
                    KDivider()
                    KToggleRow(title: String(localized: "Volume changes"), isOn: $showsVolume)
                }
                Text("Like the iPhone, the island briefly widens for these and then goes back to what it was showing.")
                    .font(.system(size: 12))
                    .foregroundStyle(KongiTheme.secondary)
            }
        }
    }
}

/// 아일랜드 모드: 두 가지를 그림과 함께 고릅니다.
struct IslandModePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(IslandMode.allCases) { mode in
                let selected = selection == mode.rawValue
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = mode.rawValue }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04))
                            HStack(spacing: 6) {
                                if mode == .claude {
                                    Circle().fill(KongiTheme.accent).frame(width: 12, height: 12)
                                    Capsule().fill(Color.white.opacity(0.5)).frame(width: 40, height: 4)
                                } else {
                                    RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.pink, .orange], startPoint: .top, endPoint: .bottom))
                                        .frame(width: 14, height: 14)
                                    Capsule().fill(Color.white.opacity(0.5)).frame(width: 34, height: 4)
                                    EqualizerBars(playing: false, height: 10)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(Color.black))
                        }
                        .frame(height: 64)
                        Text(verbatim: mode.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KongiTheme.text)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KongiTheme.field))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? KongiTheme.accent : KongiTheme.line, lineWidth: selected ? 2 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(IslandPressStyle())
            }
        }
    }
}

// MARK: - Claude Code

struct ClaudeCodePane: View {
    @AppStorage(AppSettings.approvalsInIsland) private var approvalsInIsland = true
    @AppStorage(AppSettings.approvalFallbackSeconds) private var fallbackSeconds = 60
    @AppStorage(AppSettings.historyRetentionDaysKey) private var historyDays = 7
    @State private var installed = HookInstaller.isInstalled
    @State private var canContinue = HookInstaller.canContinue

    var body: some View {
        KPage(title: "Claude Code", subtitle: String(localized: "Shows what Claude Code is doing in the island at the top of the screen, and lets you approve requests and answer questions there.")) {
            KCard {
                HStack(spacing: 12) {
                    Image(systemName: installed ? (canContinue ? "checkmark.circle.fill" : "arrow.up.circle.fill") : "circle.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(installed ? (canContinue ? KongiTheme.green : KongiTheme.orange) : KongiTheme.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(installed ? String(localized: "Connected to Claude Code") : String(localized: "Not connected to Claude Code"))
                            .font(.system(size: 14, weight: .semibold))
                        if installed, !canContinue {
                            Text("Update the connection so “Continue after reset” and prompts from your phone go into the same conversation, including in VS Code.")
                                .font(.system(size: 12))
                                .foregroundStyle(KongiTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if installed, !canContinue {
                        KButton(title: String(localized: "Update"), style: .primary) {
                            HookSetupFlow.run()
                            refresh()
                        }
                    }
                    KButton(title: installed ? String(localized: "Remove") : String(localized: "Connect"), style: installed ? .secondary : .primary) {
                        if installed { _ = HookSetupFlow.uninstall() } else { HookSetupFlow.run() }
                        refresh()
                    }
                }
            }
            KLabel(String(localized: "Approvals"))
            KCard {
                KToggleRow(title: String(localized: "Answer approvals and questions in the island"), isOn: $approvalsInIsland)
                if approvalsInIsland {
                    KDivider()
                    KRow(title: String(localized: "If unanswered, ask in terminal after")) {
                        KMenu(selection: $fallbackSeconds, options: AppSettings.approvalFallbackOptions.map {
                            ($0, $0 == 0 ? String(localized: "Never") : Formatters.countdownSeconds($0))
                        })
                    }
                }
            }
            KLabel(String(localized: "History"))
            KCard {
                KRow(title: String(localized: "Keep session history")) {
                    KMenu(selection: $historyDays, options: AppSettings.historyRetentionOptions.map { days in
                        (days, days == 0 ? String(localized: "Don't keep") : String(localized: "\(days) days"))
                    })
                }
                KDivider()
                HStack {
                    Spacer()
                    KButton(title: String(localized: "Delete session history"), symbol: "trash", style: .destructive) {
                        AppServices.shared.agents.clearHistory()
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: historyDays) { _ in
            AppServices.shared.agents.applyRetention()
            AppServices.shared.agents.saveHistory()
        }
    }

    private func refresh() {
        installed = HookInstaller.isInstalled
        canContinue = HookInstaller.canContinue
    }
}

// MARK: - Phone

struct PhonePane: View {
    @ObservedObject var mobile: MobileBridge

    var body: some View {
        KPage(title: String(localized: "Phone")) {
            PhoneSection(mobile: mobile)
        }
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            // 콩이는 옆 막대에 있으므로 여기서는 앱 아이콘으로
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(verbatim: "Kongi").font(.system(size: 28, weight: .bold))
            Text("Version \(AppInfo.version)").foregroundStyle(KongiTheme.secondary)
            if AppServices.shared.updater.isSupported {
                UpdateSection(updater: AppServices.shared.updater)
                    .padding(.vertical, 6)
            }
            if let url = AppInfo.repositoryURL {
                HStack(spacing: 8) {
                    KButton(title: String(localized: "Send feedback"), symbol: "bubble.left.and.text.bubble.right") {
                        if let feedback = Self.feedbackURL(repository: url) { NSWorkspace.shared.open(feedback) }
                    }
                    KButton(title: "GitHub", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                }
            }
            Text("Unofficial app. Not affiliated with Anthropic.")
                .font(.system(size: 12))
                .foregroundStyle(KongiTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    /// GitHub 새 이슈 화면을 버전·macOS·언어만 채워 엽니다 (그 밖의 정보는 보내지 않음, 사용자가 보고 직접 올림).
    static func feedbackURL(repository: URL) -> URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let language = AppLanguage.override ?? Bundle.main.preferredLocalizations.first ?? "en"
        let body = """
        **What happened / what would you like?**


        **Steps to reproduce (for bugs)**


        ---
        Kongi \(AppInfo.version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(language)
        """
        var components = URLComponents(url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        return components?.url
    }
}

// MARK: - 작은 부품

/// 알림이 꺼져 있을 때 시스템 설정으로 안내합니다.
private struct PermissionWarning: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill").foregroundStyle(KongiTheme.orange)
            Text("Notifications are turned off for this app.")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            KButton(title: String(localized: "Open Notification Settings")) { Notifier.openSystemSettings() }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KongiTheme.orange.opacity(0.12)))
    }
}

/// 사용량 알림 기준(%)을 직접 추가하고 지우는 편집기
private struct ThresholdEditor: View {
    @Binding var raw: String
    @State private var draft = ""
    @State private var invalid = false

    private var values: [Int] { AppSettings.parseThresholds(raw) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                HStack(spacing: 4) {
                    Text(verbatim: "\(value)%").monospacedDigit()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            raw = AppSettings.formatThresholds(values.filter { $0 != value })
                        }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KongiTheme.secondary)
                }
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(KongiTheme.field))
                .transition(.scale.combined(with: .opacity))
            }
            if values.count < AppSettings.maxAlertThresholds {
                TextField(text: $draft, prompt: Text(verbatim: "%")) { EmptyView() }
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 40, height: 26)
                    .background(Capsule().fill(KongiTheme.field))
                    .overlay(Capsule().stroke(KongiTheme.red, lineWidth: invalid ? 1 : 0))
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(KongiTheme.field))
                }
                .buttonStyle(IslandPressStyle())
                .disabled(draft.isEmpty)
            }
        }
    }

    private func add() {
        let trimmed = draft.trimmingCharacters(in: CharacterSet(charactersIn: " %"))
        guard let value = Int(trimmed), (1...100).contains(value) else {
            invalid = true
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            raw = AppSettings.formatThresholds(values + [value])
        }
        draft = ""
        invalid = false
    }
}

/// 직접 입력하거나 +/−로 조절하는 숫자 칸. 범위를 벗어나면 가장 가까운 값으로 맞춥니다.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            step("minus", -1)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 44)
            step("plus", 1)
        }
        .frame(height: 28)
        .background(Capsule().fill(KongiTheme.field))
        .onChange(of: value) { newValue in
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            if clamped != newValue { value = clamped }
        }
    }

    private func step(_ symbol: String, _ delta: Int) -> some View {
        Button {
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
        .foregroundStyle(KongiTheme.secondary)
    }
}

/// 연결된 계정 정보와 연결 / 연결 해제(로그아웃)
private struct AccountSection: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        if store.isConnected {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(KongiTheme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: store.profile?.displayName ?? store.profile?.email ?? String(localized: "Connected"))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let email = store.profile?.email, email != store.profile?.displayName {
                        Text(verbatim: email)
                            .font(.system(size: 12))
                            .foregroundStyle(KongiTheme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let plan = store.credentials?.planName {
                        Text(verbatim: plan)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(KongiTheme.accent)
                    }
                }
                Spacer(minLength: 0)
                KButton(title: String(localized: "Disconnect"), symbol: "rectangle.portrait.and.arrow.right", style: .destructive) {
                    store.disconnect()
                }
            }
            Text("Removes this account's data from the app. Your Claude Code login is not affected.")
                .font(.system(size: 12))
                .foregroundStyle(KongiTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Not connected").foregroundStyle(KongiTheme.secondary)
        }
    }
}
