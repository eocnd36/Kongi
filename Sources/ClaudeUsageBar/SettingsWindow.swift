import AppKit
import ClaudeUsageCore
import SwiftUI

/// Kongi 창: 사용량과 지금 하는 일을 보고, 승인하고, 대화를 이어 가고, 설정합니다.
/// 열려 있는 동안은 일반 앱처럼 Dock에 나타나고(⌘Tab으로 오갈 수 있음), 닫으면 메뉴 막대 앱으로 돌아갑니다.
@MainActor
enum SettingsWindow {
    enum Pane: String, CaseIterable, Identifiable {
        case home, sessions, schedules
        case general, notifications, island, claudeCode, tools, phone, about

        var id: String { rawValue }

        static let app: [Pane] = [.home, .sessions, .schedules]
        static let settings: [Pane] = [.general, .notifications, .island, .claudeCode, .tools, .phone, .about]

        var title: String {
            switch self {
            case .home: return String(localized: "Home")
            case .sessions: return String(localized: "Sessions")
            case .schedules: return String(localized: "Scheduled prompts")
            case .general: return String(localized: "General")
            case .notifications: return String(localized: "Notifications")
            case .island: return String(localized: "Island")
            case .claudeCode: return "Claude Code"
            case .tools: return String(localized: "Tools")
            case .phone: return String(localized: "Phone")
            case .about: return String(localized: "About")
            }
        }

        var symbol: String {
            switch self {
            case .home: return "house"
            case .sessions: return "bubble.left.and.text.bubble.right"
            case .schedules: return "calendar.badge.clock"
            case .general: return "gearshape"
            case .notifications: return "bell"
            case .island: return "capsule"
            case .claudeCode: return "terminal"
            case .tools: return "wand.and.stars"
            case .phone: return "iphone"
            case .about: return "info.circle"
            }
        }
    }

    final class Router: ObservableObject {
        @Published var pane: Pane = .home
        @Published var session: String?
    }

    private static var window: NSWindow?
    static let router = Router()
    /// 창 안의 입력 칸이 쓰는 (아일랜드와 따로인) 상태
    static let composerModel = IslandModel()

    static func show(_ pane: Pane? = nil, draft: ScheduleDraft? = nil, session: String? = nil) {
        let services = AppServices.shared
        if let pane { router.pane = pane }
        if let session {
            router.session = session
            router.pane = .sessions
        }
        if let draft {
            services.scheduleDraft = draft
            router.pane = .schedules
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Kongi"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 840, height: 560)
            window.setFrameAutosaveName("KongiWindow")
            window.contentView = NSHostingView(
                rootView: KongiWindowRoot(router: router)
                    .environmentObject(services.usage)
                    .environmentObject(services.scheduler)
                    .environmentObject(services.agents)
            )
            if !window.setFrameUsingName("KongiWindow") { window.center() }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                // 창을 닫으면 다시 메뉴 막대 앱으로 (Dock 아이콘 숨김)
                Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
            }
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct KongiWindowRoot: View {
    @ObservedObject var router: SettingsWindow.Router

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(router: router)
            // 각 화면은 창 모서리와 같은 중심의 둥근 판 위에 (Liquid Glass의 동심 모서리)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(KongiTheme.panel))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(KongiTheme.line))
                .padding([.top, .bottom, .trailing], 10)
        }
        .background(KongiTheme.window)
        .foregroundStyle(KongiTheme.text)
        .tint(KongiTheme.accent)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var page: some View {
        Group {
            switch router.pane {
            case .home: HomePage(router: router)
            case .sessions: SessionsPage(router: router)
            case .schedules: ScheduleListView().padding(.top, 8)
            case .general: GeneralPane()
            case .notifications: NotificationsPane()
            case .island: IslandPane()
            case .claudeCode: ClaudeCodePane()
            case .tools: ToolsPane()
            case .phone: PhonePane(mobile: AppServices.shared.mobile)
            case .about: AboutPane()
            }
        }
        .id(router.pane)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: router.pane)
    }
}

// MARK: - Sidebar

