import AppKit
import ClaudeUsageCore
import SwiftUI

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var devices: DeviceEventsMonitor
    @EnvironmentObject private var usage: UsageStore

    var body: some View {
        IslandSurface(model: model)
            .modifier(IslandDropModifier(model: model))
            .environment(\.kongiGrowth, (usage.snapshot?.limit(.session)?.percent ?? 30) / 100)
            // 마우스·클릭은 섬 모양 안에서만 받습니다 (애니메이션 중 창이 더 클 수 있음).
            .onHover { inside in
                model.hover(inside, keepOpen: !agents.requests.isEmpty)
            }
            .onTapGesture {
                guard !model.expanded else { return }
                // 소식을 누르면 그 소식이 가리키는 곳으로 (작업 완료 → 그 대화, 회의 → 참여 링크)
                if case let .notice(notice)? = devices.event, let action = notice.action {
                    switch action {
                    case let .openURL(url): NSWorkspace.shared.open(url)
                    case .openWindow: SettingsWindow.show()
                    case .openAbout: SettingsWindow.show(.about)
                    case let .openSession(id):
                        withAnimation(IslandModel.morph) {
                            model.expanded = true
                            model.pinned = true
                        }
                        model.navigate(to: .session(id))
                    }
                    return
                }
                withAnimation(IslandModel.morph) {
                    model.expanded = true
                    model.pinned = true
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.style == .floatingBuddy ? .topTrailing : .top)
            .onPreferenceChange(IslandHeightKey.self) { height in
                if abs(model.contentHeight - height) > 0.5 { model.contentHeight = height }
            }
    }
}

/// 아일랜드의 모양과 내용. 실제 창과 디자인 비교용 스크린샷이 함께 씁니다.
struct IslandSurface: View {
    @ObservedObject var model: IslandModel
    @EnvironmentObject private var devices: DeviceEventsMonitor

    private var metrics: IslandMetrics { model.metrics }

    var body: some View {
        // 음악과 Claude를 함께 보여 줄 때는 아이폰처럼 큰 알약 + 작은 원으로 나눕니다.
        let split = model.mode == .dynamic && !model.expanded && model.activity == .both && !metrics.hasNotch && !model.showingEvent
        let outline = IslandOutline(
            attachedToTop: metrics.attachesToTop(style: model.style),
            radius: radius,
            bubble: split ? metrics.islandHeight : 0
        )
        ZStack(alignment: .top) {
            if model.expanded {
                ExpandedScroller(model: model) {
                    ExpandedIsland(model: model)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: IslandHeightKey.self, value: proxy.size.height)
                        })
                }
                    // 섬이 커지는 동안 살짝 늦게 나타나고, 접을 때는 섬보다 먼저 사라집니다.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            .animation(.easeOut(duration: 0.22).delay(0.17)),
                        removal: .opacity.animation(IslandModel.fadeOut)
                    ))
            } else if model.mode == .claude, let event = devices.event {
                // Claude 모드에서도 작업 완료·명령 끝 같은 소식은 잠깐 넓어져 보여 줍니다.
                EventCompact(event: event, metrics: metrics)
                    .id(event.key)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            } else if model.mode == .dynamic {
                DynamicCompact(activity: model.activity, metrics: metrics)
                    .id(model.activity)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.14)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))
                    ))
            } else if !model.tucked {
                CompactIsland(style: model.style, metrics: metrics)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.18)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))
                    ))
            }
        }
        // 섬 크기는 IslandController가 스프링으로 바꿉니다. 내용은 섬 모양 밖으로 나가지 않게 잘라 냅니다.
        .frame(width: model.displaySize?.width, height: model.displaySize?.height, alignment: .top)
        .background(outline.fill(fill))
        .overlay(outline.stroke(stroke, lineWidth: 1))
        .clipShape(outline)
        .contentShape(outline)
        .opacity(model.visible ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    private var radius: CGFloat {
        let hidden = !model.visible
        switch model.style {
        case .notch:
            return model.expanded ? 22 : (metrics.hasNotch ? 12 : metrics.topHeight / 2)
        case .dynamicIsland:
            if model.expanded { return 30 }
            if hidden { return metrics.islandHeight / 2 }
            return metrics.hasNotch ? metrics.topHeight / 2 : metrics.islandHeight / 2
        case .floatingBuddy:
            return model.expanded ? 22 : IslandMetrics.buddySize / 2
        }
    }

    private var fill: Color {
        model.style == .floatingBuddy ? Color(red: 0.12, green: 0.14, blue: 0.13).opacity(0.97) : .black
    }

    private var stroke: Color {
        switch model.style {
        case .floatingBuddy: return Color(red: 0.66, green: 0.90, blue: 0.71).opacity(0.35)
        case .dynamicIsland where !metrics.hasNotch: return Color.white.opacity(0.08)
        default: return .clear
        }
    }
}

