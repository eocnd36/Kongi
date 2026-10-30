#if DEBUG
import AppKit
import ClaudeUsageCore
import SwiftUI

/// 디버그 빌드 전용: README·웹사이트용 사용 영상을 만듭니다.
///
///   swift run ClaudeUsageBar --render-snapshot ./frames --demo-video
///
/// 노치 없는 Mac(맥 미니·맥 스튜디오·아이맥)의 가짜 바탕화면 위에서 가짜 Claude Code 세션을 정해진 순서대로 재생하고,
/// 이 앱의 창 하나만 프레임으로 저장합니다 (다른 화면은 찍지 않음). 프레임은 ffmpeg로 영상·GIF로 묶습니다.
enum DemoStage {
    static let size = CGSize(width: 1100, height: 680)
    static let fps = 30.0

    @MainActor
    static func run(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let agents = AgentStore(preview: [])
        let usage = DebugSnapshot.demoUsageStore()
        let model = IslandModel()
        model.style = .dynamicIsland
        model.metrics = IslandMetrics(hasNotch: false, notchWidth: 0, topHeight: 24, maxExpandedHeight: 560)
        let caption = Caption()
        let nowPlaying = NowPlayingMonitor()
        let devices = DeviceEventsMonitor()

        let stage = Stage(model: model, caption: caption)
            .environmentObject(agents)
            .environmentObject(usage)
            .environmentObject(PromptScheduler(usage: usage))
            .environmentObject(nowPlaying)
            .environmentObject(SystemMonitor())
            .environmentObject(devices)
            .environment(\.kongiGrowth, 0.45)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: stage)
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.center()
        window.orderFrontRegardless()

        // 녹화하는 동안 macOS가 앱을 재우지 않게 (App Nap이면 타이머가 느려져 영상이 끊김)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "Recording the demo video")
        _ = activity
        let script = Script(agents: agents, model: model, caption: caption, nowPlaying: nowPlaying, devices: devices)
        // 캡처는 메인 스레드에서 바로, 저장은 뒤에서 (프레임마다 실제 시각을 함께 적어 영상 길이를 맞춤)
        let writer = DispatchQueue(label: "demo-frames")
        var frame = 0
        var times: [Double] = []
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { timer in
            MainActor.assumeIsolated {
                let now = Date().timeIntervalSince(start)
                script.advance(to: now)
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
                let url = directory.appendingPathComponent(String(format: "f%05d.png", frame))
                writer.async {
                    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    try? png?.write(to: url)
                }
                times.append(now)
                frame += 1
                if now >= script.duration {
                    timer.invalidate()
                    // ffmpeg concat 목록: 프레임마다 다음 프레임까지의 시간
                    var list = ""
                    for index in 0..<times.count {
                        let next = index + 1 < times.count ? times[index + 1] : times[index] + 1 / fps
                        list += "file 'f\(String(format: "%05d", index)).png'\nduration \(next - times[index])\n"
                    }
                    list += "file 'f\(String(format: "%05d", times.count - 1)).png'\n"
                    try? list.write(to: directory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
                    writer.sync {}
                    print("✓ \(frame) frames → \(directory.path)")
                    exit(0)
                }
            }
        }
    }

    /// 화면 아래의 짧은 설명
    @MainActor
    final class Caption: ObservableObject {
        @Published var text = ""
        /// 메뉴 막대의 사용량 창을 열어 보여 주는 중
        @Published var popover = false
        /// 마우스 포인터 (승인 장면)
        @Published var pointer: CGPoint?
        @Published var pressing = false
        /// 마지막 안내 카드
        @Published var endCard = false
    }

    // MARK: 장면 순서

    @MainActor
    final class Script {
        let agents: AgentStore
        let model: IslandModel
        let caption: Caption
        let nowPlaying: NowPlayingMonitor
        let devices: DeviceEventsMonitor
        private var done = Set<Int>()
        private var steps: [(at: Double, run: () -> Void)] = []
        var duration: Double { (steps.last?.at ?? 0) + 2.5 }

        init(agents: AgentStore, model: IslandModel, caption: Caption, nowPlaying: NowPlayingMonitor, devices: DeviceEventsMonitor) {
            self.agents = agents
            self.model = model
            self.caption = caption
            self.nowPlaying = nowPlaying
            self.devices = devices
            build()
        }

        func advance(to time: Double) {
            for (index, step) in steps.enumerated() where step.at <= time && !done.contains(index) {
                done.insert(index)
                step.run()
            }
        }

        private func at(_ time: Double, _ run: @escaping () -> Void) { steps.append((time, run)) }

        private func say(_ text: String) {
            withAnimation(.easeInOut(duration: 0.35)) { caption.text = text }
        }

