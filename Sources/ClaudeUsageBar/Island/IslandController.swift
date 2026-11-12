import AppKit
import Combine
import ClaudeUsageCore
import SwiftUI

/// 아일랜드 모양. 세 가지를 만들어 비교한 뒤 기본값을 골랐습니다 (DebugSnapshot --render-island-designs).
enum IslandStyle: String, CaseIterable {
    /// 화면 위 가장자리(노치)에 붙어 아래로 흘러내리는 모양
    case notch
    /// 노치 자리(화면 맨 위 가운데)의 검은 알약 → 둥근 카드.
    /// 노치가 있으면 노치와 이어지고, 없으면 메뉴 막대 한가운데에 떠 있습니다.
    case dynamicIsland
    /// 오른쪽 위에 떠 있는 콩이 말풍선 → 카드
    case floatingBuddy

    static let `default`: IslandStyle = .dynamicIsland
}

/// 다이나믹 아일랜드 모드에서 접힌 아일랜드가 보여 줄 것
enum IslandActivity: Equatable {
    case idle
    case claude
    case music
    /// 음악과 Claude를 함께: 아이폰처럼 큰 알약 + 작은 원으로 나눠 보여 줍니다.
    case both
}

/// 아일랜드 화면 배치 정보
struct IslandMetrics: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    /// 노치(또는 메뉴 막대) 높이. 노치형은 펼친 화면을 이 아래부터 그립니다.
    var topHeight: CGFloat
    var maxExpandedHeight: CGFloat
    var screenWidth: CGFloat = 1440

    /// diff를 크게 볼 때의 너비
    var enlargedWidth: CGFloat { min(max(screenWidth * 0.6, 640), 1000) }

    static let compactWing: CGFloat = 68
    static let compactWidthWithoutNotch: CGFloat = 200
    static let expandedWidth: CGFloat = 460
    static let islandCompactWidth: CGFloat = 236
    /// 노치가 없을 때 메뉴 막대 위아래로 남기는 여백
    static let islandInset: CGFloat = 2
    static let buddySize: CGFloat = 50
    static let buddyExpandedWidth: CGFloat = 400
    /// 메뉴 막대와 떠 있는 아일랜드 사이 간격
    static let floatingGap: CGFloat = 6

    func compactSize(style: IslandStyle, tucked: Bool) -> CGSize {
        switch style {
        case .notch:
            if hasNotch {
                return CGSize(width: notchWidth + (tucked ? 0 : Self.compactWing * 2), height: topHeight)
            }
            return CGSize(width: Self.compactWidthWithoutNotch, height: topHeight)
        case .dynamicIsland:
            if hasNotch {
                return CGSize(width: notchWidth + (tucked ? 0 : Self.compactWing * 2), height: topHeight)
            }
            return CGSize(width: Self.islandCompactWidth, height: islandHeight)
        case .floatingBuddy:
            return CGSize(width: Self.buddySize, height: Self.buddySize)
        }
    }

    /// 노치가 없을 때 메뉴 막대 안에 들어가는 알약 높이
    var islandHeight: CGFloat { max(topHeight - Self.islandInset * 2, 22) }

    /// 노치와 이어지는 모양인지 (위 가장자리에 붙음)
    func attachesToTop(style: IslandStyle) -> Bool {
        style == .notch || (style == .dynamicIsland && hasNotch)
    }

    /// 아이폰 다이나믹 아일랜드처럼 평소엔 작게, 할 일이 있으면 넓게
    static let idleWidth: CGFloat = 110
    static let splitGap: CGFloat = 6

    /// 잠깐 띄우는 소식(에어팟 연결, 충전 등)의 너비
    static let eventWidth: CGFloat = 300
    static let eventWing: CGFloat = 104
    /// 마이크·카메라 사용 중 점이 들어갈 자리
    static let privacyWing: CGFloat = 22

    func dynamicCompactSize(activity: IslandActivity, title: String? = nil, event: Bool = false, privacy: Bool = false) -> CGSize {
        if hasNotch {
            // 노치가 있으면 쉴 때는 노치 뒤로 숨고, 할 일이 있으면 양쪽 날개가 나옵니다.
            if event { return CGSize(width: notchWidth + Self.eventWing * 2, height: topHeight) }
            if activity == .idle { return CGSize(width: notchWidth + (privacy ? Self.privacyWing * 2 : 0), height: topHeight) }
            return CGSize(width: notchWidth + Self.compactWing * 2, height: topHeight)
        }
        if event { return CGSize(width: Self.eventWidth, height: islandHeight) }
        let extra: CGFloat = privacy ? 12 : 0
        switch activity {
        case .idle: return CGSize(width: Self.idleWidth + extra, height: islandHeight)
        case .claude: return CGSize(width: Self.islandCompactWidth, height: islandHeight)
        case .music: return CGSize(width: musicWidth(title: title) + extra, height: islandHeight)
        case .both: return CGSize(width: musicWidth(title: title) + Self.splitGap + islandHeight, height: islandHeight)
        }
    }

    /// 음악 알약 너비: 제목에 맞춰 줄고 늘되, 기본 너비를 넘지 않습니다 (넘치면 …, 잠시 뒤 흘러가며 전체 제목).
    func musicWidth(title: String?) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let text = ((title ?? "") as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        // 여백 5 + 앨범 아트 + 간격 7 + 제목 + 간격 7 + 막대 + 여백 9
        let fixed = 5 + (islandHeight - 8) + 7 + 7 + 16 + 9
        return min(max(fixed + text, 150), Self.islandCompactWidth)
    }

    func expandedWidth(style: IslandStyle) -> CGFloat {
        style == .floatingBuddy ? Self.buddyExpandedWidth : Self.expandedWidth
    }

    static func current(for screen: NSScreen) -> IslandMetrics {
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        var notchWidth: CGFloat = 0
        var hasNotch = false
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            hasNotch = notchWidth > 40
        }
        return IslandMetrics(
            hasNotch: hasNotch,
            notchWidth: notchWidth,
            topHeight: hasNotch ? screen.safeAreaInsets.top : menuBar,
            maxExpandedHeight: screen.frame.height * 0.75,
            screenWidth: screen.frame.width
        )
    }
}