/// 섬 윤곽. 노치에 붙는 모양(위가 평평)과 떠 있는 모양(모든 모서리가 둥근)을 같은 방식으로 애니메이션합니다.
struct IslandOutline: Shape {
    var attachedToTop: Bool
    var radius: CGFloat
    /// 0보다 크면 오른쪽에 이 지름의 작은 원을 따로 붙입니다 (아이폰의 두 활동 표시).
    var bubble: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, bubble) }
        set {
            radius = newValue.first
            bubble = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        if attachedToTop { return IslandShape(radius: radius).path(in: rect) }
        guard bubble > 0.5 else {
            return RoundedRectangle(cornerRadius: min(radius, rect.height / 2, rect.width / 2), style: .continuous).path(in: rect)
        }
        let gap = IslandMetrics.splitGap * min(bubble / max(rect.height, 1), 1)
        let main = CGRect(x: rect.minX, y: rect.minY, width: max(rect.width - bubble - gap, rect.height), height: rect.height)
        var path = RoundedRectangle(cornerRadius: min(radius, rect.height / 2), style: .continuous).path(in: main)
        let size = min(bubble, rect.height)
        path.addEllipse(in: CGRect(x: rect.maxX - size, y: rect.midY - size / 2, width: size, height: size))
        return path
    }
}

/// 펼친 내용이 화면보다 길면(승인 요청이 여러 개 등) 섬 안에서 스크롤합니다.
/// 구조가 바뀌면 입력 중인 글이 사라지므로 항상 같은 ScrollView를 쓰고, 넘칠 때만 스크롤을 켭니다.
private struct ExpandedScroller<Content: View>: View {
    @ObservedObject var model: IslandModel
    @ViewBuilder let content: Content

    var body: some View {
        if model.rendersForSnapshot {
            content
        } else {
            // scrollDisabled는 안쪽 스크롤(대화, diff)까지 막으므로 쓰지 않습니다. 내용이 다 들어가면 어차피 움직이지 않습니다.
            let limit = model.metrics.maxExpandedHeight
            ScrollView(.vertical) { content }
                .scrollIndicators(model.contentHeight > limit ? .automatic : .never)
                .frame(height: min(model.contentHeight, limit))
        }
    }
}

struct IslandHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 위쪽은 화면 끝에 붙고 아래 모서리만 둥근 모양 (노치에서 흘러내린 듯한 모양)
struct IslandShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension AnyTransition {
    /// 아일랜드 안 화면 전환: 들어갈 때는 오른쪽에서, 돌아갈 때는 왼쪽에서 살짝 밀려 들어오고, 이전 화면은 바로 흐려집니다.
    static func islandPage(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 18 : -18)),
            removal: .opacity.animation(.easeIn(duration: 0.1))
        )
    }
}

// MARK: - Shared state helpers

extension AgentStore {
    var mood: Kongi.Mood {
        if !requests.isEmpty || activeSessions.contains(where: { $0.state.needsAttention }) { return .alert }
        if let lastCompletion, Date().timeIntervalSince(lastCompletion) < 6,
           !activeSessions.contains(where: { $0.state.isBusy }) { return .happy }
        if let busy = activeSessions.first(where: { $0.state.isBusy }) { return Self.mood(of: busy) }
        // 방금(5초 안) 명령이 실패했으면 시무룩
        if activeSessions.contains(where: { session in
            guard let last = session.activities.last else { return false }
            return last.status == .failed && Date().timeIntervalSince(last.date) < 5
        }) { return .sad }
        return activeSessions.isEmpty ? .sleeping : .idle
    }

    /// 일하는 세션 하나의 기분: 지금 하는 도구에 따라 읽기·고치기·실행·찾기, 도구 사이에는 생각 중
    static func mood(of session: AgentSession) -> Kongi.Mood {
        if session.state.needsAttention { return .alert }
        if let running = session.activities.last(where: { $0.status == .running }) { return .doing(running.activity.kind) }
        if session.state == .thinking || session.state == .starting { return .thinking }
        return session.state.isBusy ? .working : session.state == .done ? .happy : .idle
    }

    /// 접힌 아일랜드에 보여 줄 한 줄 상태
    var headline: String {
        if let request = requests.first {
            switch request.kind {
            case .permission: return String(localized: "Needs approval")
            case .question: return String(localized: "Has a question")
            }
        }
        if let session = activeSessions.first(where: { $0.state.needsAttention }) { return session.state.label }
        if let session = activeSessions.first(where: { $0.state.isBusy }) { return session.state.label }
        if mood == .happy { return String(localized: "Done") }
        if let session = activeSessions.first { return session.state.label }
        return String(localized: "No sessions")
    }
}