        private func show(_ state: AgentState, _ activities: [AgentActivity], messages: [AgentMessage] = [],
                          requests: [AgentRequest] = [], completed: Bool = false) {
            var session = AgentSession(
                id: "demo-1", cwd: "/Users/demo/weather-app", context: HookContext(termProgram: "ghostty"),
                state: state, startedAt: Date().addingTimeInterval(-300), updatedAt: Date(),
                activities: activities
            )
            session.messages = messages
            agents.setPreview(sessions: [session], requests: requests, completed: completed)
            let activity: IslandActivity = nowPlaying.track == nil ? .claude : .both
            if model.activity != activity { withAnimation(IslandModel.morph) { model.activity = activity } }
        }

        private func build() {
            let read = ToolActivity(kind: .read, toolName: "Read", target: "ForecastView.swift")
            let test = ToolActivity(kind: .run, toolName: "Bash", target: "Run the tests")
            let edit = ToolActivity(kind: .edit, toolName: "Edit", target: "ForecastView.swift")
            let deploy = ToolActivity(kind: .run, toolName: "Bash", target: "Deploy the preview")
            let file = "/Users/demo/weather-app/Sources/ForecastView.swift"
            let code = Self.forecastCode
            let excerpt = CodeExcerpt(path: file, startLine: 1, lines: code.components(separatedBy: "\n"))
            let ask = AgentMessage(id: "u1", date: Date(), role: .user, text: "Show the high and low next to each day")

            var log: [AgentActivity] = []
            func step(_ id: String, _ activity: ToolActivity, _ status: AgentActivity.Status, detail: String = "",
                      output: String? = nil, preview: LineDiff? = nil, excerpt: CodeExcerpt? = nil) -> AgentActivity {
                AgentActivity(id: id, date: Date(), activity: activity, detail: detail, status: status,
                              preview: preview, output: output, excerpt: excerpt)
            }

            // 1부: 노치 없는 Mac의 다이나믹 아일랜드 (음악, 기기, 볼륨)
            self.model.mode = .dynamic
            at(0) {
                self.say("A Dynamic Island made for Macs without a notch")
                withAnimation(IslandModel.morph) {
                    self.nowPlaying.setPreview(.init(title: "Golden Hour Drive", artist: "The Demo Band", isPlaying: true,
                                                     position: 62, duration: 214, app: .music, artwork: Self.artwork()))
                    self.model.activity = .music
                }
            }
            at(3.2) {
                self.say("AirPods, volume and battery pop in like on iPhone")
                withAnimation(IslandModel.morph) {
                    self.devices.showPreview(.audioDevice(name: "AirPods Pro", kind: .airpodsPro,
                                                          battery: .init(left: 85, right: 90, caseLevel: 60)), for: 2.4)
                }
            }
            at(6.0) {
                withAnimation(IslandModel.morph) { self.devices.showPreview(.volume(level: 0.6, muted: false), for: 1.6) }
            }
            // 2부: Claude Code
            at(8.2) {
                self.say("Music and Claude Code, side by side")
                self.show(.thinking, [], messages: [ask])
            }
            at(11.0) {
                // 펼친 동안은 콩이가 보이는 Claude 모드로 (먼저 바꾸고, 자리를 잡은 뒤 펼침)
                withAnimation(IslandModel.morph) { self.model.mode = .claude }
            }
            at(11.6) {
                withAnimation(IslandModel.morph) { self.model.expanded = true }
                self.say("See what Claude Code reads, runs and edits, live")
                log = [step("s1", read, .running, detail: file, excerpt: excerpt)]
                self.show(.running(read), log, messages: [ask])
            }
            at(14.6) {
                log[0].status = .succeeded
                log.append(step("s2", test, .running, detail: "swift test"))
                self.show(.running(test), log, messages: [ask])
            }
            at(16.0) {
                log[1].output = "Test run with 48 tests in 9 suites passed after 0.41 seconds."
                log[1].status = .succeeded
                self.show(.thinking, log, messages: [ask])
            }
            at(17.4) {
                let preview = LineDiff.compute(old: Self.oldRow, new: Self.newRow, context: 3)
                log.append(step("s3", edit, .running, detail: file, preview: preview))
                self.show(.running(edit), log, messages: [ask])
            }
            at(21.4) {
                log[2].status = .succeeded
                self.say("Approve from the island, without switching windows")
                let request = AgentRequest(
                    sessionId: "demo-1", createdAt: Date(),
                    kind: .permission(PermissionInfo(
                        toolName: "Bash",
                        activity: deploy,
                        detail: "npm run deploy -- --preview",
                        suggestions: []
                    )),
                    connection: nil
                )
                self.show(.waitingForApproval, log, messages: [ask], requests: [request])
            }
            at(22.6) {
                self.caption.pointer = CGPoint(x: 900, y: 430)
                withAnimation(.easeInOut(duration: 0.9)) { self.caption.pointer = DemoStage.allowButton }
            }
            at(23.7) {
                withAnimation(.easeOut(duration: 0.12)) { self.caption.pressing = true }
            }
            at(23.9) {
                withAnimation(.easeOut(duration: 0.15)) { self.caption.pressing = false }
            }
            at(24.0) {
                log.append(step("s4", deploy, .running, detail: "npm run deploy -- --preview"))
                self.show(.running(deploy), log, messages: [ask])
            }
            at(24.6) {
                withAnimation(.easeOut(duration: 0.3)) { self.caption.pointer = nil }
            }
            at(25.4) {
                log[3].output = "✓ Preview ready at https://preview.example.com"
                log[3].status = .succeeded
                self.say("Kongi cheers when the work is done")
                let reply = AgentMessage(id: "a1", date: Date(), role: .assistant,
                                         text: "Done. Each day now shows its high and low, and the tests pass.")
                self.show(.done, log, messages: [ask, reply], completed: true)
            }
            at(29.4) {
                withAnimation(IslandModel.morph) { self.model.expanded = false }
            }
            at(29.9) {
                withAnimation(IslandModel.morph) { self.model.mode = .dynamic }
            }
            at(30.2) {
                self.say("Notices pop in, then step aside")
                withAnimation(IslandModel.morph) {
                    self.devices.showPreview(.notice(.init(key: "done", symbol: "checkmark.circle.fill", tint: .green,
                                                           title: "weather-app finished", detail: "Deploy the preview",
                                                           trailing: "+6 −1")), for: 2.8)
                }
            }
            at(33.4) {
                self.say("Your Claude limits live in the menu bar")
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.caption.popover = true }
            }
            at(38.0) {
                withAnimation(.easeInOut(duration: 0.25)) { self.caption.popover = false }
                self.say("Free and open source. On Android today, iPhone next.")
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { self.caption.endCard = true }
            }
            at(41.0) {}
        }