@MainActor
final class IslandModel: ObservableObject {
    enum Route: Equatable {
        case sessions
        case session(String)
        case diff(sessionId: String, path: String)
    }

    @Published var expanded = false
    @Published var pinned = false
    @Published var route: Route = .sessions
    @Published var style: IslandStyle = .default
    @Published var mode: IslandMode = .claude
    @Published var activity: IslandActivity = .idle
    /// diff를 크게 보는 중 (아일랜드가 넓고 길어짐)
    @Published var enlarged = false

    var expandedWidth: CGFloat {
        enlarged ? metrics.enlargedWidth : metrics.expandedWidth(style: style)
    }
    @Published var metrics = IslandMetrics(hasNotch: false, notchWidth: 0, topHeight: 24, maxExpandedHeight: 600)
    @Published var contentHeight: CGFloat = 200
    /// 세션이 없을 때 노치 뒤로 숨어 있는지
    @Published var tucked = false
    /// 지금 화면에 그려지는 섬의 크기. 창 크기와 따로 움직여야 애니메이션이 자연스럽습니다
    /// (창은 미리 크게 열어 두고, 섬 모양만 스프링으로 커지고 작아짐). nil이면 내용 크기대로 그립니다.
    @Published var displaySize: CGSize?
    /// 노치가 없는 맥에서 숨길 때 섬이 작아지며 사라지게 합니다.
    @Published var visible = true
    /// 화면 전환 방향 (들어가면 오른쪽에서, 돌아오면 왼쪽에서)
    @Published var forward = true
    /// 에어팟 연결·음량 같은 소식을 잠깐 보여 주는 중 (이때는 섬을 나누지 않음)
    @Published var showingEvent = false
    /// 일이 끝났을 때 접힌 섬이 잠깐 통 하고 커졌다 돌아옵니다.
    @Published var bumping = false
    /// 디버그 스크린샷 렌더링 중 (ImageRenderer는 ScrollView를 그리지 못함)
    var rendersForSnapshot = false

    /// 아일랜드가 커지고 작아질 때 쓰는 스프링 (다이나믹 아일랜드 느낌)
    static let morph = Animation.spring(response: 0.44, dampingFraction: 0.8, blendDuration: 0.1)
    /// 내용이 사라질 때는 섬보다 먼저, 빠르게
    static let fadeOut = Animation.easeIn(duration: 0.12)

    private var collapseTask: Task<Void, Never>?
    private var routeResetTask: Task<Void, Never>?
    /// 마우스가 실제로 섬 창 위에 있는지 (IslandController가 채움)
    var mouseInside: () -> Bool = { false }

