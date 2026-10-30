#if DEBUG
import AppKit
import ClaudeUsageCore
import SwiftUI

/// 디버그 빌드 전용: 아일랜드 디자인을 가짜 바탕화면 위에 그려 PNG로 저장합니다.
///
///   ClaudeUsageBar --render-snapshot <dir> --island                 # 기본 디자인
///   ClaudeUsageBar --render-snapshot <dir> --island-designs         # 세 가지 디자인 비교
@MainActor
enum IslandDesignPreview {
    static func render(to directory: URL, styles: [IslandStyle]) {
        let agents = demoAgents()
        let usage = DebugSnapshot.demoUsageStore()
        let scheduler = PromptScheduler(usage: usage)
        let nowPlaying = NowPlayingMonitor()
        let system = SystemMonitor()
        let devices = DeviceEventsMonitor()
        for style in styles {
            for notch in style == .floatingBuddy ? [false] : [false, true] {
                for expanded in [false, true] {
                    let view = DesignMock(style: style, notch: notch, expanded: expanded)
                        .environmentObject(agents)
                        .environmentObject(usage)
                        .environmentObject(scheduler)
                        .environmentObject(nowPlaying)
                        .environmentObject(system)
                        .environmentObject(devices)
                        .environmentObject(devices)
                        .environmentObject(devices)
                        .environmentObject(devices)
                    let name = "island-\(style.rawValue)\(notch ? "-notch" : "")-\(expanded ? "expanded" : "compact").png"
                    save(view, to: directory.appendingPathComponent(name))
                }
            }
        }
    }

    /// 접힘 ↔ 펼침 중간 단계 (애니메이션 점검용)
    static func renderMorph(to directory: URL) {
        let agents = demoAgents()
        let usage = DebugSnapshot.demoUsageStore()
        let scheduler = PromptScheduler(usage: usage)
        let nowPlaying = NowPlayingMonitor()
        let system = SystemMonitor()
        let devices = DeviceEventsMonitor()
        let compact = CGSize(width: IslandMetrics.islandCompactWidth, height: 26)
        let full = CGSize(width: IslandMetrics.expandedWidth, height: 300)
        let frames = HStack(alignment: .top, spacing: 16) {
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { t in
                let model = IslandModel()
                model.style = .dynamicIsland
                model.metrics = IslandMetrics(hasNotch: false, notchWidth: 0, topHeight: 30, maxExpandedHeight: 800)
                model.expanded = t > 0.3
                model.rendersForSnapshot = true
                model.displaySize = CGSize(
                    width: compact.width + (full.width - compact.width) * t,
                    height: compact.height + (full.height - compact.height) * t
                )
                return IslandSurface(model: model)
                    .frame(width: full.width, height: full.height, alignment: .top)
                    .environmentObject(agents)
                    .environmentObject(usage)
                    .environmentObject(scheduler)
                    .environmentObject(nowPlaying)
                    .environmentObject(system)
                    .environmentObject(devices)
                    .environmentObject(devices)
                    .environmentObject(devices)
            }
        }
        .padding(16)
        .background(Color(red: 0.6, green: 0.5, blue: 0.7))
        save(frames, to: directory.appendingPathComponent("morph.png"))
    }