extension AgentState {
    var label: String {
        switch self {
        case .starting: return String(localized: "Starting")
        case .thinking: return String(localized: "Thinking")
        case let .running(activity): return activity.label
        case .waitingForApproval: return String(localized: "Needs approval")
        case .waitingInTerminal: return String(localized: "Waiting in terminal")
        case .waitingForAnswer: return String(localized: "Has a question")
        case .waitingForInput: return String(localized: "Waiting for you")
        case .done: return String(localized: "Done")
        case .ended: return String(localized: "Ended")
        }
    }

    var color: Color {
        switch self {
        case .waitingForApproval, .waitingInTerminal, .waitingForAnswer: return .yellow
        case .done: return .green
        case .waitingForInput: return .blue
        case .ended: return .gray
        default: return .orange
        }
    }
}

extension PermissionRule {
    var scopeLabel: String {
        destination == "session" ? String(localized: "this session only") : String(localized: "this project")
    }
}

extension ToolActivity {
    var verb: String {
        switch kind {
        case .read: return String(localized: "Reading")
        case .edit: return String(localized: "Editing")
        case .write: return String(localized: "Writing")
        case .run: return String(localized: "Running")
        case .search: return String(localized: "Searching")
        case .web: return String(localized: "Browsing")
        case .agent: return String(localized: "Delegating")
        case .plan: return String(localized: "Planning")
        case .question: return String(localized: "Asking")
        case .other: return toolName
        }
    }

    /// "Editing App.swift" — 언어마다 어순이 달라 번역 파일에서 순서를 정합니다 (예: "App.swift 편집 중").
    var label: String {
        guard !target.isEmpty else { return verb }
        // 명령에 Claude Code가 붙인 설명("Run the tests")은 그 자체로 문장이라 앞에 "실행 중"을 붙이지 않습니다.
        if kind == .run, target.contains(" "), target.first?.isUppercase == true { return target }
        let verb = self.verb
        let target = self.target
        return String(localized: "\(verb) \(target)")
    }