    func hover(_ inside: Bool, keepOpen: Bool) {
        collapseTask?.cancel()
        if inside {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(Self.morph) { self?.expanded = true }
            }
        } else if !pinned, !keepOpen {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                // SwiftUI가 나갔다고 잘못 알려도 (창 크기가 바뀌는 중 등) 마우스가 실제로 섬 위에 있으면 접지 않고,
                // 정말 나갈 때까지 기다렸다가 접습니다.
                while !Task.isCancelled, self?.mouseInside() == true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    func collapse() {
        guard expanded else { return }
        withAnimation(Self.morph) {
            expanded = false
            pinned = false
            enlarged = false
        }
        // 접히는 동안 화면이 바뀌어 보이지 않게, 다 접힌 뒤 목록으로 돌려 둡니다.
        routeResetTask?.cancel()
        routeResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, !self.expanded else { return }
            self.route = .sessions
        }
    }

    /// 세션 목록 → 상세 → diff 화면 전환
    func navigate(to route: Route) {
        forward = Self.depth(of: route) >= Self.depth(of: self.route)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            self.route = route
            if case .diff = route {} else { enlarged = false }
        }
    }

    private static func depth(of route: Route) -> Int {
        switch route {
        case .sessions: return 0
        case .session: return 1
        case .diff: return 2
        }
    }

    /// 완료를 알리는 작은 튕김
    func bump() {
        guard !expanded, !bumping else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) { bumping = true }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { self?.bumping = false }
        }
    }
}

