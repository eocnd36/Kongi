import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 펼친 아일랜드의 도구 줄 (집중 타이머, 다음 회의, GitHub, 서버, 클립보드)

struct IslandToolbox: View {
    @ObservedObject var focus = AppServices.shared.focus
    @ObservedObject var meetings = AppServices.shared.meetings
    @ObservedObject var github = AppServices.shared.github
    @ObservedObject var ports = AppServices.shared.ports
    @ObservedObject var clipboard = AppServices.shared.clipboard
    @ObservedObject var tasks = AppServices.shared.tasks
    @State private var showsClipboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // kongi run으로 돌고 있는 빌드·테스트 (백그라운드 작업)
            ForEach(tasks.running) { task in
                ToolRow(symbol: "hammer.fill", tint: KongiTheme.orange) { TaskRow(task: task) } trailing: { EmptyView() }
            }
            FocusRow(focus: focus)
            if let meeting = meetings.next, meeting.start.timeIntervalSinceNow < 3 * 3600 {
                ToolRow(symbol: "video.fill", tint: Color(red: 0.4, green: 0.7, blue: 1.0)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: meeting.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(verbatim: Formatters.scheduleTime(meeting.start, now: Date()))
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                } trailing: {
                    if let url = meeting.url {
                        IslandPillButton(title: String(localized: "Join"), style: .primary) { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if !github.items.isEmpty {
                ToolRow(symbol: "arrow.triangle.pull", tint: Color(red: 0.6, green: 0.55, blue: 1.0)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(localized: "GitHub · \(github.items.count)")).font(.system(size: 12, weight: .semibold))
                        Text(verbatim: github.items.first?.title ?? "")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                } trailing: {
                    IslandTextButton(title: String(localized: "Open"), symbol: "arrow.up.right") {
                        if let url = github.items.first?.url ?? URL(string: "https://github.com/notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if !ports.states.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).frame(width: 22)
                    ForEach(ports.states.keys.sorted(), id: \.self) { port in
                        let open = ports.states[port] == true
                        Button {
                            if open, let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(open ? KongiTheme.green : KongiTheme.red).frame(width: 6, height: 6)
                                Text(verbatim: "\(port)").font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(IslandPressStyle())
                    }
                    Spacer(minLength: 0)
                }
            }
            if !clipboard.items.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showsClipboard.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 11)).frame(width: 22)
                        Text(String(localized: "Clipboard · \(clipboard.items.count)")).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showsClipboard ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsClipboard {
                    ForEach(clipboard.items, id: \.self) { text in
                        Button { clipboard.copy(text) } label: {
                            Text(verbatim: text.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .islandHoverRow(cornerRadius: 8, base: 0.04)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }
}

private struct ToolRow<Content: View, Trailing: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 22)
            content()
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .islandHoverRow()
    }
}

/// 집중 타이머: 시작, 남은 시간 고리, 멈춤
struct FocusRow: View {
    @ObservedObject var focus: FocusTimer
    @AppStorage(AppSettings.focusMinutes) private var minutes = 25

    var body: some View {
        ToolRow(symbol: focus.phase == .rest ? "cup.and.saucer.fill" : "timer", tint: KongiTheme.accent) {
            if focus.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        TimerRing(progress: focus.progress(at: context.date), size: 16)
                        Text(verbatim: Self.clock(focus.remaining(at: context.date)))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(focus.phase == .rest ? String(localized: "Break") : focus.phase == .timer ? String(localized: "Timer") : String(localized: "Focus"))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            } else {
                Text(String(localized: "Focus \(minutes) min")).font(.system(size: 12, weight: .semibold))
            }
        } trailing: {
            if focus.isRunning {
                IslandTextButton(title: String(localized: "Stop"), symbol: "stop.fill") { focus.stop() }
            } else {
                // 몇 분짜리 타이머 (아일랜드에서 남은 시간을 보여 주고 끝나면 알림)
                Menu {
                    ForEach([1, 3, 5, 10, 15, 30, 60], id: \.self) { minutes in
                        Button(String(localized: "\(minutes) min")) { focus.startTimer(minutes: minutes) }
                    }
                } label: {
                    Image(systemName: "timer").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Timer"))
                IslandPillButton(title: String(localized: "Start"), style: .secondary) { focus.start() }
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TimerRing: View {
    let progress: Double
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: size * 0.16)
            Circle()
                .trim(from: 0, to: 1 - progress)
                .stroke(KongiTheme.accent, style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 1), value: progress)
    }
}

/// 세션마다 점 하나: 일하는 중이면 숨 쉬고, 확인이 필요하면 노란색
struct SessionDots: View {
    let sessions: [AgentSession]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(sessions.prefix(4)) { session in
                PulsingDot(color: session.state.color, size: 5, pulses: session.state.isBusy || session.state.needsAttention)
                    .id("\(session.id)-\(session.state.isBusy || session.state.needsAttention)")
            }
        }
        .help(Text(verbatim: sessions.prefix(4).map { "\($0.projectName): \($0.state.label)" }.joined(separator: "\n")))
    }
}

// MARK: - 끌어 놓기: 파일을 섬에 놓으면 대화 입력 칸에 경로가 붙습니다.

struct IslandDropModifier: ViewModifier {
    @ObservedObject var model: IslandModel
    @EnvironmentObject private var agents: AgentStore
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(KongiTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted.animation(.easeOut(duration: 0.15))) { providers in
                guard let target = targetSession else { return false }
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            agents.appendDraft(url.path, to: target)
                            withAnimation(IslandModel.morph) {
                                model.expanded = true
                                model.pinned = true
                            }
                            model.navigate(to: .session(target))
                        }
                    }
                }
                return true
            }
    }

    /// 보고 있는 대화, 없으면 가장 최근에 움직인 대화
    private var targetSession: String? {
        if case let .session(id) = model.route { return id }
        if case let .diff(id, _) = model.route { return id }
        return agents.activeSessions.first?.id
    }
}