    var symbol: String {
        switch kind {
        case .read: return "doc.text"
        case .edit, .write: return "pencil"
        case .run: return "terminal"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .agent: return "person.2"
        case .plan: return "checklist"
        case .question: return "questionmark.bubble"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Compact

private struct CompactIsland: View {
    let style: IslandStyle
    let metrics: IslandMetrics
    @EnvironmentObject private var agents: AgentStore
    @ObservedObject private var focus = AppServices.shared.focus

    /// Claude가 일하지 않을 때 집중 타이머가 돌고 있으면 그 시간을
    private var showsTimer: Bool { focus.isRunning && !agents.activeSessions.contains { $0.state.isBusy || $0.state.needsAttention } }

    @ViewBuilder
    private var headlineText: some View {
        if showsTimer {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    TimerRing(progress: focus.progress(at: context.date), size: 11)
                    Text(verbatim: FocusRow.clock(focus.remaining(at: context.date)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(KongiTheme.accent)
                }
            }
        } else {
            Text(agents.headline)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .id(agents.headline)
                .transition(.opacity)
        }
    }

    var body: some View {
        content
            // 상태 문구가 바뀔 때 부드럽게 바뀝니다.
            .animation(.easeInOut(duration: 0.22), value: agents.headline)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .notch:
            notch
        case .dynamicIsland:
            if metrics.hasNotch {
                notch
            } else {
                HStack(spacing: 7) {
                    Kongi(mood: agents.mood, size: metrics.islandHeight * 0.62)
                    headlineText
                    Spacer(minLength: 0)
                    status
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .frame(width: IslandMetrics.islandCompactWidth, height: metrics.islandHeight)
            }
        case .floatingBuddy:
            Kongi(mood: agents.mood, size: IslandMetrics.buddySize * 0.5)
                .frame(width: IslandMetrics.buddySize, height: IslandMetrics.buddySize)
                .overlay(alignment: .topTrailing) {
                    status.offset(x: 4, y: -4)
                }
        }
    }

    @ViewBuilder
    private var notch: some View {
        let height = metrics.topHeight
        if metrics.hasNotch {
            HStack(spacing: 0) {
                Kongi(mood: agents.mood, size: height * 0.56)
                    .frame(width: IslandMetrics.compactWing)
                Spacer().frame(width: metrics.notchWidth)
                status
                    .frame(width: IslandMetrics.compactWing)
            }
            .frame(height: height)
        } else {
            HStack(spacing: 6) {
                Kongi(mood: agents.mood, size: height * 0.6)
                headlineText
                Spacer(minLength: 0)
                status
            }
            .padding(.horizontal, 10)
            .frame(width: IslandMetrics.compactWidthWithoutNotch, height: height)
        }
    }

    @ViewBuilder
    private var status: some View {
        statusBadge
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: agents.requests.count)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: agents.activeSessions.count)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !agents.requests.isEmpty {
            Badge(text: "\(agents.requests.count)", color: .yellow)
        } else if agents.activeSessions.count > 0 {
            Badge(text: "\(agents.activeSessions.count)", color: agents.mood.isBusy ? .orange : .white.opacity(0.25))
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .numericTransition()
            .foregroundStyle(color == .yellow || color == .orange ? .black : .white)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(color))
    }
}

// MARK: - Expanded

private struct ExpandedIsland: View {
    @ObservedObject var model: IslandModel
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var nowPlaying: NowPlayingMonitor
    @AppStorage(AppSettings.showSystemStats) private var showSystemStats = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.mode == .dynamic, nowPlaying.track != nil {
                NowPlayingCard()
            }
            if model.mode == .claude || !agents.sessions.isEmpty || !agents.requests.isEmpty {
                header
            }
            LimitBanner()
            BackgroundRuns()
            ForEach(agents.requests) { request in
                RequestCard(request: request)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            switch model.route {
            case .sessions:
                // 일하는 대화가 있으면 지금 읽고 고치는 곳을 맨 위에 크게
                if let busy = agents.activeSessions.first(where: { $0.state.isBusy && !$0.activities.isEmpty }) {
                    LiveFocusView(session: busy, scrollable: !model.rendersForSnapshot)
                        .contentShape(Rectangle())
                        .onTapGesture { model.navigate(to: .session(busy.id)) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if model.mode == .claude || !agents.sessions.isEmpty {
                    SessionList(model: model)
                        .transition(.islandPage(forward: model.forward))
                }
            case let .session(id):
                if let session = agents.session(id) {
                    SessionDetail(model: model, session: session)
                        .transition(.islandPage(forward: model.forward))
                } else {
                    SessionList(model: model)
                }
            case let .diff(sessionId, path):
                if let change = agents.session(sessionId)?.changes.first(where: { $0.path == path }) {
                    DiffView(model: model, change: change) { model.navigate(to: .session(sessionId)) }
                        .transition(.islandPage(forward: model.forward))
                } else {
                    SessionList(model: model)
                }
            }
            if model.route == .sessions {
                IslandToolbox()
            }
            if showSystemStats {
                SystemStatsRow()
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: agents.requests.map(\.id))

        .padding(.horizontal, 16)
        // 노치형은 노치(메뉴 막대) 아래부터 그립니다.
        .padding(.top, model.metrics.attachesToTop(style: model.style) ? model.metrics.topHeight + 8 : 16)
        .padding(.bottom, 14)
        .frame(width: model.expandedWidth, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var sessionSummary: String {
        let count = agents.activeSessions.count
        switch count {
        case 0: return String(localized: "Claude Code sessions appear here")
        case 1: return String(localized: "1 session")
        default: return String(localized: "\(count) sessions")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.mode == .claude {
                Kongi(mood: agents.mood, size: 26)
            } else {
                ClaudeGlyph(mood: agents.mood, size: 20)
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(agents.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .id(agents.headline)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                Text(sessionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .numericTransition()
            }
            .animation(.easeInOut(duration: 0.22), value: agents.headline)
            Spacer()
            if let session = usage.snapshot?.limit(.session) {
                Text(verbatim: MenuBarFormatter.percentText(session.percent))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .numericTransition()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(session.severity.color.opacity(0.25)))
                    .foregroundStyle(session.severity.color)
                    .help(Text(LimitKind.session.title))
            }
            IslandIconButton(symbol: "calendar.badge.clock", help: String(localized: "Scheduled prompts")) {
                SettingsWindow.show(.schedules)
            }
            IslandIconButton(symbol: "gearshape", help: String(localized: "Settings")) {
                SettingsWindow.show()
            }
            IslandIconButton(symbol: model.pinned ? "pin.fill" : "pin", help: String(localized: "Keep open")) {
                model.pinned.toggle()
            }
            IslandIconButton(symbol: "chevron.up", help: String(localized: "Close")) {
                model.collapse()
            }
        }
    }
}

// MARK: - Limit reached (자동 감지 → 초기화되면 이어서 하기)

private struct LimitBanner: View {
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var scheduler: PromptScheduler

    /// 한도에 닿은 가장 이른 초기화
    private var limit: LimitItem? {
        let reached = (usage.snapshot?.limits ?? []).filter { $0.percent >= 99 && $0.resetsAt != nil }
        return reached.min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    var body: some View {
        if let limit, let resetsAt = limit.resetsAt {
            // 한도 때문에 멈춘 대화만 권합니다 (그냥 끝났거나 아직 일하는 대화는 빼고).
            let sessions = Array(agents.activeSessions.filter { session in
                session.limitStoppedAt.map { Date().timeIntervalSince($0) < 8 * 3600 } ?? false
            }.prefix(3))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").foregroundStyle(.orange)
                    Text(String(localized: "\(limit.kind.title) limit reached"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(verbatim: Formatters.scheduleTime(resetsAt, now: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                ForEach(sessions) { session in
                    HStack {
                        Text(verbatim: session.projectName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        if let pending = scheduler.pendingContinue(sessionId: session.id) {
                            HStack(spacing: 6) {
                                Label("Will continue after reset", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.green)
                                // 잘못 눌렀으면 바로 취소
                                IslandIconButton(symbol: "xmark", help: String(localized: "Cancel")) {
                                    scheduler.delete(pending.id)
                                }
                            }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        } else {
                            IslandPillButton(title: String(localized: "Continue after reset"), style: .secondary) {
                                scheduler.scheduleContinue(
                                    session: session,
                                    trigger: limit.kind == .session ? .sessionReset : .weeklyReset
                                )
                            }
                        }
                    }
                }
                if sessions.isEmpty {
                    IslandTextButton(title: String(localized: "Schedule a prompt for the reset"), symbol: "calendar.badge.plus") {
                        SettingsWindow.show(.schedules, draft: ScheduleDraft(trigger: limit.kind == .session ? .sessionReset : .weeklyReset))
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.14)))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sessions.map { scheduler.pendingContinue(sessionId: $0.id) != nil })
        }
    }
}

/// 예약으로 뒤에서 실행 중인 Claude Code: 무엇이 돌고 있는지 보이고 바로 멈출 수 있게
private struct BackgroundRuns: View {
    @EnvironmentObject private var scheduler: PromptScheduler

    var body: some View {
        let running = scheduler.prompts.filter { scheduler.running.contains($0.id) }
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(running) { prompt in
                    HStack(spacing: 8) {
                        PulsingDot(color: .orange, size: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "Running in the background · \(prompt.projectName)"))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(verbatim: prompt.prompt)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        IslandPillButton(title: String(localized: "Stop"), style: .destructive) {
                            scheduler.stop(prompt.id)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// git 브랜치 표시
struct BranchChip: View {
    let branch: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5, weight: .bold))
            Text(verbatim: branch).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(KongiTheme.accent)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(KongiTheme.accent.opacity(0.12)))
        .truncationMode(.middle)
    }
}

// MARK: - Requests

private struct RequestCard: View {
    let request: AgentRequest
    @EnvironmentObject private var agents: AgentStore

    var body: some View {
        let session = agents.session(request.sessionId)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
                Text(verbatim: session?.projectName ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let session {
                    IslandTextButton(title: String(localized: "Answer in terminal"), symbol: "arrow.up.forward.app") {
                        agents.replyInTerminal(request)
                        TerminalJumper.jump(to: session)
                    }
                }
            }
            switch request.kind {
            case let .permission(info):
                PermissionContent(request: request, info: info)
            case let .question(questions, _):
                QuestionContent(request: request, questions: questions)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.35), lineWidth: 1))
    }
}

private struct PermissionContent: View {
    let request: AgentRequest
    let info: PermissionInfo
    @EnvironmentObject private var agents: AgentStore

    /// 같은 도구로 지금 진행 중인 단계의 미리 보기 (PreToolUse에서 계산해 둔 것)
    private var preview: LineDiff? {
        agents.session(request.sessionId)?.activities.last {
            $0.status == .running && $0.activity.toolName == info.toolName && $0.preview != nil
        }?.preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(String(localized: "Allow \(info.toolName)?"))
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: info.activity.symbol)
            }
            // 파일을 고치는 요청이면 무엇이 바뀌는지 먼저 보여 줍니다.
            if let preview {
                HStack(spacing: 6) {
                    Text(verbatim: info.activity.target)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    ChangeCount(added: preview.added, removed: preview.removed)
                }
                MiniDiff(diff: preview, maxLines: 14)
            }
            if !info.detail.isEmpty, preview == nil || !info.detail.hasPrefix("/") {
                // 전체 내용을 보여 줍니다 (잘린 명령을 허용하지 않도록). 길면 스크롤됩니다.
                if info.detail.contains("\n") {
                    Label("Multi-line command — check every line", systemImage: "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
                ScrollView {
                    Text(verbatim: info.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: min(CGFloat(info.detail.split(separator: "\n", omittingEmptySubsequences: false).count) * 15 + 4, 160))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
            }
            let rules = PermissionRule.rules(in: info.suggestions)
            if !rules.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always allows:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    ForEach(rules, id: \.text) { rule in
                        Text(verbatim: "\(rule.text) · \(rule.scopeLabel)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 8) {
                IslandPillButton(title: String(localized: "Deny"), style: .destructive) { agents.deny(request) }
                Spacer()
                if !rules.isEmpty {
                    IslandPillButton(title: String(localized: "Always"), style: .secondary) {
                        agents.allow(request, always: true)
                    }
                    .help(Text("Allow, and don't ask again for this kind of request."))
                }
                IslandPillButton(title: String(localized: "Allow"), style: .primary) { agents.allow(request) }
            }
        }
    }
}

private struct QuestionContent: View {
    let request: AgentRequest
    let questions: [AgentQuestion]
    @EnvironmentObject private var agents: AgentStore
    @State private var selections: [String: Set<String>] = [:]
    @State private var otherText: [String: String] = [:]

    private func answer(for question: AgentQuestion) -> String? {
        var labels = question.options.map(\.label).filter { selections[question.id]?.contains($0) == true }
        if let other = otherText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty,
           selections[question.id]?.contains(Self.otherKey) == true {
            labels.append(other)
        }
        return labels.isEmpty ? nil : AgentQuestion.answerText(labels)
    }

    private static let otherKey = "\u{0}other"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(verbatim: header)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.yellow))
                    }
                    Text(verbatim: question.question)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options) { option in
                        OptionRow(
                            label: option.label,
                            description: option.description,
                            multiSelect: question.multiSelect,
                            selected: selections[question.id]?.contains(option.label) == true
                        ) { toggle(option.label, in: question) }
                    }
                    OptionRow(
                        label: String(localized: "Other…"),
                        description: nil,
                        multiSelect: question.multiSelect,
                        selected: selections[question.id]?.contains(Self.otherKey) == true
                    ) { toggle(Self.otherKey, in: question) }
                    if selections[question.id]?.contains(Self.otherKey) == true {
                        TextField(String(localized: "Type your answer"), text: Binding(
                            get: { otherText[question.id] ?? "" },
                            set: { otherText[question.id] = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
                    }
                }
            }
            HStack {
                Spacer()
                IslandPillButton(title: String(localized: "Send answer"), style: .primary) {
                    var answers: [String: String] = [:]
                    for question in questions {
                        if let text = answer(for: question) { answers[question.question] = text }
                    }
                    agents.answer(request, answers: answers)
                }
                .disabled(questions.contains { answer(for: $0) == nil })
                .opacity(questions.contains { answer(for: $0) == nil } ? 0.4 : 1)
            }
        }
    }

    private func toggle(_ label: String, in question: AgentQuestion) {
        var current = selections[question.id] ?? []
        if question.multiSelect {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = [label]
        }
        selections[question.id] = current
    }
}

private struct OptionRow: View {
    let label: String
    let description: String?
    let multiSelect: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multiSelect
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.yellow : .white.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: label).font(.system(size: 12, weight: .medium))
                    if let description, !description.isEmpty {
                        Text(verbatim: description)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(selected ? 0.5 : 0), lineWidth: 1))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(IslandPressStyle())
    }
}

// MARK: - Sessions

private struct SessionList: View {
    @ObservedObject var model: IslandModel
    @EnvironmentObject private var agents: AgentStore
    @State private var showingHistory = false