/// 테두리 없는 패널. 클릭해도 다른 앱의 포커스를 뺏지 않고, 질문의 직접 입력 칸에서는 키보드를 받습니다.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandController {
    let model = IslandModel()
    private let agents: AgentStore
    private let usage: UsageStore
    private let scheduler: PromptScheduler
    private let nowPlaying: NowPlayingMonitor
    private let system: SystemMonitor
    private let devices: DeviceEventsMonitor
    private var panel: IslandPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var lastRequestCount = 0
    /// 섬이 다 줄어든 뒤에 창을 줄이는 예약
    private var shrinkTask: Task<Void, Never>?
    /// 다른 앱이 화면 전체를 덮고 있는지 (전체 화면 공간을 쓰지 않는 전체 화면 포함)
    private var coveredByFullScreen = false
    private var fullScreenTask: Task<Void, Never>?
    private var pendingWindowSize: CGSize?
    /// 지난번 확인 때 이미 떠 있던 시스템 확인 창들
    private var seenDialogs: Set<Int> = []

    init(agents: AgentStore, usage: UsageStore, scheduler: PromptScheduler, nowPlaying: NowPlayingMonitor,
         system: SystemMonitor, devices: DeviceEventsMonitor) {
        self.devices = devices
        self.agents = agents
        self.usage = usage
        self.scheduler = scheduler
        self.nowPlaying = nowPlaying
        self.system = system
    }

    func start() {
        // 데스크톱(공간)이 바뀌면 전체 화면 여부를 바로 확인합니다 (전환 애니메이션 뒤에 한 번 더).
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkFullScreen()
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self?.checkFullScreen()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.layout() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.applySettings() } }
            .store(in: &cancellables)
        model.objectWillChange
            .merge(with: agents.objectWillChange, nowPlaying.objectWillChange, devices.objectWillChange,
                   AppServices.shared.focus.objectWillChange)
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.layout() } }
            .store(in: &cancellables)
        agents.$requests
            .sink { [weak self] requests in Task { @MainActor in self?.requestsChanged(requests.count) } }
            .store(in: &cancellables)
        // 완료 표시가 끝나면 다시 작아지도록
        agents.$lastCompletion
            .compactMap { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model.bump()
                    try? await Task.sleep(nanoseconds: 6_500_000_000)
                    self?.layout()
                }
            }
            .store(in: &cancellables)
        applySettings()
        fullScreenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.checkFullScreen()
            }
        }
    }

    private func currentActivity() -> IslandActivity {
        let recentlyDone = agents.lastCompletion.map { Date().timeIntervalSince($0) < 6 } ?? false
        let claude = !agents.requests.isEmpty
            || agents.activeSessions.contains { $0.state.isBusy || $0.state.needsAttention }
            || recentlyDone
        // 음악이 없으면 집중 타이머가 같은 자리를 씁니다.
        let music = nowPlaying.track?.isPlaying == true || AppServices.shared.focus.isRunning
        switch (claude, music) {
        case (true, true): return .both
        case (true, false): return .claude
        case (false, true): return .music
        case (false, false): return .idle
        }
    }

    private func checkFullScreen() {
        guard let screen else { return }
        // 권한 확인 같은 시스템 창이 뜨면 펼친 섬이 가리지 않게 접습니다 (답을 기다리는 동안 앱이 멈춰 보일 수 있음).
        // 펼쳐 둔 사이에 새로 뜬 창일 때만: 이미 떠 있던 창 위로 펼치거나 고정하면 그대로 둡니다
        // (예전엔 계속 떠 있는 권한 창 때문에 1.5초마다 접혀 마우스를 올려도, 고정해도 꺼졌음).
        if let panel {
            let dialogs = Self.systemDialogs(overlapping: panel.frame, screen: screen)
            if model.expanded, !dialogs.overlapping.isSubset(of: seenDialogs) { model.collapse() }
            seenDialogs = dialogs.all
        }
        let covered = Self.otherAppCoversScreen(screen)
        guard covered != coveredByFullScreen else { return }
        coveredByFullScreen = covered
        if covered {
            panel?.orderOut(nil)
        } else {
            layout()
        }
    }

    /// 화면에 뜬 권한·보안 확인 창(시스템이 띄움)들의 창 번호: 전부, 그리고 섬과 겹치는 것
    static func systemDialogs(overlapping frame: NSRect, screen: NSScreen) -> (all: Set<Int>, overlapping: Set<Int>) {
        let owners: Set<String> = ["UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent", "universalAccessAuthWarn", "coreautha"]
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return ([], []) }
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // AppKit 좌표(왼쪽 아래 원점) → CGWindow 좌표(왼쪽 위 원점)
        let island = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        var all: Set<Int> = [], overlapping: Set<Int> = []
        for window in list {
            guard let owner = window[kCGWindowOwnerName as String] as? String, owners.contains(owner),
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.width > 40 else { continue }
            all.insert(number)
            if rect.intersects(island) { overlapping.insert(number) }
        }
        return (all, overlapping)
    }

    /// 다른 앱의 일반 창이 메뉴 막대까지 포함해 화면 전체를 덮고 있으면 true
    static func otherAppCoversScreen(_ screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        // CGWindow 좌표는 주 화면의 왼쪽 위가 원점입니다.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let target = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
        return list.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != me,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            return abs(rect.minX - target.minX) < 1 && abs(rect.minY - target.minY) < 1
                && abs(rect.width - target.width) < 1 && abs(rect.height - target.height) < 1
        }
    }

    private func applySettings() {
        let mode = AppSettings.islandMode
        if model.mode != mode { withAnimation(IslandModel.morph) { model.mode = mode } }
        nowPlaying.setActive(mode == .dynamic && UserDefaults.standard.bool(forKey: AppSettings.islandEnabled))
        devices.setActive(mode == .dynamic && UserDefaults.standard.bool(forKey: AppSettings.islandEnabled))
        if UserDefaults.standard.bool(forKey: AppSettings.islandEnabled) {
            show()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func requestsChanged(_ count: Int) {
        defer { lastRequestCount = count }
        if count > lastRequestCount {
            // 승인·질문이 오면 저절로 펼칩니다.
            withAnimation(IslandModel.morph) { model.expanded = true }
        } else if count == 0, lastRequestCount > 0, !model.pinned, !model.mouseInside() {
            // 마우스가 섬 위에 있으면 그대로 두고, 나갈 때 hover가 접습니다.
            model.collapse()
        }
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func show() {
        if panel == nil {
            let panel = IslandPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            // 전체 화면 앱(유튜브 전체 화면 등) 위에는 나타나지 않게 fullScreenAuxiliary는 넣지 않습니다.
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            let hosting = NSHostingView(
                rootView: IslandRootView(model: model)
                    .environmentObject(agents)
                    .environmentObject(usage)
                    .environmentObject(scheduler)
                    .environmentObject(nowPlaying)
                    .environmentObject(system)
                    .environmentObject(devices)
            )
            // 창 크기는 IslandController가 정합니다 (SwiftUI가 창 크기를 바꾸지 않도록).
            hosting.sizingOptions = []
            // NSHostingView를 창의 contentView로 바로 두면, macOS 26 SDK로 빌드했을 때 SwiftUI가 창 최소·최대 크기를
            // 계속 다시 맞추다 레이아웃이 끝없이 돌아 앱이 꺼집니다 (Update Constraints 무한 반복). 빈 NSView 안에 넣습니다.
            let container = NSView()
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            hosting.frame = container.bounds
            model.mouseInside = { [weak panel] in
                guard let panel, panel.isVisible else { return false }
                return panel.frame.contains(NSEvent.mouseLocation)
            }
            self.panel = panel
        }
        layout()
        // 설정이 바뀔 때마다 불리므로, 전체 화면을 덮은 앱이 있으면 다시 꺼내지 않습니다
        // (예전에는 곡이 바뀌는 등으로 설정이 저장되면 전체 화면 위에 섬이 다시 나타났음).
        if !coveredByFullScreen { panel?.orderFrontRegardless() }
    }

    private func layout() {
        guard let panel, let screen else { return }
        let metrics = IslandMetrics.current(for: screen)
        if model.metrics != metrics { model.metrics = metrics }

        // 펼쳤을 때만 시스템 사용량을 읽습니다.
        system.setActive(model.expanded && UserDefaults.standard.bool(forKey: AppSettings.showSystemStats))

        let activity = currentActivity()
        if model.activity != activity { withAnimation(IslandModel.morph) { model.activity = activity } }
        let showingEvent = devices.event != nil
        if model.showingEvent != showingEvent { withAnimation(IslandModel.morph) { model.showingEvent = showingEvent } }

        let autoHide = UserDefaults.standard.bool(forKey: AppSettings.islandAutoHide)
        let hasWork = !agents.activeSessions.isEmpty || !agents.requests.isEmpty
        let tucked = model.mode == .claude && autoHide && !hasWork && !model.expanded
        if model.tucked != tucked {
            withAnimation(IslandModel.morph) { model.tucked = tucked }
        }

        let style = model.style
        // 노치가 있으면 노치 뒤로 숨고, 없으면 작아지며 사라졌다가 창을 감춥니다.
        let hides = tucked && !(metrics.hasNotch && style != .floatingBuddy)
        var target: CGSize
        if model.expanded {
            target = CGSize(width: model.expandedWidth, height: min(model.contentHeight, metrics.maxExpandedHeight))
        } else if showingEvent {
            target = metrics.dynamicCompactSize(activity: activity, event: true)
        } else if model.mode == .dynamic {
            let playing = nowPlaying.track?.isPlaying == true
            target = metrics.dynamicCompactSize(
                activity: activity, title: playing ? nowPlaying.track?.title : String(localized: "Focus") + " 00:00 ",
                event: devices.event != nil, privacy: devices.micInUse || devices.cameraInUse
            )
        } else {
            target = metrics.compactSize(style: style, tucked: tucked)
        }
        if hides {
            let side = metrics.islandHeight
            target = CGSize(width: side, height: side)
        } else if model.bumping, !model.expanded {
            target.width += 16
        }

        if coveredByFullScreen { return }
        if !panel.isVisible, !hides, UserDefaults.standard.bool(forKey: AppSettings.islandEnabled) {
            // 처음 나타날 때는 애니메이션 없이 제자리에
            model.displaySize = target
            model.visible = true
            setWindowSize(target, metrics: metrics, screen: screen)
            panel.orderFrontRegardless()
            return
        }

        if model.displaySize != target || model.visible == hides {
            withAnimation(IslandModel.morph) {
                model.displaySize = target
                model.visible = !hides
            }
        }

        // 커질 때: 창을 바로 키워 두고 그 안에서 섬이 커집니다.
        // 작아질 때: 섬이 다 줄어든 다음 창을 줄입니다 (먼저 줄이면 내용이 잘려 보임).
        let current = panel.frame.size
        let grown = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        if grown != current { setWindowSize(grown, metrics: metrics, screen: screen) }

        if grown != target || hides {
            guard pendingWindowSize != target || shrinkTask == nil else { return }
            pendingWindowSize = target
            shrinkTask?.cancel()
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let self, let panel = self.panel, let screen = self.screen else { return }
                self.shrinkTask = nil
                self.pendingWindowSize = nil
                if hides {
                    panel.orderOut(nil)
                } else if let size = self.model.displaySize {
                    self.setWindowSize(size, metrics: self.model.metrics, screen: screen)
                }
            }
        } else {
            shrinkTask?.cancel()
            shrinkTask = nil
            pendingWindowSize = nil
        }
    }

    /// 창은 항상 위쪽 가운데(노치 자리)에 붙어 있고, 섬은 그 안의 위쪽 가운데에 그려집니다.
    private func setWindowSize(_ size: CGSize, metrics: IslandMetrics, screen: NSScreen) {
        guard let panel else { return }
        let frame: NSRect
        switch model.style {
        case .notch:
            frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        case .dynamicIsland:
            // 노치 자리: 노치가 있으면 위 가장자리에 붙고, 없으면 메뉴 막대 한가운데에 둡니다.
            let top = metrics.hasNotch ? screen.frame.maxY : screen.frame.maxY - IslandMetrics.islandInset
            frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: top - size.height,
                           width: size.width, height: size.height)
        case .floatingBuddy:
            let menuBarBottom = screen.frame.maxY - metrics.topHeight
            frame = NSRect(x: screen.frame.maxX - 14 - size.width, y: menuBarBottom - 10 - size.height,
                           width: size.width, height: size.height)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}