/// 접으면 아이콘만 남는 좁은 막대가 됩니다 (⌃⌘S).
private struct Sidebar: View {
    @ObservedObject var router: SettingsWindow.Router
    @EnvironmentObject private var agents: AgentStore
    @AppStorage("kongiSidebarCollapsed") private var collapsed = false
    @Namespace private var selection

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            header
            ForEach(SettingsWindow.Pane.app) { pane in
                item(pane, badge: pane == .sessions && !agents.requests.isEmpty ? agents.requests.count : nil)
            }
            Group {
                if collapsed {
                    KDivider().frame(width: 28).padding(.vertical, 14)
                } else {
                    KLabel(String(localized: "Settings"))
                        .padding(.horizontal, 10)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                }
            }
            ForEach(SettingsWindow.Pane.settings) { pane in
                item(pane, badge: nil)
            }
            Spacer(minLength: 12)
            ConnectionStatus(compact: collapsed) { router.pane = .claudeCode }
        }
        .padding(.horizontal, collapsed ? 8 : 12)
        .padding(.bottom, 14)
        .frame(width: collapsed ? 60 : 224)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: router.pane)
    }

    private var toggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { collapsed.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(KongiTheme.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle())
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(collapsed ? Text("Show sidebar") : Text("Hide sidebar"))
    }

    @ViewBuilder
    private var header: some View {
        if collapsed {
            VStack(spacing: 12) {
                Kongi(mood: agents.mood, size: 22)
                toggle
            }
            .padding(.top, 40)
            .padding(.bottom, 14)
        } else {
            HStack(spacing: 10) {
                Kongi(mood: agents.mood, size: 24)
                Text(verbatim: "Kongi").font(.system(size: 18, weight: .bold))
                Spacer(minLength: 0)
                toggle
            }
            .padding(.leading, 8)
            .padding(.top, 46)
            .padding(.bottom, 22)
        }
    }

    private func item(_ pane: SettingsWindow.Pane, badge: Int?) -> some View {
        let selected = router.pane == pane
        return Button { router.pane = pane } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 20)
                    .overlay(alignment: .topTrailing) {
                        if collapsed, badge != nil {
                            Circle().fill(Color.yellow).frame(width: 7, height: 7).offset(x: 4, y: -3)
                        }
                    }
                if !collapsed {
                    Text(verbatim: pane.title)
                        .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                if !collapsed, let badge {
                    Text(verbatim: "\(badge)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.yellow))
                }
            }
            .foregroundStyle(selected ? KongiTheme.text : KongiTheme.secondary)
            .padding(.horizontal, 10)
            .frame(width: collapsed ? 44 : nil, height: 32)
            .background {
                if selected {
                    Color.clear
                        .kongiGlass(RoundedRectangle(cornerRadius: 10, style: .continuous), tint: KongiTheme.accent.opacity(0.12))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle())
        .help(Text(verbatim: pane.title))
    }
}

private struct SidebarItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.04 : 0)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hover = $0 }
        }
    }
}

/// 사이드바 아래: Claude Code 연결 상태
private struct ConnectionStatus: View {
    var compact = false
    let open: () -> Void
    @State private var installed = HookInstaller.isInstalled
    @State private var canContinue = HookInstaller.canContinue

    private var label: String {
        installed
            ? (canContinue ? String(localized: "Connected to Claude Code") : String(localized: "Update the Claude Code connection"))
            : String(localized: "Not connected to Claude Code")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Circle()
                    .fill(installed ? (canContinue ? KongiTheme.green : KongiTheme.orange) : KongiTheme.muted)
                    .frame(width: 7, height: 7)
                if !compact {
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(KongiTheme.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KongiTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(KongiTheme.line))
        }
        .buttonStyle(IslandPressStyle())
        .help(Text(verbatim: label))
        .onAppear {
            installed = HookInstaller.isInstalled
            canContinue = HookInstaller.canContinue
        }
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var router: SettingsWindow.Router
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var usage: UsageStore
    @AppStorage(AppSettings.islandEnabled) private var islandEnabled = true
    @AppStorage(AppSettings.islandModeKey) private var islandMode = IslandMode.claude.rawValue
    @AppStorage(AppSettings.agentNotifications) private var agentNotifications = true
    @AppStorage(AppSettings.approvalsInIsland) private var approvalsInIsland = true

    private var summary: String {
        let count = agents.activeSessions.filter(\.state.isBusy).count
        if !agents.requests.isEmpty { return String(localized: "Claude needs you") }
        if count > 0 { return String(localized: "\(count) sessions working") }
        return agents.activeSessions.isEmpty ? String(localized: "No sessions") : String(localized: "All quiet")
    }

    var body: some View {
        KPage(title: String(localized: "Home"), subtitle: summary) {
            KButton(title: String(localized: "Refresh"), symbol: "arrow.clockwise") {
                Task { await usage.refresh(force: true) }
            }
        } content: {
            if let snapshot = usage.snapshot {
                HStack(spacing: 12) {
                    ForEach(snapshot.limits.prefix(3)) { item in
                        UsageTile(item: item, now: usage.now)
                    }
                }
            } else if !usage.isConnected {
                KCard { ConnectView() }
            }

            if !agents.requests.isEmpty {
                KLabel(String(localized: "Needs you"))
                ForEach(agents.requests) { request in
                    RequestTile(request: request)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            let working = agents.activeSessions.filter { $0.state.isBusy && !$0.activities.isEmpty }
            if !working.isEmpty {
                KLabel(String(localized: "Working now"))
                ForEach(working) { session in
                    KCard {
                        LiveFocusView(session: session, large: true)
                        HStack(spacing: 8) {
                            Spacer()
                            KButton(title: TerminalJumper.appName(for: session.context) ?? String(localized: "Open terminal"), symbol: "arrow.up.forward.app") {
                                TerminalJumper.jump(to: session)
                            }
                            KButton(title: String(localized: "Open conversation"), symbol: "bubble.left", style: .primary) {
                                router.session = session.id
                                router.pane = .sessions
                            }
                        }
                    }
                }
            }

            KLabel(String(localized: "This week"))
            WeeklyCard()

            KLabel(String(localized: "Quick controls"))
            KCard {
                FocusRow(focus: AppServices.shared.focus)
                KDivider()
                KToggleRow(title: String(localized: "Show the island"), isOn: $islandEnabled)
                if islandEnabled {
                    KDivider()
                    IslandModePicker(selection: $islandMode)
                }
                KDivider()
                KToggleRow(title: String(localized: "Answer approvals and questions in the island"), isOn: $approvalsInIsland)
                KDivider()
                KToggleRow(title: String(localized: "Notify when Claude finishes or needs you"), isOn: $agentNotifications)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: agents.requests.map(\.id))
    }
}

/// 사용량 한 칸: 큰 숫자와 막대, 초기화까지 남은 시간
private struct UsageTile: View {
    let item: LimitItem
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: item.kind.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KongiTheme.secondary)
                .lineLimit(1)
            Text(verbatim: MenuBarFormatter.percentText(item.percent))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .numericTransition()
                .foregroundStyle(item.severity.color)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(item.severity.color)
                        .frame(width: proxy.size.width * CGFloat(min(max(item.percent, 0), 100)) / 100)
                }
            }
            .frame(height: 6)
            Text(verbatim: Formatters.resetDescription(item.resetsAt, now: now))
                .font(.system(size: 11.5))
                .foregroundStyle(KongiTheme.muted)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(KongiTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KongiTheme.line))
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: item.percent)
    }
}