    var body: some View {
        let active = agents.activeSessions
        let past = agents.pastSessions
        if active.isEmpty && past.isEmpty {
            EmptySessions()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if active.isEmpty {
                    EmptySessions()
                }
                ForEach(active.prefix(8)) { session in
                    SessionRow(session: session) { model.navigate(to: .session(session.id)) }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                if !past.isEmpty {
                    HStack {
                        Button {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { showingHistory.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(showingHistory ? 90 : 0))
                                Text(String(localized: "Past sessions \(past.count)"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if showingHistory {
                            IslandTextButton(title: String(localized: "Clear all"), symbol: "trash") {
                                withAnimation { agents.clearHistory() }
                            }
                        }
                    }
                    .padding(.top, active.isEmpty ? 0 : 4)
                    if showingHistory {
                        ForEach(past.prefix(10)) { session in
                            HStack(spacing: 6) {
                                SessionRow(session: session) { model.navigate(to: .session(session.id)) }
                                IslandIconButton(symbol: "xmark", help: String(localized: "Delete")) {
                                    withAnimation { agents.deleteSession(session.id) }
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.85), value: agents.sessions.map(\.id))
        }
    }
}

private struct EmptySessions: View {
    @State private var installed = HookInstaller.isInstalled

    var body: some View {
        VStack(spacing: 6) {
            Text(installed
                 ? String(localized: "Start Claude Code in a terminal and its work shows up here.")
                 : String(localized: "Connect Claude Code to see sessions, approve requests and answer questions here."))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !installed {
                IslandPillButton(title: String(localized: "Connect Claude Code"), style: .primary) {
                    if HookSetupFlow.run() { installed = HookInstaller.isInstalled }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let open: () -> Void

    /// 마지막으로 한 말이나 지금 하는 일
    private var subtitle: String {
        if session.state.isBusy || session.state.needsAttention { return session.state.label }
        if let last = session.messages.last(where: { $0.role == .assistant }) {
            return last.text.replacingOccurrences(of: "\n", with: " ")
        }
        return session.state.label
    }

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot(color: session.state.color, size: 8, pulses: session.state.isBusy || session.state.needsAttention)
                .id(session.state.isBusy || session.state.needsAttention)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .id(subtitle)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: subtitle)
            Spacer(minLength: 6)
            if !session.changes.isEmpty {
                ChangeCount(added: session.added, removed: session.removed)
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(verbatim: Formatters.shortElapsed(since: session.updatedAt))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
            }
            IslandIconButton(
                symbol: "arrow.up.forward.app",
                help: TerminalJumper.appName(for: session.context).map { String(localized: "Open in \($0)") } ?? String(localized: "Open terminal")
            ) {
                TerminalJumper.jump(to: session)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .islandHoverRow()
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

struct ChangeCount: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added)").foregroundStyle(Color.green)
            Text(verbatim: "−\(removed)").foregroundStyle(Color.red.opacity(0.9))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
    }
}

private struct SessionDetail: View {
    @ObservedObject var model: IslandModel
    let session: AgentSession
    @State private var tab: Tab?
    @Namespace private var segments

    enum Tab: Hashable { case live, conversation, changes }

    /// 일하는 중이면 실시간 화면부터
    private var current: Tab { tab ?? (session.state.isBusy && !session.activities.isEmpty ? .live : .conversation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IslandIconButton(symbol: "chevron.left", help: String(localized: "Back")) { model.navigate(to: .sessions) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: session.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let branch = session.gitBranch { BranchChip(branch: branch) }
                    }
                    Text(session.state.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .id(session.state.label)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.2), value: session.state.label)
                Spacer()
                IslandTextButton(
                    title: TerminalJumper.appName(for: session.context) ?? String(localized: "Open terminal"),
                    symbol: "arrow.up.forward.app"
                ) { TerminalJumper.jump(to: session) }
            }

            HStack(spacing: 4) {
                IslandSegment(title: String(localized: "Live"), selected: current == .live, namespace: segments) {
                    tab = .live
                }
                IslandSegment(title: String(localized: "Conversation"), selected: current == .conversation, namespace: segments) {
                    tab = .conversation
                }
                IslandSegment(title: String(localized: "Changes \(session.changes.count)"), selected: current == .changes, namespace: segments) {
                    tab = .changes
                }
                Spacer()
                if !session.changes.isEmpty { ChangeCount(added: session.added, removed: session.removed) }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: current)

            ZStack(alignment: .top) {
                switch current {
                case .live:
                    LiveFocusView(session: session, scrollable: !model.rendersForSnapshot)
                        .transition(.opacity)
                case .conversation:
                    SessionConversation(model: model, session: session)
                        .transition(.opacity.combined(with: .offset(x: -10)))
                case .changes:
                    changes
                        .transition(.opacity.combined(with: .offset(x: 10)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: current)
        }
    }

    private var changes: some View {
        let list = VStack(spacing: 4) {
            ForEach(session.changes) { change in
                HStack(spacing: 8) {
                    Image(systemName: change.existedBefore ? "doc.text" : "doc.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: change.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(verbatim: Formatters.relativePath(change.path, in: session.launchDirectory ?? session.cwd))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    ChangeCount(added: change.diff.added, removed: change.diff.removed)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .islandHoverRow(cornerRadius: 8)
                .contentShape(Rectangle())
                .onTapGesture { model.navigate(to: .diff(sessionId: session.id, path: change.path)) }
            }
            if session.changes.isEmpty {
                Text("No file changes yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        return Group {
            if model.rendersForSnapshot {
                list
            } else {
                ScrollView { list }
                    .frame(height: min(CGFloat(max(session.changes.count, 1)) * 44, 300))
            }
        }
    }
}

struct DiffView: View {
    @ObservedObject var model: IslandModel
    let change: FileChange
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IslandIconButton(symbol: "chevron.left", help: String(localized: "Back"), action: back)
                Text(verbatim: change.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                ChangeCount(added: change.diff.added, removed: change.diff.removed)
                // 별도 창 대신 아일랜드가 넓고 길게 커집니다.
                IslandTextButton(
                    title: model.enlarged ? String(localized: "Smaller") : String(localized: "Open large"),
                    symbol: model.enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                ) {
                    withAnimation(IslandModel.morph) {
                        model.enlarged.toggle()
                        model.pinned = model.pinned || model.enlarged
                    }
                }
            }
            if change.diff.truncated {
                Text("This file is too large to show line by line.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            // 가로 스크롤 없이 긴 줄은 줄바꿈하고, 세로로만 스크롤합니다.
            ScrollView(.vertical) {
                DiffLines(diff: change.diff, fontSize: model.enlarged ? 12.5 : 11, showsBothNumbers: model.enlarged)
            }
            .frame(height: min(
                CGFloat(max(change.diff.hunks.reduce(0) { $0 + $1.lines.count }, 1)) * (model.enlarged ? 19 : 17) + 30,
                model.enlarged ? model.metrics.maxExpandedHeight - 140 : 420
            ))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        }
    }
}

/// 변경된 부분(hunk)마다 줄 번호와 함께 보여 줍니다. 아일랜드와 큰 창이 함께 씁니다.
struct DiffLines: View {
    let diff: LineDiff
    let fontSize: CGFloat
    /// 큰 창에서는 이전·새 줄 번호를 모두, 아일랜드에서는 하나만
    let showsBothNumbers: Bool

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.hunks.enumerated()), id: \.offset) { index, hunk in
                HunkHeader(hunk: hunk, fontSize: fontSize)
                    .padding(.top, index == 0 ? 4 : 10)
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineView(line: line, fontSize: fontSize, showsBothNumbers: showsBothNumbers)
                }
            }
        }
        .textSelection(.enabled)
        .padding(.bottom, 6)
    }
}

private struct HunkHeader: View {
    let hunk: LineDiff.Hunk
    let fontSize: CGFloat

    var body: some View {
        let first = hunk.lines.first { $0.newNumber != nil }?.newNumber ?? hunk.lines.first?.oldNumber ?? 0
        HStack(spacing: 6) {
            Text(String(localized: "Line \(first)"))
                .font(.system(size: fontSize - 1, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.7, blue: 1))
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
    }
}

private struct DiffLineView: View {
    let line: LineDiff.Line
    let fontSize: CGFloat
    let showsBothNumbers: Bool

    var body: some View {
        let (sign, color): (String, Color) = {
            switch line.kind {
            case .added: return ("+", .green)
            case .removed: return ("−", .red)
            case .context: return (" ", .white.opacity(0.75))
            }
        }()
        let numberWidth = fontSize * 2.8
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showsBothNumbers {
                Text(verbatim: line.oldNumber.map(String.init) ?? "")
                    .frame(width: numberWidth, alignment: .trailing)
                    .foregroundStyle(.white.opacity(0.3))
            }
            Text(verbatim: (showsBothNumbers ? line.newNumber : (line.newNumber ?? line.oldNumber)).map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundStyle(.white.opacity(0.3))
            Text(verbatim: sign).foregroundStyle(color)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .background(
            line.kind == .added ? Color.green.opacity(0.14)
                : line.kind == .removed ? Color.red.opacity(0.14) : Color.clear
        )
    }
}

// MARK: - Controls (순수 SwiftUI라 스크린샷 렌더링에도 나옵니다)

struct IslandIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .kongiGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressStyle())
        .help(Text(verbatim: help))
    }
}

struct IslandTextButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .kongiGlass(Capsule(), interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
    }
}

struct IslandPillButton: View {
    enum Style { case primary, secondary, destructive }

    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(style == .primary ? KongiTheme.onAccent : .white)
                .modifier(PillBackground(style: style, color: background))
                .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
    }

    private var background: Color {
        switch style {
        case .primary: return KongiTheme.accent
        case .secondary: return Color.white.opacity(0.10)
        case .destructive: return KongiTheme.red.opacity(0.75)
        }
    }
}

/// 허용·거부처럼 중요한 버튼은 꽉 찬 색으로 (유리 효과는 색을 흐리게 해 꺼진 버튼처럼 보임), 나머지는 유리로
private struct PillBackground: ViewModifier {
    let style: IslandPillButton.Style
    let color: Color

    func body(content: Content) -> some View {
        if style == .secondary {
            content.kongiGlass(Capsule(), tint: color, interactive: true)
        } else {
            content.background(Capsule().fill(color))
        }
    }
}

/// 탭 버튼. 선택 표시가 미끄러지듯 옮겨 갑니다.
struct IslandSegment: View {
    let title: String
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.black : .white.opacity(0.7))
                .background {
                    if selected {
                        Capsule().fill(Color.white).matchedGeometryEffect(id: "segment", in: namespace)
                    } else {
                        Capsule().fill(Color.white.opacity(0.08))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
    }
}