        /// 가짜 앨범 그림 (그라데이션)
        static func artwork() -> NSImage {
            NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
                NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.35, alpha: 1), NSColor(red: 0.85, green: 0.25, blue: 0.55, alpha: 1)])?
                    .draw(in: rect, angle: -45)
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 42, dy: 42)).fill()
                return true
            }
        }

        static let forecastCode = """
        import SwiftUI

        struct ForecastView: View {
            let days: [Day]

            var body: some View {
                List(days) { day in
                    HStack {
                        Text(day.name)
                        Spacer()
                        Image(systemName: day.symbol)
                        Text("\\(day.temperature)°")
                    }
                }
            }
        }
        """

        static let oldRow = """
                HStack {
                    Text(day.name)
                    Spacer()
                    Image(systemName: day.symbol)
                    Text("\\(day.temperature)°")
                }
        """

        static let newRow = """
                HStack {
                    Text(day.name)
                    Spacer()
                    Image(systemName: day.symbol)
                    Text("\\(day.high)°").bold()
                    Text("\\(day.low)°").foregroundStyle(.secondary)
                }
        """
    }

    // MARK: 무대

    /// 노치 없는 화면: 바탕화면, 메뉴 막대, 가운데 위의 아일랜드, 아래쪽 설명
    private struct Stage: View {
        @ObservedObject var model: IslandModel
        @ObservedObject var caption: Caption
        @EnvironmentObject private var devices: DeviceEventsMonitor
        @EnvironmentObject private var usage: UsageStore
        @EnvironmentObject private var nowPlaying: NowPlayingMonitor

        /// 접힌 섬은 실제 앱(IslandController)과 같은 방법으로 크기를 정합니다. 펼친 섬은 내용 크기 그대로 (nil).
        private var islandSize: CGSize? {
            let metrics = model.metrics
            if model.expanded {
                return nil
            } else if model.showingEvent {
                return metrics.dynamicCompactSize(activity: model.activity, event: true)
            } else if model.mode == .dynamic {
                return metrics.dynamicCompactSize(activity: model.activity, title: nowPlaying.track?.title)
            }
            return metrics.compactSize(style: model.style, tucked: false)
        }

        var body: some View {
            ZStack(alignment: .top) {
                Wallpaper()
                EditorWindow()
                    .frame(width: 620, height: 360)
                    .offset(y: 230)
                MenuBar(usage: usage)
                if caption.popover {
                    // 메뉴 막대 게이지 아래로 열리는 사용량 창 (실제 앱의 화면)
                    PopoverView()
                        .environmentObject(usage)
                        .frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.97)))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                        .environment(\.colorScheme, .dark)
                        // 화면 안에 다 들어오게 줄여서
                        .scaleEffect(0.78, anchor: .topTrailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 150)
                        .padding(.top, 32)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
                IslandSurface(model: model)
                    .fixedSize()
                    .padding(.top, 4)
                    // 실제 아일랜드처럼 내용 높이만큼 펼칩니다.
                    .onPreferenceChange(IslandHeightKey.self) { height in
                        if abs(model.contentHeight - height) > 0.5 { model.contentHeight = height }
                    }
                if let pointer = caption.pointer {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .scaleEffect(caption.pressing ? 0.82 : 1, anchor: .topLeading)
                        .position(x: pointer.x + 8, y: pointer.y + 12)
                        .transition(.opacity)
                }
                if caption.endCard {
                    EndCard()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                VStack {
                    Spacer()
                    if !caption.text.isEmpty {
                        Text(verbatim: caption.text)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .id(caption.text)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.bottom, 26)
            }
            .frame(width: DemoStage.size.width, height: DemoStage.size.height)
            .clipped()
            .onAppear { model.displaySize = islandSize }
            .onChange(of: islandSize.map { "\($0.width)x\($0.height)" } ?? "expanded") { _ in
                withAnimation(IslandModel.morph) { model.displaySize = islandSize }
            }
            // 실제 아일랜드처럼 소식이 뜨면 음악·Claude 나눔을 잠시 접습니다.
            // 실제 앱(IslandController)처럼 값이 바뀐 다음에 반영합니다. $event는 바뀌기 직전에 알려 주므로
            // 그 자리에서 바로 바꾸면 화면이 옛 값으로 그려진 채 남습니다.
            .onReceive(devices.$event.receive(on: RunLoop.main)) { event in
                withAnimation(IslandModel.morph) { model.showingEvent = event != nil }
            }
        }
    }

    /// 허용 버튼 자리 (무대 좌표). 승인 장면에서 포인터가 여기로 갑니다.
    static let allowButton = CGPoint(x: 722, y: 201)

    /// 마지막 안내: 앱 아이콘, 이름, 지원 기기
    private struct EndCard: View {
        var body: some View {
            ZStack {
                Color.black.opacity(0.82)
                VStack(spacing: 14) {
                    if let icon = NSImage(contentsOfFile: "docs/icon.png") {
                        Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                    }
                    Text(verbatim: "Kongi").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(verbatim: "Free and open source").font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    HStack(spacing: 10) {
                        badge("Mac", symbol: "desktopcomputer", soon: false)
                        badge("Android", symbol: "iphone.gen1", soon: false)
                        badge("iPhone", symbol: "iphone", soon: true)
                    }
                    .padding(.top, 4)
                    Text(verbatim: "github.com/eocnd36/Kongi")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(KongiTheme.accent)
                        .padding(.top, 6)
                }
                .offset(y: -30)
            }
        }

        private func badge(_ title: String, symbol: String, soon: Bool) -> some View {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(verbatim: soon ? "\(title) · soon" : title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(soon ? .white.opacity(0.6) : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(soon ? 0.06 : 0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(soon ? 0.15 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
    }

    private struct Wallpaper: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.24), Color(red: 0.20, green: 0.14, blue: 0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(red: 0.30, green: 0.62, blue: 0.52).opacity(0.45)).frame(width: 520).blur(radius: 120).offset(x: -300, y: 160)
                Circle().fill(Color(red: 0.55, green: 0.35, blue: 0.75).opacity(0.40)).frame(width: 460).blur(radius: 120).offset(x: 330, y: -60)
            }
        }
    }

    /// 노치 없는 메뉴 막대 (가짜 앱 메뉴와 시계)
    private struct MenuBar: View {
        let usage: UsageStore

        var body: some View {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
                Text(verbatim: "Terminal").fontWeight(.bold)
                ForEach(["Shell", "Edit", "View", "Window", "Help"], id: \.self) { Text(verbatim: $0) }
                Spacer()
                MenuBarLabel(store: usage)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                Image(systemName: "wifi")
                Text(verbatim: "Tue 9:41 AM")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(.black.opacity(0.25))
        }
    }

    /// 뒤쪽의 흐릿한 터미널 창 (분위기용)
    private struct EditorWindow: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 11, height: 11) }
                    Spacer()
                }
                .padding(12)
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: "~/weather-app $ claude").foregroundStyle(.white.opacity(0.8))
                    Text(verbatim: "> Show the high and low next to each day").foregroundStyle(Color(red: 0.6, green: 0.9, blue: 0.7))
                    ForEach(0..<6, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(width: CGFloat([380, 300, 420, 260, 340, 200][index]), height: 9)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 16)
                Spacer()
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
    }
}
#endif
