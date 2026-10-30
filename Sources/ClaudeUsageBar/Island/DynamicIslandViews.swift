import AppKit
import SwiftUI

// MARK: - Dynamic Island mode (캐릭터 없이, 아이폰 다이나믹 아일랜드처럼)

/// 캐릭터 대신 쓰는 작은 Claude 상태 표시
struct ClaudeGlyph: View {
    var mood: Kongi.Mood
    var size: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !mood.isBusy && mood != .alert)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Group {
                switch mood {
                case _ where mood.isBusy:
                    Image(systemName: "sparkle")
                        .foregroundStyle(Color.orange)
                        .rotationEffect(.degrees(t * 120))
                case .alert:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.yellow)
                        .scaleEffect(1 + sin(t * 8) * 0.08)
                case .happy:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                default:
                    Image(systemName: "sparkle")
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .font(.system(size: size, weight: .bold))
        }
        .frame(width: size + 4, height: size + 4)
    }
}

/// 음악이 나올 때 움직이는 막대
struct EqualizerBars: View {
    var playing: Bool
    var color: Color = Color(red: 0.66, green: 0.90, blue: 0.71)
    var height: CGFloat = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { index in
                    let phase = t * (5 + Double(index) * 1.7) + Double(index)
                    let level = playing ? 0.35 + 0.65 * abs(sin(phase)) : 0.25
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: max(height * level, 2.5))
                }
            }
            .frame(height: height)
        }
    }
}

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.5)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 접힌 상태 (다이나믹 아일랜드 모드)
struct DynamicCompact: View {
    let activity: IslandActivity
    let metrics: IslandMetrics
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var nowPlaying: NowPlayingMonitor
    @EnvironmentObject private var devices: DeviceEventsMonitor
    @ObservedObject private var focus = AppServices.shared.focus