// MARK: - 설정: 도구

struct ToolsPane: View {
    @AppStorage(AppSettings.islandShowsCompletion) private var showsCompletion = true
    @AppStorage(AppSettings.islandShowsPace) private var showsPace = true
    @AppStorage(AppSettings.focusMinutes) private var focusMinutes = 25
    @AppStorage(AppSettings.breakMinutes) private var breakMinutes = 5
    @AppStorage(AppSettings.githubEnabled) private var githubEnabled = false
    @AppStorage(AppSettings.watchedPorts) private var watchedPorts = ""
    @AppStorage(AppSettings.meetingsEnabled) private var meetingsEnabled = false
    @AppStorage(AppSettings.clipboardEnabled) private var clipboardEnabled = false
    @AppStorage(AppSettings.shellMinimumSeconds) private var shellSeconds = 10
    @AppStorage(AppSettings.systemAlerts) private var systemAlerts = true
    @AppStorage(AppSettings.iPhoneCalls) private var iPhoneCalls = false
    @AppStorage(AppSettings.iPhoneNotices) private var iPhoneNotices = false
    @ObservedObject private var meetings = AppServices.shared.meetings
    @State private var shellInstalled = ShellIntegration.isInstalled
    @State private var shellError: String?

    var body: some View {
        KPage(title: String(localized: "Tools"), subtitle: String(localized: "Extra things the island can do. Anything that needs a permission or touches your files is off until you turn it on.")) {
            KLabel(String(localized: "Your Mac"))
            KCard {
                KToggleRow(title: String(localized: "System alerts"),
                           detail: String(localized: "When your Mac runs hot, memory runs low or storage is almost full. At most once an hour each."),
                           isOn: $systemAlerts)
            }
            KLabel("iPhone")
            KCard {
                KToggleRow(title: String(localized: "Calls from iPhone"),
                           detail: String(localized: "Show who's calling in the island when your iPhone rings. Needs Calls from iPhone turned on in FaceTime or Phone."),
                           isOn: $iPhoneCalls)
                KDivider()
                KToggleRow(title: String(localized: "iPhone notifications"),
                           detail: String(localized: "Show notifications your iPhone sends to this Mac in the island. Needs iPhone Mirroring set up."),
                           isOn: $iPhoneNotices)
                if (iPhoneCalls || iPhoneNotices) && !AXIsProcessTrusted() {
                    KDivider()
                    KRow(title: String(localized: "Allow Kongi in Accessibility"),
                         detail: String(localized: "Kongi reads these banners on screen to show them in the island. Nothing leaves this Mac.")) {
                        KButton(title: String(localized: "Open Settings"), symbol: "lock.open") { PhoneBanners.openAccessibilitySettings() }
                    }
                }
            }
            KLabel("Claude Code")
            KCard {
                KToggleRow(title: String(localized: "Summary when Claude finishes"),
                           detail: String(localized: "Files, lines and time of the last request. Click it to open the conversation."),
                           isOn: $showsCompletion)
                KDivider()
                KToggleRow(title: String(localized: "Warn when usage runs out fast"),
                           detail: String(localized: "When the current pace would hit a limit before it resets."),
                           isOn: $showsPace)
                KDivider()
                Text("Drop files on the island to attach them to the conversation, and use the mic button in the message box to dictate.")
                    .font(.system(size: 12))
                    .foregroundStyle(KongiTheme.secondary)
            }

            KLabel(String(localized: "Focus timer"))
            KCard {
                KRow(title: String(localized: "Focus")) {
                    KMenu(selection: $focusMinutes, options: [15, 25, 30, 45, 50, 60, 90].map { minutes in (minutes, String(localized: "\(minutes) min")) })
                }
                KDivider()
                KRow(title: String(localized: "Break")) {
                    KMenu(selection: $breakMinutes, options: [3, 5, 10, 15, 20].map { minutes in (minutes, String(localized: "\(minutes) min")) })
                }
            }

            KLabel(String(localized: "Terminal"))
            KCard {
                KRow(title: String(localized: "Tell me when a long command finishes"),
                     detail: shellError ?? String(localized: "Adds a small block to ~/.zshrc (backed up first). Works in any terminal, also outside Claude Code.")) {
                    KButton(title: shellInstalled ? String(localized: "Remove") : String(localized: "Install"), style: shellInstalled ? .secondary : .primary) {
                        do {
                            if shellInstalled { try ShellIntegration.uninstall() } else { try ShellIntegration.install() }
                            shellError = nil
                        } catch {
                            shellError = error.localizedDescription
                        }
                        shellInstalled = ShellIntegration.isInstalled
                    }
                }
                if shellInstalled {
                    KDivider()
                    KRow(title: String(localized: "Only for commands longer than")) {
                        KMenu(selection: $shellSeconds, options: [5, 10, 30, 60, 300].map { seconds in (seconds, String(localized: "\(seconds)s")) })
                    }
                    Text("Open a new terminal window for it to take effect.")
                        .font(.system(size: 12))
                        .foregroundStyle(KongiTheme.secondary)
                }
                KDivider()
                KRow(title: String(localized: "Watch local servers"),
                     detail: String(localized: "Ports to check, like 3000, 5173. You'll see when a dev server goes down or comes back.")) {
                    TextField("3000, 5173", text: $watchedPorts)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(width: 170, height: 30)
                        .background(Capsule().fill(KongiTheme.field))
                }
            }

            KLabel(String(localized: "Connected"))
            KCard {
                KToggleRow(title: String(localized: "GitHub notifications"),
                           detail: GitHubWatcher.ghPath == nil
                               ? String(localized: "Needs the GitHub CLI (gh) signed in.")
                               : String(localized: "Review requests, CI and mentions, through the GitHub CLI you're signed in to."),
                           isOn: $githubEnabled)
                    .disabled(GitHubWatcher.ghPath == nil)
                KDivider()
                KToggleRow(title: String(localized: "Next meeting"),
                           detail: meetings.denied
                               ? String(localized: "Calendar access was denied. Allow it in System Settings → Privacy & Security → Calendars.")
                               : String(localized: "Shows meetings from your calendars 10 and 1 minutes before, with a Join button for Zoom, Meet and Teams links."),
                           isOn: $meetingsEnabled)
                KDivider()
                KToggleRow(title: String(localized: "Clipboard history"),
                           detail: String(localized: "Keeps the last 8 copied texts in memory only, to copy again from the island. Password managers' items are skipped."),
                           isOn: $clipboardEnabled)
            }
        }
        .onAppear { shellInstalled = ShellIntegration.isInstalled }
    }
}

