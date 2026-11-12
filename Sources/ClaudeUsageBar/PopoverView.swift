import AppKit
import ClaudeUsageCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var contentHeight: CGFloat = 420

    /// 화면보다 길어지면 스크롤합니다 (작은 화면에서 설정 화면이 잘리지 않도록).
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 24
    }

    var body: some View {
        let height = min(contentHeight, maxHeight)
        ScrollView(.vertical) {
            UsageView { SettingsWindow.show() }
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
        .frame(width: 320, height: height)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .background(WindowHeightFitter(height: height))
        .task { await store.refresh(force: false) }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// MenuBarExtra(.window)의 창은 내용이 커지면 늘어나지만 작아지면 줄어들지 않습니다.
/// (설정 → 사용량으로 돌아오면 위아래에 빈 공간이 남던 문제)
/// 내용 높이에 맞춰 창 크기를 직접 조정하고, 창 위쪽은 메뉴 막대 바로 아래에 붙여 둡니다.
private struct WindowHeightFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, height > 0 else { return }
            let frame = window.frame
            let frameHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: height)).height
            // 메뉴 막대를 덮지 않도록 위쪽 끝을 화면의 사용 가능 영역 안으로 제한합니다.
            let topLimit = (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? frame.maxY
            let top = min(frame.maxY, topLimit)
            let target = NSRect(x: frame.minX, y: top - frameHeight, width: frame.width, height: frameHeight)
            guard abs(target.height - frame.height) > 0.5 || abs(target.maxY - frame.maxY) > 0.5 else { return }
            window.setFrame(target, display: true)
        }
    }
}

// MARK: - Usage page

