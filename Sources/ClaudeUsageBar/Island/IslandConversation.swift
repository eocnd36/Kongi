import AppKit
import ClaudeUsageCore
import SwiftUI

// MARK: - 대화 타임라인 (사용자의 말, Claude의 글, 하는 일이 실시간으로)

/// 세션 화면의 "대화" 탭: 무엇을 부탁했고, Claude가 무슨 말을 하며 무엇을 고치는지 차례로 보여 주고,
/// 아래 입력 칸에서 같은 대화에 이어서 말할 수 있습니다.
struct SessionConversation: View {
    @ObservedObject var model: IslandModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.rendersForSnapshot {
                // ImageRenderer는 ScrollView를 그리지 못해 스크린샷에서는 그대로 그립니다.
                SessionTimeline(model: model, session: session)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        SessionTimeline(model: model, session: session)
                            .padding(.trailing, 4)
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .frame(height: timelineHeight)
                    .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    .onChange(of: lastItemKey) { _ in
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    }
                }
            }
            Composer(model: model, session: session)
        }
    }

    private static let bottom = "timeline-bottom"

    /// 새 글이나 새 단계가 들어오면 맨 아래로 내려갑니다.
    private var lastItemKey: String {
        "\(session.messages.last?.id ?? "")|\(session.activities.last?.id ?? "")|\(session.activities.last?.status.rawValue ?? "")|\(session.state.label)"
    }

    /// 내용이 많으면 고정 높이로 두고 스크롤합니다 (예전에는 줄 수로 어림해 긴 글이 잘렸음).
    private var timelineHeight: CGFloat {
        let items = session.messages.count + session.activities.count
        if items == 0 { return 60 }
        let estimate = session.messages.suffix(8).reduce(CGFloat(0)) { $0 + CGFloat($1.text.count / 55 + 1) * 17 + 14 }
            + CGFloat(session.activities.suffix(12).count) * 26
        return min(max(estimate, 120), 380)
    }
}

/// 대화의 한 줄: 말 또는 단계
private enum TimelineItem: Identifiable {
    case message(AgentMessage)
    case activity(AgentActivity)

    var id: String {
        switch self {
        case let .message(message): return "m-" + message.id
        case let .activity(activity): return "a-" + activity.id
        }
    }

    var date: Date {
        switch self {
        case let .message(message): return message.date
        case let .activity(activity): return activity.date
        }
    }
}

struct SessionTimeline: View {
    @ObservedObject var model: IslandModel
    let session: AgentSession
    /// 앱 창에서는 넓게
    var large = false
    /// 파일 변경을 눌렀을 때 (없으면 아일랜드의 diff 화면으로)
    var openFile: ((String) -> Void)?

    private var items: [TimelineItem] {
        let all = session.messages.map(TimelineItem.message) + session.activities.map(TimelineItem.activity)
        return Array(all.sorted { $0.date < $1.date }.suffix(80))
    }