// MARK: - 홈: 이번 주

struct WeeklyCard: View {
    @EnvironmentObject private var agents: AgentStore

    var body: some View {
        let stats = WeeklyStats.make(from: agents.sessions)
        KCard {
            WeeklyContent(stats: stats)
            HStack {
                Spacer()
                KButton(title: String(localized: "Save as image"), symbol: "square.and.arrow.down") { save(stats) }
            }
        }
    }

    private func save(_ stats: WeeklyStats) {
        let card = WeeklyContent(stats: stats, poster: true)
            .padding(32)
            .frame(width: 540)
            .background(KongiTheme.window)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kongi-week.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

private struct WeeklyContent: View {
    let stats: WeeklyStats
    var poster = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                // 앱 안에서는 콩이가 이미 보이므로, 공유용 그림에만 넣습니다.
                if poster { Kongi(mood: .happy, size: 34) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("This week with Claude").font(.system(size: poster ? 18 : 14, weight: .bold))
                    if let top = stats.topProject {
                        Text(String(localized: "Most active: \(top)"))
                            .font(.system(size: 12)).foregroundStyle(KongiTheme.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                stat(String(format: "%.1f", stats.hours), String(localized: "hours"))
                stat("\(stats.sessions)", String(localized: "sessions"))
                stat("\(stats.files)", String(localized: "files"))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(verbatim: "+\(stats.added)").foregroundStyle(KongiTheme.green)
                        Text(verbatim: "−\(stats.removed)").foregroundStyle(KongiTheme.red)
                    }
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("lines").font(.system(size: 11)).foregroundStyle(KongiTheme.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KongiTheme.field))
            }
        }
        .foregroundStyle(KongiTheme.text)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            Text(verbatim: label).font(.system(size: 11)).foregroundStyle(KongiTheme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KongiTheme.field))
    }
}