struct UsageView: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject private var tasks = AppServices.shared.tasks
    @ObservedObject private var updater = AppServices.shared.updater
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let card = updater.card {
                UpdateCard(card: card, updater: updater)
            }

            if store.isConnected, let status = store.serviceStatus, status.hasProblem {
                StatusBanner(status: status)
            }

            if !store.isConnected {
                ConnectView()
            } else if let snapshot = store.snapshot {
                if let error = store.error {
                    ErrorBanner(error: error)
                }
                SectionCard {
                    ForEach(snapshot.limits) { item in
                        LimitRow(item: item, now: store.now)
                        if item.id != snapshot.limits.last?.id { Divider().opacity(0.5) }
                    }
                    if let extra = snapshot.extraUsagePercent {
                        Divider().opacity(0.5)
                        ExtraUsageRow(percent: extra)
                    }
                }
                if !snapshot.breakdown.isEmpty {
                    SectionCard { BreakdownView(items: snapshot.breakdown) }
                }
            } else if let error = store.error {
                ErrorStateView(error: error)
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 24)
            }

            if !tasks.tasks.isEmpty {
                // 빌드·테스트 스코어보드 (kongi run)
                SectionCard {
                    HStack {
                        Label("Builds & tests", systemImage: "hammer").font(.subheadline.weight(.semibold))
                        Spacer()
                        if tasks.tasks.contains(where: { $0.state != .running }) {
                            Button(String(localized: "Clear")) { tasks.clearFinished() }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                    ForEach(tasks.tasks) { TaskRow(task: $0) }
                }
            }

            if !tasks.widgets.isEmpty {
                // 확장·앱이 올린 위젯 (kongi widget)
                SectionCard {
                    Label("Extensions", systemImage: "puzzlepiece.extension").font(.subheadline.weight(.semibold))
                    ForEach(tasks.widgets) { WidgetRow(widget: $0) }
                }
            }

            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Usage")
                .font(.title3.weight(.semibold))
            if let plan = store.credentials?.planName {
                Text(plan)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if store.isConnected {
                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await store.refresh(force: true) }
        } label: {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(IconButtonStyle())
        .disabled(store.isRefreshing)
        .help(Text("Refresh"))
    }

    private var footer: some View {
        HStack {
            Text(Formatters.updatedDescription(store.snapshot?.fetchedAt, now: store.now))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            footerButtons
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                // 조작 버튼만 유리로 묶습니다 (macOS 26 도구 막대처럼)
                .kongiGlass(Capsule(), interactive: true)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        HStack(spacing: 2) {
            Link(destination: AppInfo.claudeUsageURL) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(IconButtonStyle())
            .help(Text("Open usage on claude.ai"))
            Button {
                SettingsWindow.show(.schedules)
            } label: {
                Image(systemName: "calendar.badge.clock")
            }
            .buttonStyle(IconButtonStyle())
            .help(Text("Scheduled prompts"))
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help(Text("Settings"))
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help(Text("Quit"))
        }
    }
}

/// 내용 묶음: 은은한 바탕의 둥근 카드 (유리는 버튼에만 씀)
/// 새 버전이 있거나 방금 업데이트했을 때 맨 위에 뜨는 카드 (무엇이 바뀌었는지)
private struct UpdateCard: View {
    let card: Updater.Card
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(card.installed ? String(localized: "Kongi was updated to \(card.version)") : String(localized: "Kongi \(card.version) is available"),
                      systemImage: card.installed ? "sparkles" : "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KongiTheme.green)
                Spacer()
                Button { updater.dismissCard() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(Text(card.installed ? "Close" : "Later"))
            }
            if !card.changes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(card.changes, id: \.self) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•").foregroundStyle(.secondary)
                            Text(verbatim: change).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
            }
            if !card.installed {
                HStack(spacing: 8) {
                    if case .installing = updater.state {
                        ProgressView().controlSize(.small)
                        Text("Updating… Kongi will reopen when it's done.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        KButton(title: String(localized: "Update now"), symbol: "arrow.down.circle", style: .primary) {
                            Task { await updater.install() }
                        }
                        Button(String(localized: "Later")) { updater.dismissCard() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KongiTheme.green.opacity(0.12)))
    }
}

private struct SectionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Rows

private struct LimitRow: View {
    let item: LimitItem
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.kind.title)
                        .font(.subheadline.weight(.medium))
                    Text(item.kind.windowLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(MenuBarFormatter.percentText(item.percent))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(item.severity.color)
            }
            UsageBar(percent: item.percent, color: item.severity.color, pace: item.elapsedFraction(now: now))
            Text(Formatters.resetDescription(item.resetsAt, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hit = item.projectedLimitDate(now: now) {
                Label(Formatters.projectionDescription(hit, now: now), systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(Text("Estimated from how fast you've used this limit so far."))
            }
        }
    }
}

/// status.claude.com에 장애가 있을 때 보여 줍니다.
private struct StatusBanner: View {
    let status: ServiceStatus

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(status.level == .major || status.level == .critical ? .red : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude is having issues")
                    .font(.caption.weight(.semibold))
                ForEach(status.incidents.prefix(2)) { incident in
                    Text(verbatim: incident.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.incidents.isEmpty, !status.summary.isEmpty {
                    Text(verbatim: status.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Link(String(localized: "View status"), destination: status.incidents.first?.url ?? ServiceStatus.pageURL)
                    .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

private struct ExtraUsageRow: View {
    let percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extra usage")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(MenuBarFormatter.percentText(percent))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            UsageBar(percent: percent, color: .purple, pace: nil)
        }
    }
}

/// 사용량 막대. `pace`는 한도 창에서 경과한 시간 비율로, 세로 눈금으로 표시합니다.
/// 막대가 눈금보다 앞서 있으면 평소보다 빠르게 쓰고 있다는 뜻입니다.
private struct UsageBar: View {
    let percent: Double
    let color: Color
    let pace: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(geo.size.width * percent / 100, percent > 0 ? 6 : 0))
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 12)
                        .offset(x: min(max(geo.size.width * pace - 1, 0), geo.size.width - 2))
                        .help(Text("Time elapsed in this window"))
                }
            }
        }
        .frame(height: 10)
    }
}

private struct BreakdownView: View {
    let items: [BreakdownItem]

    private static let palette: [Color] = [.orange, .blue, .purple, .teal, .pink, .gray]

    private func color(at index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This week by product")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let total = max(items.reduce(0) { $0 + $1.percent }, 1)
                HStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(at: index))
                            .frame(width: max((geo.size.width - CGFloat(items.count - 1) * 2) * item.percent / total, 2))
                    }
                }
            }
            .frame(height: 6)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 5) {
                        Circle().fill(color(at: index)).frame(width: 7, height: 7)
                        Text(item.name).font(.caption)
                        Text(MenuBarFormatter.percentText(item.percent))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Errors

private extension UsageError {
    var symbol: String {
        switch self {
        case .notLoggedIn: return "person.crop.circle.badge.questionmark"
        case .unauthorized: return "key"
        case .rateLimited: return "hourglass"
        case .network: return "wifi.exclamationmark"
        case .server, .decoding: return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .notLoggedIn: return String(localized: "Claude Code login not found")
        case .unauthorized: return String(localized: "Login expired")
        case .rateLimited: return String(localized: "Too many requests")
        case .network: return String(localized: "Can't reach Claude")
        case let .server(code): return String(localized: "Server error (\(code))")
        case .decoding: return String(localized: "Unexpected response")
        }
    }

    var message: String {
        switch self {
        case .notLoggedIn:
            return String(localized: "This app uses the login saved by Claude Code. Install Claude Code and run `claude` in Terminal to sign in.")
        case .unauthorized:
            return String(localized: "Run `claude` in Terminal once — Claude Code will refresh the login automatically.")
        case .rateLimited:
            return String(localized: "Will retry automatically in a few minutes.")
        case let .network(detail):
            return detail
        case .server:
            return String(localized: "Will retry automatically.")
        case .decoding:
            return String(localized: "The usage format may have changed. Check for an app update.")
        }
    }
}

private struct ErrorStateView: View {
    let error: UsageError

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: error.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(error.title)
                .font(.subheadline.weight(.semibold))
            Text(.init(error.message))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if error == .notLoggedIn {
                Link(String(localized: "Claude Code setup guide"), destination: AppInfo.claudeCodeDocsURL)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct ErrorBanner: View {
    let error: UsageError

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error.symbol)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.caption.weight(.semibold))
                Text(.init(error.message))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

/// 순수 SwiftUI 아이콘 버튼 (AppKit 컨트롤이 아니라서 스냅샷 렌더링에도 그대로 나옵니다)
private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