/// 승인 요청: 창에서 바로 허용·거부
private struct RequestTile: View {
    let request: AgentRequest
    @EnvironmentObject private var agents: AgentStore

    var body: some View {
        let session = agents.session(request.sessionId)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.yellow)
                Text(verbatim: session?.projectName ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KongiTheme.secondary)
                Spacer()
            }
            switch request.kind {
            case let .permission(info):
                Text(String(localized: "Allow \(info.toolName)?"))
                    .font(.system(size: 16, weight: .semibold))
                // 아일랜드와 같은 규칙: 같은 도구로 진행 중인 단계의 미리 보기만 쓰고,
                // 고치는 파일 경로가 아닌 내용(명령 등)은 항상 그대로 보여 줍니다.
                let preview = session?.activities.last {
                    $0.status == .running && $0.activity.toolName == info.toolName && $0.preview != nil
                }?.preview
                if let preview {
                    MiniDiff(diff: preview, maxLines: 16)
                }
                if !info.detail.isEmpty, preview == nil || !info.detail.hasPrefix("/") {
                    Text(verbatim: info.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(KongiTheme.text.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KongiTheme.code))
                }
                HStack(spacing: 8) {
                    KButton(title: String(localized: "Deny"), style: .destructive) { agents.deny(request) }
                    Spacer()
                    if !PermissionRule.rules(in: info.suggestions).isEmpty {
                        KButton(title: String(localized: "Always")) { agents.allow(request, always: true) }
                    }
                    KButton(title: String(localized: "Allow"), style: .primary) { agents.allow(request) }
                }
            case let .question(questions, _):
                Text(verbatim: questions.first?.question ?? "")
                    .font(.system(size: 15, weight: .semibold))
                HStack {
                    Spacer()
                    KButton(title: String(localized: "Answer in the island"), style: .primary) {
                        let model = AppServices.shared.island.model
                        withAnimation(IslandModel.morph) {
                            model.expanded = true
                            model.pinned = true
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(KongiTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.yellow.opacity(0.35)))
    }
}

// MARK: - Sessions

private struct SessionsPage: View {
    @ObservedObject var router: SettingsWindow.Router
    @EnvironmentObject private var agents: AgentStore
    @AppStorage("kongiSessionListHidden") private var listHidden = false

    private var selected: AgentSession? {
        router.session.flatMap { agents.session($0) } ?? agents.activeSessions.first ?? agents.sessions.first
    }

    var body: some View {
        HStack(spacing: 0) {
            if !listHidden {
                SessionColumn(router: router, selectedId: selected?.id)
                    .frame(width: 250)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(KongiTheme.line).frame(width: 1)
            }
            if let selected {
                SessionPanel(session: selected, listHidden: $listHidden)
                    .id(selected.id)
            } else {
                VStack(spacing: 12) {
                    // 콩이는 옆 막대에 있으므로 여기서는 기호로
                    Image(systemName: "terminal")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(KongiTheme.muted)
                    Text("Start Claude Code in a terminal and its work shows up here.")
                        .foregroundStyle(KongiTheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SessionColumn: View {
    @ObservedObject var router: SettingsWindow.Router
    let selectedId: String?
    @EnvironmentObject private var agents: AgentStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                KLabel(String(localized: "Sessions"))
                    .padding(.horizontal, 8)
                    .padding(.top, 22)
                    .padding(.bottom, 6)
                ForEach(agents.activeSessions) { row($0) }
                if !agents.pastSessions.isEmpty {
                    KLabel(String(localized: "Past sessions"))
                        .padding(.horizontal, 8)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    ForEach(agents.pastSessions.prefix(30)) { row($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func row(_ session: AgentSession) -> some View {
        let selected = session.id == selectedId
        return Button { router.session = session.id } label: {
            HStack(spacing: 10) {
                PulsingDot(color: session.state.color, size: 7, pulses: session.state.isBusy || session.state.needsAttention)
                    .id(session.state.isBusy || session.state.needsAttention)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: session.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(session.state.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(KongiTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !session.changes.isEmpty {
                    ChangeCount(added: session.added, removed: session.removed)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle())
    }
}

/// 한 대화: 실시간 / 대화 / 변경
private struct SessionPanel: View {
    let session: AgentSession
    @Binding var listHidden: Bool
    @EnvironmentObject private var agents: AgentStore
    @State private var tab: Tab?
    @State private var file: String?
    @Namespace private var segments

    enum Tab: Hashable { case live, conversation, changes }

    private var current: Tab { tab ?? (session.state.isBusy && !session.activities.isEmpty ? .live : .conversation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { listHidden.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(listHidden ? KongiTheme.secondary : KongiTheme.text)
                        .frame(width: 30, height: 30)
                        .kongiGlass(Circle(), interactive: true)
                }
                .buttonStyle(IslandPressStyle())
                .help(listHidden ? Text("Show sessions") : Text("Hide sessions"))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: session.projectName).font(.system(size: 20, weight: .bold))
                        if let branch = session.gitBranch { BranchChip(branch: branch) }
                    }
                    Text(session.state.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(KongiTheme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                KButton(title: TerminalJumper.appName(for: session.context) ?? String(localized: "Open terminal"), symbol: "arrow.up.forward.app") {
                    TerminalJumper.jump(to: session)
                }
            }
            HStack(spacing: 4) {
                IslandSegment(title: String(localized: "Live"), selected: current == .live, namespace: segments) { tab = .live }
                IslandSegment(title: String(localized: "Conversation"), selected: current == .conversation, namespace: segments) { tab = .conversation }
                IslandSegment(title: String(localized: "Changes \(session.changes.count)"), selected: current == .changes, namespace: segments) { tab = .changes }
                Spacer()
                if !session.changes.isEmpty { ChangeCount(added: session.added, removed: session.removed) }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: current)

            Group {
                switch current {
                case .live:
                    ScrollView { LiveFocusView(session: session, large: true) }
                case .conversation:
                    conversation
                case .changes:
                    changes
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .onAppear { agents.readTranscript(of: session.id) }
    }

    private var conversation: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    SessionTimeline(model: SettingsWindow.composerModel, session: session, large: true) { path in
                        file = path
                        tab = .changes
                    }
                    .padding(.trailing, 6)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.messages.last?.id) { _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.activities.last?.id) { _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Composer(model: SettingsWindow.composerModel, session: session)
        }
    }

    private var changes: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(session.changes) { change in
                        Button { file = change.path } label: {
                            HStack(spacing: 8) {
                                Image(systemName: change.existedBefore ? "doc.text" : "doc.badge.plus")
                                    .foregroundStyle(KongiTheme.secondary)
                                Text(verbatim: change.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                ChangeCount(added: change.diff.added, removed: change.diff.removed)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity((file ?? session.changes.first?.path) == change.path ? 0.08 : 0.03)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SidebarItemStyle())
                    }
                    if session.changes.isEmpty {
                        Text("No file changes yet").foregroundStyle(KongiTheme.secondary).padding(.top, 20)
                    }
                }
            }
            .frame(width: 230)
            if let change = session.changes.first(where: { $0.path == (file ?? session.changes.first?.path) }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: Formatters.relativePath(change.path, in: session.launchDirectory ?? session.cwd))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(KongiTheme.secondary)
                    ScrollView {
                        DiffLines(diff: change.diff, fontSize: 12.5, showsBothNumbers: true)
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KongiTheme.code))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}