    var body: some View {
        ZStack {
            if let event = devices.event {
                EventCompact(event: event, metrics: metrics)
                    .id(event.key)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92)).animation(.easeOut(duration: 0.22).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            } else {
                Group {
                    if metrics.hasNotch { notchLayout } else { pillLayout }
                }
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.14)),
                    removal: .opacity.animation(.easeIn(duration: 0.08))
                ))
            }
        }
        .animation(IslandModel.morph, value: devices.event?.key)
    }

    private var height: CGFloat { metrics.hasNotch ? metrics.topHeight : metrics.islandHeight }
    private var privacy: Bool { devices.micInUse || devices.cameraInUse }

    // 노치가 있으면 양쪽 날개에 나눠 보여 줍니다.
    @ViewBuilder
    private var notchLayout: some View {
        if activity == .idle {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if privacy {
                    PrivacyDot(camera: devices.cameraInUse).frame(width: IslandMetrics.privacyWing)
                }
            }
            .frame(width: metrics.notchWidth + (privacy ? IslandMetrics.privacyWing * 2 : 0), height: height)
        } else {
            HStack(spacing: 0) {
                leftWing.frame(width: IslandMetrics.compactWing)
                Spacer().frame(width: metrics.notchWidth)
                HStack(spacing: 6) {
                    rightWing
                    if privacy { PrivacyDot(camera: devices.cameraInUse) }
                }
                .frame(width: IslandMetrics.compactWing)
            }
            .frame(height: height)
        }
    }

    @ViewBuilder
    private var leftWing: some View {
        switch activity {
        case .music, .both: Artwork(image: nowPlaying.track?.artwork, size: height * 0.62, radius: 5)
        case .claude: ClaudeGlyph(mood: agents.mood, size: height * 0.42)
        case .idle: EmptyView()
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        switch activity {
        case .music: EqualizerBars(playing: nowPlaying.track?.isPlaying == true, height: height * 0.42)
        case .both: ClaudeGlyph(mood: agents.mood, size: height * 0.42)
        case .claude: claudeBadge
        case .idle: EmptyView()
        }
    }

    @ViewBuilder
    private var pillLayout: some View {
        let musicWidth = metrics.musicWidth(title: nowPlaying.track?.title)
        switch activity {
        case .idle:
            HStack {
                Spacer(minLength: 0)
                if privacy { PrivacyDot(camera: devices.cameraInUse).padding(.trailing, 8) }
            }
            .frame(width: IslandMetrics.idleWidth + (privacy ? 12 : 0), height: height)
        case .music:
            musicPill(trailingDot: privacy).frame(width: musicWidth + (privacy ? 12 : 0), height: height)
        case .claude:
            claudePill.frame(width: IslandMetrics.islandCompactWidth, height: height)
        case .both:
            HStack(spacing: IslandMetrics.splitGap) {
                musicPill(trailingDot: false).frame(width: musicWidth, height: height)
                ClaudeGlyph(mood: agents.mood, size: height * 0.46)
                    .frame(width: height, height: height)
            }
        }
    }

    @ViewBuilder
    private func musicPill(trailingDot: Bool) -> some View {
        if nowPlaying.track?.isPlaying != true, focus.isRunning {
            timerPill(trailingDot: trailingDot)
        } else {
            songPill(trailingDot: trailingDot)
        }
    }

    /// 음악이 없을 때 집중 타이머가 그 자리에
    private func timerPill(trailingDot: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                TimerRing(progress: focus.progress(at: context.date), size: height - 12)
                    .frame(width: height - 8)
                Text(focus.phase == .rest ? String(localized: "Break") : String(localized: "Focus"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                Text(verbatim: FocusRow.clock(focus.remaining(at: context.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(KongiTheme.accent)
                if trailingDot { PrivacyDot(camera: devices.cameraInUse) }
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
        }
    }

    private func songPill(trailingDot: Bool) -> some View {
        HStack(spacing: 7) {
            Artwork(image: nowPlaying.track?.artwork, size: height - 8, radius: 4)
            // 길면 …로 줄였다가, 잠시 뒤 한 번 흘러가며 전체 제목을 보여 줍니다.
            MarqueeText(text: nowPlaying.track?.title ?? "", size: 11)
            EqualizerBars(playing: nowPlaying.track?.isPlaying == true, height: height * 0.45)
            if trailingDot { PrivacyDot(camera: devices.cameraInUse) }
        }
        .padding(.leading, 5)
        .padding(.trailing, 9)
    }

    private var claudePill: some View {
        HStack(spacing: 7) {
            ClaudeGlyph(mood: agents.mood, size: height * 0.46)
            MarqueeText(text: agents.headline, size: 11)
                .id(agents.headline)
                .transition(.opacity)
            if agents.activeSessions.count > 1 { SessionDots(sessions: agents.activeSessions) }
            claudeBadge
            if privacy { PrivacyDot(camera: devices.cameraInUse) }
        }
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.2), value: agents.headline)
    }

    @ViewBuilder
    private var claudeBadge: some View {
        if !agents.requests.isEmpty {
            Text(verbatim: "\(agents.requests.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .numericTransition()
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .frame(minHeight: 16)
                .background(Capsule().fill(Color.yellow))
        }
    }
}

/// 마이크(주황)·카메라(초록) 사용 중 표시. 아이폰처럼 작은 점입니다.
struct PrivacyDot: View {
    let camera: Bool

    var body: some View {
        Circle()
            .fill(camera ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
            .shadow(color: (camera ? Color.green : Color.orange).opacity(0.7), radius: 3)
            .help(Text(camera ? "Camera in use" : "Microphone in use"))
    }
}

/// 잠깐 띄우는 소식: 에어팟 연결, 충전, 배터리 부족, 음량
struct EventCompact: View {
    let event: DeviceEventsMonitor.Event
    let metrics: IslandMetrics

    private var height: CGFloat { metrics.hasNotch ? metrics.topHeight : metrics.islandHeight }

    var body: some View {
        if metrics.hasNotch {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    icon
                    Text(verbatim: title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .frame(width: IslandMetrics.eventWing)
                Spacer().frame(width: metrics.notchWidth)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.trailing, 10)
                .frame(width: IslandMetrics.eventWing)
            }
            .foregroundStyle(.white)
            .frame(height: height)
        } else if case let .volume(level, muted) = event {
            // 아이폰처럼 아이콘 + 넓은 막대 + 숫자만
            HStack(spacing: 10) {
                icon.frame(width: 18)
                VolumeBar(level: muted ? 0 : level, flexible: true)
                Text(verbatim: muted ? "0" : "\(Int((level * 100).rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, alignment: .trailing)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(width: IslandMetrics.eventWidth, height: height)
        } else {
            HStack(spacing: 8) {
                icon
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // 오른쪽 끝은 줄이지 않고, 모자라면 제목을 줄입니다.
                trailing
                    .fixedSize()
                    .layoutPriority(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(width: IslandMetrics.eventWidth, height: height)
        }
    }

    private var title: String {
        switch event {
        case let .audioDevice(name, _, _): return name
        case .charging: return String(localized: "Charging")
        case .lowBattery: return String(localized: "Low Battery")
        case let .volume(_, muted): return muted ? String(localized: "Muted") : String(localized: "Volume")
        case let .notice(notice): return notice.detail.map { "\(notice.title) · \($0)" } ?? notice.title
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch event {
        case let .audioDevice(_, kind, _):
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
        case .charging:
            Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
        case .lowBattery:
            Image(systemName: "battery.25percent").font(.system(size: 13)).foregroundStyle(.red)
        case let .volume(level, muted):
            Image(systemName: muted ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                .font(.system(size: 12))
        case let .notice(notice):
            Image(systemName: notice.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notice.tint)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch event {
        case let .audioDevice(_, _, battery):
            if let battery, let level = battery.headline {
                BatteryGauge(level: level, charging: false)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Text("Connected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        case let .charging(level):
            BatteryGauge(level: level, charging: true)
        case let .lowBattery(level):
            BatteryGauge(level: level, charging: false)
        case let .volume(level, muted):
            VolumeBar(level: muted ? 0 : level)
        case let .notice(notice):
            if let trailing = notice.trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }
}

/// 배터리 칸 + 퍼센트
struct BatteryGauge: View {
    let level: Int
    let charging: Bool

    private var color: Color { charging ? .green : level <= 20 ? .red : .white }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(level)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).stroke(Color.white.opacity(0.5), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .padding(1.5)
                    .frame(width: max(3, 22 * CGFloat(min(max(level, 0), 100)) / 100))
            }
            .frame(width: 22, height: 10)
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 1.5, height: 4).offset(x: 2.5)
            }
        }
    }
}

struct VolumeBar: View {
    let level: Double
    /// 남는 너비를 다 쓰기
    var flexible = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white).frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(width: flexible ? nil : 90, height: 5)
        .frame(maxWidth: flexible ? .infinity : nil)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
    }
}

/// 넘치면 …로 줄여 두다가, 잠시 뒤 한 번 왼쪽으로 흘러가며 전체를 보여 주고 다시 돌아옵니다.
struct MarqueeText: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .semibold
    @State private var scrolling = false
    @State private var offset: CGFloat = 0

    private var textWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight == .semibold ? .semibold : .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    var body: some View {
        GeometryReader { proxy in
            let overflow = textWidth - proxy.size.width
            ZStack(alignment: .leading) {
                if scrolling {
                    Text(verbatim: text)
                        .fixedSize()
                        .offset(x: offset)
                        .transition(.opacity)
                } else {
                    Text(verbatim: text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
            }
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
            .mask(
                // 흘러가는 동안만 양 끝을 흐리게
                LinearGradient(
                    stops: scrolling
                        ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                           .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                        : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .task(id: "\(text)|\(Int(proxy.size.width))") {
                await run(overflow: overflow)
            }
        }
        .frame(height: size * 1.4)
    }

    private func run(overflow: CGFloat) async {
        scrolling = false
        offset = 0
        guard overflow > 2 else { return }
        let speed: CGFloat = 30 // 초당 pt
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { scrolling = true }
            try? await Task.sleep(nanoseconds: 600_000_000)
            let duration = Double((overflow + 12) / speed)
            withAnimation(.linear(duration: duration)) { offset = -(overflow + 12) }
            try? await Task.sleep(nanoseconds: UInt64((duration + 1.4) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { scrolling = false }
            offset = 0
            // 한 번 보여 준 뒤에는 한참 있다가 다시
            try? await Task.sleep(nanoseconds: 25_000_000_000)
        }
    }
}

// MARK: - Expanded sections

/// 지금 재생 중: 앨범 아트, 제목, 진행 막대, 재생 버튼
struct NowPlayingCard: View {
    @EnvironmentObject private var nowPlaying: NowPlayingMonitor

    var body: some View {
        if let track = nowPlaying.track {
            HStack(spacing: 12) {
                Artwork(image: track.artwork, size: 54, radius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    if track.duration > 0 {
                        // 재생 위치는 앱에 묻지 않고 지난 시간으로 계산합니다 (1초마다, 이 막대만 다시 그림).
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.15))
                                    Capsule().fill(Color.white.opacity(0.8))
                                        .frame(width: proxy.size.width * min(max(track.position(at: context.date) / track.duration, 0), 1))
                                }
                            }
                            .animation(.linear(duration: 1), value: Int(track.position(at: context.date)))
                        }
                        .frame(height: 3)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    IslandIconButton(symbol: "backward.fill", help: String(localized: "Previous")) { nowPlaying.previous() }
                    IslandIconButton(symbol: track.isPlaying ? "pause.fill" : "play.fill",
                                     help: track.isPlaying ? String(localized: "Pause") : String(localized: "Play")) {
                        nowPlaying.playPause()
                    }
                    IslandIconButton(symbol: "forward.fill", help: String(localized: "Next")) { nowPlaying.next() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        }
    }
}

/// CPU · GPU · 메모리 · 저장공간
struct SystemStatsRow: View {
    @EnvironmentObject private var system: SystemMonitor

    var body: some View {
        HStack(spacing: 8) {
            if let snapshot = system.snapshot {
                stat("CPU", fraction: snapshot.cpu, detail: percent(snapshot.cpu))
                if let gpu = snapshot.gpu {
                    stat("GPU", fraction: gpu, detail: percent(gpu))
                }
                stat(String(localized: "Memory"),
                     fraction: Double(snapshot.memoryUsed) / Double(max(snapshot.memoryTotal, 1)),
                     detail: "\(bytes(snapshot.memoryUsed)) / \(bytes(snapshot.memoryTotal))")
                let free = bytes(snapshot.diskTotal - min(snapshot.diskUsed, snapshot.diskTotal))
                stat(String(localized: "Storage"),
                     fraction: Double(snapshot.diskUsed) / Double(max(snapshot.diskTotal, 1)),
                     detail: String(localized: "\(free) free"))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: system.snapshot)
    }

    private func stat(_ title: String, fraction: Double, detail: String) -> some View {
        let color: Color = fraction > 0.9 ? .red : fraction > 0.7 ? .orange : Color(red: 0.66, green: 0.90, blue: 0.71)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
            Text(verbatim: detail)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