    /// 앱 아이콘 (1024×1024, macOS 아이콘 격자: 824 크기의 둥근 사각형)
    static func renderIcon(to url: URL) {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.16, green: 0.19, blue: 0.18), Color(red: 0.03, green: 0.04, blue: 0.04)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 4)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            // 콩이 뒤의 은은한 빛
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.66, green: 0.90, blue: 0.71).opacity(0.35), .clear],
                    center: .center, startRadius: 10, endRadius: 330
                ))
                .frame(width: 660, height: 660)
                .offset(y: 30)
            // 아래쪽에 작은 아일랜드 알약
            Capsule()
                .fill(Color.black)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 3))
                .frame(width: 300, height: 64)
                .overlay(
                    HStack(spacing: 14) {
                        Capsule().fill(Color(red: 0.66, green: 0.90, blue: 0.71)).frame(width: 150, height: 14)
                        Circle().fill(Color.yellow).frame(width: 22, height: 22)
                    }
                )
                .offset(y: 270)
            Kongi(mood: .idle, size: 400)
                .offset(y: -10)
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print("✓ \(url.path)")
    }

    /// 다이나믹 아일랜드 모드의 상태들 (대기 / 음악 / Claude / 둘 다 / 펼침)
    static func renderDynamic(to url: URL) {
        let agents = demoAgents()
        let usage = DebugSnapshot.demoUsageStore()
        let scheduler = PromptScheduler(usage: usage)
        let nowPlaying = NowPlayingMonitor()
        let system = SystemMonitor()
        let devices = DeviceEventsMonitor()
        let art = NSImage(size: NSSize(width: 60, height: 60), flipped: false) { rect in
            NSGradient(colors: [.systemPink, .systemOrange])?.draw(in: rect, angle: 45)
            return true
        }
        nowPlaying.setPreview(.init(title: "Midnight City", artist: "M83", isPlaying: true, position: 95, duration: 243, app: .music, artwork: art))
        system.setPreview(.init(cpu: 0.23, gpu: 0.41, memoryUsed: 11_200_000_000, memoryTotal: 17_179_869_184,
                                diskUsed: 380_000_000_000, diskTotal: 494_000_000_000))
        let metrics = IslandMetrics(hasNotch: false, notchWidth: 0, topHeight: 30, maxExpandedHeight: 900)
        func surface(_ activity: IslandActivity, expanded: Bool = false) -> some View {
            let model = IslandModel()
            model.style = .dynamicIsland
            model.mode = .dynamic
            model.activity = activity
            model.expanded = expanded
            model.metrics = metrics
            model.rendersForSnapshot = true
            model.displaySize = expanded ? nil : metrics.dynamicCompactSize(activity: activity, title: nowPlaying.track?.title)
            return IslandSurface(model: model).fixedSize()
        }
        /// 잠깐 띄우는 소식 (모니터를 따로 둬서 위의 상태들과 섞이지 않게)
        func event(_ event: DeviceEventsMonitor.Event?, mic: Bool = false, activity: IslandActivity = .idle) -> some View {
            let monitor = DeviceEventsMonitor()
            monitor.setPreview(event, mic: mic)
            let model = IslandModel()
            model.style = .dynamicIsland
            model.mode = .dynamic
            model.activity = activity
            model.metrics = metrics
            model.rendersForSnapshot = true
            model.displaySize = metrics.dynamicCompactSize(activity: activity, title: nowPlaying.track?.title, event: event != nil, privacy: mic)
            return IslandSurface(model: model).fixedSize().environmentObject(monitor)
        }
        let view = HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 18) {
                surface(.idle)
                surface(.music)
                surface(.claude)
                surface(.both)
                event(.audioDevice(name: "AirPods Pro", kind: .airpodsPro, battery: .init(left: 80, right: 75, caseLevel: 40)))
                event(.charging(level: 64))
                event(.lowBattery(level: 9))
                event(.volume(level: 0.6, muted: false))
                event(nil, mic: true)
                event(nil, mic: true, activity: .music)
            }
            surface(.both, expanded: true)
        }
        .padding(24)
        .background(Color(red: 0.62, green: 0.55, blue: 0.72))
        .environmentObject(agents)
        .environmentObject(usage)
        .environmentObject(scheduler)
        .environmentObject(nowPlaying)
        .environmentObject(system)
        .environmentObject(devices)
        save(view, to: url)
    }

    /// 세션 화면: 대화 타임라인, 실시간 diff, 입력 칸
    static func renderSession(to url: URL) {
        let agents = demoAgents()
        let usage = DebugSnapshot.demoUsageStore()
        let model = IslandModel()
        model.style = .dynamicIsland
        model.expanded = true
        model.rendersForSnapshot = true
        model.route = .session("demo-1")
        model.metrics = IslandMetrics(hasNotch: false, notchWidth: 0, topHeight: 30, maxExpandedHeight: 1200)
        let view = IslandSurface(model: model)
            .fixedSize()
            .padding(24)
            .environmentObject(agents)
            .environmentObject(usage)
            .environmentObject(PromptScheduler(usage: usage))
            .environmentObject(NowPlayingMonitor())
            .environmentObject(SystemMonitor())
            .environmentObject(DeviceEventsMonitor())
        save(view, to: url)
    }

    /// 아일랜드만 투명 배경으로 (README·웹사이트용)
    static func renderIslandOnly(to url: URL) {
        let agents = demoAgents()
        let usage = DebugSnapshot.demoUsageStore()
        let scheduler = PromptScheduler(usage: usage)
        let nowPlaying = NowPlayingMonitor()
        let system = SystemMonitor()
        let devices = DeviceEventsMonitor()
        let model = IslandModel()
        model.style = .dynamicIsland
        model.expanded = true
        model.rendersForSnapshot = true
        model.metrics = IslandMetrics(hasNotch: false, notchWidth: 0, topHeight: 30, maxExpandedHeight: 800)
        let view = IslandSurface(model: model)
            .fixedSize()
            .padding(24)
            .environmentObject(agents)
            .environmentObject(usage)
            .environmentObject(scheduler)
            .environmentObject(nowPlaying)
            .environmentObject(system)
            .environmentObject(devices)
            .environmentObject(devices)
        save(view, to: url)
    }

    /// 콩이의 상태별 모습
    static func renderKongi(to directory: URL) {
        let moods: [(Kongi.Mood, String)] = [(.sleeping, "sleeping"), (.idle, "idle"), (.working, "working"), (.alert, "alert"), (.happy, "happy"),
                                             (.reading, "reading"), (.editing, "editing"), (.running, "running"), (.searching, "searching"), (.thinking, "thinking"), (.sad, "sad")]
        // 두 줄로 (6 + 5)
        let rows = [Array(moods.prefix(6)), Array(moods.dropFirst(6))]
        let view = VStack(spacing: 26) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: 30) {
                    ForEach(rows[row], id: \.1) { mood, name in
                        VStack(spacing: 8) {
                            Kongi(mood: mood, size: 110)
                            Text(verbatim: name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .padding(40)
        .background(Color.black)
        save(view, to: directory.appendingPathComponent("kongi.png"))
    }

    static func save<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
        print("✓ \(url.path)")
    }

    // MARK: Demo data (가짜 데이터 — 실제 세션이나 파일과 무관)

    static func demoAgents() -> AgentStore {
        let now = Date()
        func lines(_ count: Int, _ prefix: String) -> String {
            (1...count).map { "\(prefix) line \($0)" }.joined(separator: "\n") + "\n"
        }
        let oldView = lines(60, "view")
        var newView = oldView.components(separatedBy: "\n")
        newView.replaceSubrange(10..<14, with: (1...18).map { "    new row \($0)" })
        let viewChange = FileChange(
            path: "/Users/demo/my-app/Sources/IslandViews.swift",
            original: oldView, existedBefore: true, current: newView.joined(separator: "\n"),
            diff: LineDiff.compute(old: oldView, new: newView.joined(separator: "\n"))
        )
        let storeChange = FileChange(
            path: "/Users/demo/my-app/Sources/AgentStore.swift",
            original: nil, existedBefore: false, current: lines(12, "store"),
            diff: LineDiff.compute(old: nil, new: lines(12, "store"))
        )
        let edit = ToolActivity(kind: .edit, toolName: "Edit", target: "IslandViews.swift")
        let main = AgentSession(
            id: "demo-1", cwd: "/Users/demo/my-app",
            context: HookContext(termProgram: "iTerm.app"),
            state: .running(edit), startedAt: now.addingTimeInterval(-1800), updatedAt: now,
            activities: [
                AgentActivity(id: "a1", date: now.addingTimeInterval(-120), activity: ToolActivity(kind: .read, toolName: "Read", target: "AgentStore.swift"), detail: "", status: .succeeded),
                AgentActivity(id: "a2", date: now.addingTimeInterval(-60), activity: ToolActivity(kind: .run, toolName: "Bash", target: "swift test"), detail: "swift test", status: .succeeded,
                              output: "Test run with 76 tests in 24 suites passed after 0.005 seconds."),
                AgentActivity(id: "a3", date: now.addingTimeInterval(-10), activity: edit, detail: "/Users/demo/my-app/Sources/IslandViews.swift", status: .running,
                              preview: LineDiff.compute(
                                  old: "import SwiftUI\n\nlet width = 236\nlet height = 32\n",
                                  new: "import SwiftUI\n\nlet width = min(max(fixed + measuredTitleWidth(for: track.title, font: .systemFont(ofSize: 11)), 150), maximumWidth)\nlet height = 32\n",
                                  context: 4)),
            ],
            changes: [viewChange, storeChange]
        )
        var mainWithChat = main
        mainWithChat.messages = [
            AgentMessage(id: "m1", date: now.addingTimeInterval(-200), role: .user, text: "Make the music pill fit the song title"),
            AgentMessage(id: "m2", date: now.addingTimeInterval(-150), role: .assistant, text: "I'll measure the title and size the pill to it, up to the default width. Let me look at the layout code first."),
            AgentMessage(id: "m3", date: now.addingTimeInterval(-30), role: .assistant, text: "Tests pass. Now updating the width calculation."),
        ]
        let site = AgentSession(
            id: "demo-2", cwd: "/Users/demo/website", context: HookContext(termProgram: "ghostty"),
            state: .waitingForInput, startedAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(-240)
        )
        let request = AgentRequest(
            sessionId: "demo-1", createdAt: now,
            kind: .permission(PermissionInfo(
                toolName: "Bash",
                activity: ToolActivity(kind: .run, toolName: "Bash", target: "npm run deploy"),
                detail: "npm run deploy -- --prod",
                suggestions: [.object(["type": .string("addRules")])]
            )),
            connection: nil
        )
        return AgentStore(preview: [mainWithChat, site], requests: [request])
    }
}

/// 가짜 바탕화면 + 메뉴 막대 + 아일랜드
private struct DesignMock: View {
    let style: IslandStyle
    let notch: Bool
    let expanded: Bool

    static let screen = CGSize(width: 1000, height: 660)
    static let menuBar: CGFloat = 32
    static let notchWidth: CGFloat = 190

    var body: some View {
        let model = IslandModel()
        model.style = style
        model.expanded = expanded
        model.rendersForSnapshot = true
        model.metrics = IslandMetrics(
            hasNotch: notch, notchWidth: Self.notchWidth,
            topHeight: Self.menuBar, maxExpandedHeight: 800
        )
        return ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.47, blue: 0.72), Color(red: 0.62, green: 0.48, blue: 0.70), Color(red: 0.93, green: 0.66, blue: 0.56)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // 뒤에 있는 앱 창
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.85))
                .frame(width: 620, height: 400)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 7) {
                        Circle().fill(Color.red.opacity(0.8)).frame(width: 11)
                        Circle().fill(Color.yellow.opacity(0.9)).frame(width: 11)
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 11)
                    }
                    .padding(12)
                }
                .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
                .offset(x: -120, y: 170)
            menuBar
            island(model)
        }
        .frame(width: Self.screen.width, height: Self.screen.height)
        .clipped()
    }

    private var menuBar: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.35))
            HStack(spacing: 18) {
                Image(systemName: "applelogo")
                Text(verbatim: "Terminal").bold()
                Text(verbatim: "Shell")
                Text(verbatim: "Edit")
                Text(verbatim: "View")
                Spacer()
                Image(systemName: "wifi")
                Text(verbatim: "42% · 63%")
                Text(verbatim: "Tue 10:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 16)
            if notch {
                IslandShape(radius: 10).fill(Color.black).frame(width: Self.notchWidth, height: Self.menuBar)
            }
        }
        .frame(height: Self.menuBar)
    }

    @ViewBuilder
    private func island(_ model: IslandModel) -> some View {
        let surface = IslandSurface(model: model).fixedSize()
        switch style {
        case .notch:
            surface
        case .dynamicIsland:
            surface.padding(.top, notch ? 0 : IslandMetrics.islandInset)
        case .floatingBuddy:
            HStack {
                Spacer()
                surface
            }
            .padding(.top, Self.menuBar + 10)
            .padding(.trailing, 14)
        }
    }
}
#endif