    var body: some View {
        let items = self.items
        LazyVStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text("No activity yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            ForEach(items) { item in
                Group {
                    switch item {
                    case let .message(message):
                        MessageBubble(message: message, isLatest: message.id == session.messages.last(where: { $0.role == .assistant })?.id, large: large)
                    case let .activity(activity):
                        ActivityStep(activity: activity) { path in
                            if let openFile { openFile(path) } else { model.navigate(to: .diff(sessionId: session.id, path: path)) }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // 단계가 진행 중이면 그 줄이 깜빡이므로, 생각만 하는 동안에만 따로 표시합니다.
            if session.state == .thinking || session.state == .starting {
                WorkingIndicator(label: session.state.label)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: items.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: session.state == .thinking)
    }
}

struct MessageBubble: View {
    let message: AgentMessage
    /// 가장 최근 대답은 처음부터 다 보여 줍니다.
    var isLatest = false
    var large = false
    @State private var expanded = false

    private var showsAll: Bool { expanded || isLatest || large }

    /// 굵게, 기울임, `코드`, 링크 같은 마크다운을 그대로 보여 줍니다.
    static func rendered(_ text: String) -> AttributedString {
        let cleaned = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // 제목(#)은 기호만 떼고 굵게 보이도록
            let trimmed = line.drop { $0 == "#" }
            return trimmed.count < line.count ? "**" + trimmed.trimmingCharacters(in: .whitespaces) + "**" : String(line)
        }.joined(separator: "\n")
        guard var rendered = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        // 대화 내용은 믿을 수 없으므로 링크를 누를 수 없게 하고, 보이는 글자와 실제 주소가 다르면 주소를 함께 적습니다.
        let links = rendered.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links.reversed() {
            let shown = String(rendered[range].characters)
            rendered[range].link = nil
            if shown != url.absoluteString {
                var address = AttributedString(" (\(url.absoluteString))")
                address.foregroundColor = KongiTheme.secondary
                rendered.insert(address, at: range.upperBound)
            }
        }
        return rendered
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Self.rendered(message.text))
                        .font(.system(size: large ? 13 : 12))
                        .foregroundStyle(KongiTheme.onAccent)
                        .lineLimit(showsAll ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(KongiTheme.accent.opacity(message.queued == true ? 0.45 : 1))
                        )
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                    if message.queued == true {
                        Label("Sends when Claude pauses", systemImage: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        case .assistant:
            HStack(alignment: .top, spacing: 7) {
                ClaudeGlyph(mood: .idle, size: 11)
                    .frame(width: 14, height: 16)
                BloomingMarkdown(id: message.id, text: message.text, date: message.date,
                                  fontSize: large ? 13.5 : 12, lineSpacing: large ? 3 : 1.5)
                    .frame(maxHeight: collapsed ? 150 : nil, alignment: .top)
                    .clipped()
                    .mask(alignment: .top) {
                        // 접힌 긴 대답은 아래쪽이 흐려지며 끝납니다.
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: collapsed ? 0.7 : 1), .init(color: collapsed ? .clear : .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .textSelection(.enabled)
                    .contentShape(Rectangle())
                    .onTapGesture { if isLong { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    /// 대충 8줄을 넘는 대답
    private var isLong: Bool {
        message.text.count > 420 || message.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 7
    }

    private var collapsed: Bool { !showsAll && isLong }
}

/// Claude가 한 일 한 단계. 파일을 고치면 바뀐 줄을 바로 보여 주고, 명령은 출력 끝부분을 보여 줍니다.
private struct ActivityStep: View {
    let activity: AgentActivity
    let openFile: (String) -> Void
    @State private var showsOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: activity.activity.symbol)
                    .font(.system(size: 10))
                    .frame(width: 14)
                    .foregroundStyle(.white.opacity(0.6))
                GlowText(text: activity.activity.label, active: activity.status == .running,
                         base: activity.status == .running ? KongiTheme.secondary : .white.opacity(0.85))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: activity.detail))
                Spacer(minLength: 4)
                if let preview = activity.preview {
                    ChangeCount(added: preview.added, removed: preview.removed)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                StepStatus(status: activity.status)
                Text(activity.date, style: .time)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
            }
            if let preview = activity.preview {
                MiniDiff(diff: preview, maxLines: activity.status == .running ? 10 : 5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !activity.detail.isEmpty { openFile(activity.detail) }
                    }
            }
            if let output = activity.output, !output.isEmpty {
                Text(verbatim: output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(activity.status == .failed ? Color.red.opacity(0.85) : .white.opacity(0.55))
                    .lineLimit(showsOutput ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsOutput.toggle() } }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 단계 상태: 진행 중이면 숨 쉬듯 깜빡이고, 끝나면 체크(또는 X)로 바뀝니다.
private struct StepStatus: View {
    let status: AgentActivity.Status

    var body: some View {
        ZStack {
            switch status {
            case .running:
                PulsingDot(color: .orange, size: 6)
            case .succeeded:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .failed:
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 12, height: 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: status)
    }
}

/// 짧은 diff: 바뀐 줄 위주로 몇 줄만
struct MiniDiff: View {
    let diff: LineDiff
    let maxLines: Int

    var body: some View {
        let lines = diff.hunks.flatMap(\.lines).filter { $0.kind != .context || diff.added + diff.removed < 4 }
        let shown = Array(lines.prefix(maxLines))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(line.kind == .added ? Color.green : line.kind == .removed ? Color.red : .white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 0.5)
                .background(line.kind == .added ? Color.green.opacity(0.12) : line.kind == .removed ? Color.red.opacity(0.12) : .clear)
            }
            if lines.count > shown.count {
                Text(String(localized: "\(lines.count - shown.count) more lines"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// "생각하는 중…" 같은 진행 표시 (점 세 개가 차례로 움직임)
private struct WorkingIndicator: View {
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            BeanDots()
                .frame(width: 16)
            GlowText(text: label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 입력 칸: 같은 대화에 이어서 말하기

struct Composer: View {
    @ObservedObject var model: IslandModel
    let session: AgentSession
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var scheduler: PromptScheduler
    @State private var feedback: AgentStore.SendResult?

    private var draft: Binding<String> {
        Binding(get: { agents.drafts[session.id] ?? "" }, set: { agents.drafts[session.id] = $0 })
    }
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...5)
                    .focused($focused)
                    .shiftReturnInsertsNewline()
                    .onSubmit(send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(focused ? 0.12 : 0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(KongiTheme.accent.opacity(focused ? 0.5 : 0), lineWidth: 1)
                    )
                    .animation(.easeOut(duration: 0.15), value: focused)
                // macOS 받아쓰기 (권한 필요 없음): 입력 칸에 바로 받아 적습니다.
                Button {
                    focused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
                    }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .kongiGlass(Circle(), interactive: true)
                }
                .buttonStyle(IslandPressStyle())
                .help(Text("Dictate"))
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.black : .white.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend ? KongiTheme.accent : Color.white.opacity(0.1)))
                }
                .buttonStyle(IslandPressStyle())
                .disabled(!canSend)
                .help(Text("Send"))
                .animation(.easeOut(duration: 0.15), value: canSend)
            }
            HStack(spacing: 8) {
                if let feedback {
                    FeedbackLine(result: feedback, sessionId: session.id)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer(minLength: 0)
                if session.state != .ended {
                    ContinueAfterResetChip(session: session)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: feedback)
        }
        .onChange(of: focused) { isFocused in
            // 쓰는 동안 마우스가 벗어나도 접히지 않게
            if isFocused { model.pinned = true }
        }
        .onChange(of: agents.queued[session.id]?.count ?? 0) { count in
            if count == 0, feedback == .queued { feedback = .sent }
        }
    }

    private var canSend: Bool { !(agents.drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        session.state == .ended
            ? String(localized: "Continue this conversation…")
            : String(localized: "Message Claude…")
    }

    private func send() {
        guard canSend else { return }
        let result = agents.send(agents.drafts[session.id] ?? "", to: session.id)
        feedback = result
        if result != .needsUpdate, result != .failed { agents.drafts[session.id] = nil }
        if result == .sent || result == .resumed {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if feedback == result { feedback = nil }
            }
        }
    }
}

private struct FeedbackLine: View {
    let result: AgentStore.SendResult
    let sessionId: String
    @EnvironmentObject private var agents: AgentStore

    var body: some View {
        switch result {
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 11, weight: .medium))
        case .queued:
            HStack(spacing: 6) {
                Label("Claude is working — sends when it pauses", systemImage: "clock")
                    .foregroundStyle(.white.opacity(0.65))
                Button(String(localized: "Cancel")) { agents.cancelQueued(for: sessionId) }
                    .buttonStyle(.plain)
                    .foregroundStyle(KongiTheme.accent)
            }
            .font(.system(size: 11))
        case .resumed:
            Label("The conversation had ended, so it continues in the background", systemImage: "arrow.clockwise")
                .foregroundStyle(.white.opacity(0.65))
                .font(.system(size: 11))
        case .needsUpdate:
            HStack(spacing: 6) {
                Label("Update the Claude Code connection to send from here", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(String(localized: "Update")) { HookSetupFlow.run() }
                    .buttonStyle(.plain)
                    .foregroundStyle(KongiTheme.accent)
            }
            .font(.system(size: 11))
        case .failed:
            Label("Couldn't send", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 11))
        }
    }
}

/// 한도 초기화 직후 이 대화에 "이어서 계속해"를 보내도록 예약 (예전의 시계 아이콘)
private struct ContinueAfterResetChip: View {
    let session: AgentSession
    @EnvironmentObject private var scheduler: PromptScheduler

    var body: some View {
        let pending = scheduler.pendingContinue(sessionId: session.id)
        Button {
            if let pending {
                scheduler.delete(pending.id)
            } else {
                scheduler.scheduleContinue(session: session, trigger: .sessionReset)
            }
        } label: {
            Label(
                pending != nil ? String(localized: "Continues after reset") : String(localized: "Continue after reset"),
                systemImage: pending != nil ? "clock.badge.checkmark" : "clock.arrow.circlepath"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(pending != nil ? Color.green : .white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(pending != nil ? Color.green.opacity(0.15) : Color.white.opacity(0.08)))
        }
        .buttonStyle(IslandPressStyle())
        .help(Text(pending != nil
                   ? "Scheduled: right after your usage limit resets, Kongi sends “Continue where you left off.” to this conversation. Click to cancel."
                   : "Right after your usage limit resets, send “Continue where you left off.” to this conversation."))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: pending != nil)
    }
}

// MARK: - 공통 장식


/// 진행 중 표시: 점 주위로 물결이 퍼집니다.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulses = true
    @State private var expand = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .stroke(color.opacity(0.7), lineWidth: 1.2)
                    .scaleEffect(expand ? 2.4 : 1)
                    .opacity(expand ? 0 : (pulses ? 0.8 : 0))
            )
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { expand = true }
            }
    }
}

/// 버튼 공통: 마우스를 올리면 살짝 밝아지고, 누르면 쏙 들어갑니다.
struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .brightness(hovering && isEnabled ? 0.1 : 0)
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// Return은 보내기, Shift+Return은 커서 자리에 줄바꿈 (macOS 13은 Option+Return으로 줄바꿈)
    @ViewBuilder
    func shiftReturnInsertsNewline() -> some View {
        if #available(macOS 14.0, *) {
            onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                return .handled
            }
        } else {
            self
        }
    }

    /// 숫자가 바뀔 때 굴러가듯 바뀝니다 (macOS 14 이상).
    @ViewBuilder
    func numericTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    /// 마우스를 올리면 배경이 살짝 밝아지는 줄
    func islandHoverRow(cornerRadius: CGFloat = 10, base: Double = 0.06) -> some View {
        modifier(HoverRow(cornerRadius: cornerRadius, base: base))
    }
}

private struct HoverRow: ViewModifier {
    let cornerRadius: CGFloat
    let base: Double
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.white.opacity(hovering ? base + 0.05 : base)))
            .animation(.easeOut(duration: 0.14), value: hovering)
            .onHover { hovering = $0 }
    }
}
