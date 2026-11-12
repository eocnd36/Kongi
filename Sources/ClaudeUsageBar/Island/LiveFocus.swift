import ClaudeUsageCore
import SwiftUI

// MARK: - 테마 (앱 창과 아일랜드가 함께 씀)

enum KongiTheme {
    static let window = Color.black
    static let panel = Color(red: 0.055, green: 0.059, blue: 0.067)
    static let card = Color(red: 0.090, green: 0.094, blue: 0.106)
    static let field = Color(red: 0.122, green: 0.125, blue: 0.141)
    static let code = Color(red: 0.047, green: 0.051, blue: 0.063)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.96, green: 0.965, blue: 0.97)
    static let secondary = Color(red: 0.56, green: 0.58, blue: 0.61)
    static let muted = Color(red: 0.42, green: 0.44, blue: 0.47)
    static let accent = Color(red: 0.55, green: 0.89, blue: 0.64)
    static let onAccent = Color(red: 0.03, green: 0.12, blue: 0.06)
    static let green = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let orange = Color(red: 0.98, green: 0.57, blue: 0.24)
}

extension View {
    /// macOS 26부터는 Liquid Glass, 그 전에는 같은 모양의 어두운 카드
    @ViewBuilder
    func kongiGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        // macOS 26 SDK(Swift 6.2 이상)로 빌드할 때만 Liquid Glass를 넣습니다. 이전 SDK에서도 빌드되게.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            fallbackGlass(shape, tint: tint)
        }
        #else
        fallbackGlass(shape, tint: tint)
        #endif
    }

    private func fallbackGlass<S: Shape>(_ shape: S, tint: Color?) -> some View {
        background(shape.fill(tint.map { $0.opacity(0.35) } ?? KongiTheme.field))
            .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - 지금 어디를 읽고 쓰는지 (실시간 코드 화면)

/// 왼쪽에는 콩이와 진행 단계, 오른쪽에는 Claude가 지금 읽거나 고치는 코드를 편집기처럼 보여 줍니다.
/// 고치는 줄은 한 글자씩 써지고, 읽는 곳은 훑는 빛이 지나갑니다.
struct LiveFocusView: View {
    let session: AgentSession
    /// 아일랜드(작게) / 앱 창(크게)
    var large = false
    /// 콩이는 한 화면에 한 마리만: 아일랜드 머리글이나 창 옆 막대에 이미 있으면 끕니다 (기본값 끔).
    var showsCharacter = false
    /// 스크린샷(ImageRenderer)은 ScrollView를 그리지 못해 끌 수 있게 합니다.
    var scrollable = true

    private var focus: AgentActivity? {
        session.activities.last { $0.status == .running } ?? session.activities.last
    }

    var body: some View {
        HStack(alignment: .top, spacing: large ? 18 : 12) {
            sidebar
                .frame(width: large ? 150 : 112, alignment: .leading)
            CodeCard(activity: focus, session: session, visibleLines: large ? 16 : 9, large: large, scrollable: scrollable)
        }
    }

    private var mood: Kongi.Mood {
        session.state == .ended ? .sleeping : AgentStore.mood(of: session)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: large ? 12 : 8) {
            if showsCharacter {
                Kongi(mood: mood, size: large ? 46 : 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: session.title)
                    .font(.system(size: large ? 15 : 12, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: "Claude Code")
                    .font(.system(size: large ? 12 : 10.5))
                    .foregroundStyle(KongiTheme.secondary)
            }
            StepList(session: session, large: large)
        }
    }
}

/// 진행 단계: 왼쪽 줄기를 따라 단계가 자랍니다.
///
/// 지금 하는 단계는 줄기 끝의 봉오리가 숨 쉬고 이름 위로 빛이 지나가며, 끝나면 봉오리가 잎으로 피고 이름이 작아집니다.
/// 새 단계는 아래에서 흐릿하게 올라오고, 오래된 단계는 위로 접히며 사라집니다. 일이 끝나면 맨 끝에 꽃이 핍니다.
private struct StepList: View {
    let session: AgentSession
    let large: Bool

    private struct Step: Identifiable, Equatable {
        enum State { case done, running, failed, thinking, finished }
        var id: String
        var title: String
        var state: State
    }

    /// 최근 단계 세 개 (+ 생각 중이거나 다 끝났으면 그 줄)
    private var steps: [Step] {
        var result = session.activities.suffix(3).map { activity in
            Step(id: activity.id,
                 title: activity.activity.target.isEmpty ? activity.activity.verb : activity.activity.target,
                 state: activity.status == .running ? .running : activity.status == .failed ? .failed : .done)
        }
        if session.state == .thinking || session.state == .starting {
            result.append(Step(id: "thinking-\(session.activities.last?.id ?? "")", title: session.state.label, state: .thinking))
        } else if session.state == .done {
            result.append(Step(id: "done-\(session.activities.last?.id ?? "")", title: String(localized: "Done"), state: .finished))
        }
        return Array(result.suffix(3))
    }

    private var row: CGFloat { large ? 24 : 19 }

    var body: some View {
        let steps = self.steps
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                StepRow(step: step, latest: index == steps.count - 1, first: index == 0, large: large, height: row)
                    .transition(.asymmetric(
                        insertion: .modifier(active: Bloom(amount: 1), identity: Bloom(amount: 0)),
                        removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8, anchor: .topLeading))
                    ))
            }
        }
        .frame(height: row * 3, alignment: .bottom)
        .clipped()
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: steps)
    }

    /// 새 줄: 아래에서 흐릿하게 떠올라 또렷해집니다.
    private struct Bloom: ViewModifier {
        let amount: Double
        func body(content: Content) -> some View {
            content
                .offset(y: 14 * amount)
                .blur(radius: 4 * amount)
                .opacity(1 - amount)
        }
    }

    private struct StepRow: View {
        let step: Step
        let latest: Bool
        let first: Bool
        let large: Bool
        let height: CGFloat

        private var current: Bool { step.state == .running || step.state == .thinking }

        var body: some View {
            HStack(spacing: 7) {
                node
                    .frame(width: 14, height: height)
                    .background(alignment: .center) {
                        // 줄기: 위아래 줄과 이어집니다.
                        Rectangle()
                            .fill(KongiTheme.green.opacity(0.35))
                            .frame(width: 1.5)
                            .padding(.top, first ? height / 2 : 0)
                            .padding(.bottom, latest ? height / 2 : 0)
                    }
                Group {
                    if current {
                        GlowText(text: step.title)
                    } else {
                        Text(verbatim: step.title)
                            .foregroundStyle(step.state == .failed ? KongiTheme.red.opacity(0.85)
                                             : step.state == .finished ? KongiTheme.text : KongiTheme.secondary.opacity(0.85))
                    }
                }
                .font(.system(size: (large ? 13 : 11.5) - (current || step.state == .finished ? 0 : 1), weight: current ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(height: height)
        }

        @ViewBuilder
        private var node: some View {
            switch step.state {
            case .running, .thinking:
                Bud(thinking: step.state == .thinking, size: large ? 9 : 8)
            case .done:
                SproutLeaf()
                    .fill(KongiTheme.green)
                    .frame(width: large ? 10 : 9, height: large ? 7 : 6)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: large ? 8 : 7, weight: .heavy))
                    .foregroundStyle(KongiTheme.red)
                    .frame(width: 11, height: 11)
                    .background(Circle().fill(KongiTheme.code))
            case .finished:
                Circle()
                    .fill(KongiTheme.green)
                    .frame(width: large ? 11 : 10, height: large ? 11 : 10)
                    .overlay(Image(systemName: "checkmark").font(.system(size: large ? 6.5 : 6, weight: .black)).foregroundStyle(KongiTheme.onAccent))
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
    }

    /// 줄기 끝의 봉오리: 숨 쉬듯 커졌다 작아지고, 둘레로 고리가 퍼집니다. 생각 중이면 더 느리게.
    private struct Bud: View {
        let thinking: Bool
        let size: CGFloat

        var body: some View {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate * (thinking ? 0.6 : 1)
                let ring = (t / 1.2).truncatingRemainder(dividingBy: 1)
                ZStack {
                    Circle()
                        .stroke(KongiTheme.accent.opacity(0.6 * (1 - ring)), lineWidth: 1)
                        .frame(width: size * CGFloat(1 + ring * 1.2), height: size * CGFloat(1 + ring * 1.2))
                    Circle()
                        .fill(KongiTheme.accent)
                        .frame(width: size, height: size)
                        .scaleEffect(0.85 + 0.15 * sin(t * 4))
                }
            }
        }
    }
}

/// 단계가 끝나면 돋는 작은 잎
private struct SproutLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// 가는 호가 도는 진행 표시
struct Spinner: View {
    var size: CGFloat = 12
    var color: Color = KongiTheme.text

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
    }
}

/// 편집기처럼 생긴 코드 카드
private struct CodeCard: View {
    let activity: AgentActivity?
    let session: AgentSession
    let visibleLines: Int
    let large: Bool
    let scrollable: Bool

    private var fontSize: CGFloat { large ? 12.5 : 10.5 }
    private var rowHeight: CGFloat { large ? 22 : 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // 일하는 동안 머리글 아래로 빛줄기가 지나갑니다.
            ZStack {
                Rectangle().fill(KongiTheme.line).frame(height: 1)
                if activity?.status == .running || session.state == .thinking {
                    IndeterminateBar(color: barColor, height: 1.5)
                        .transition(.opacity)
                }
            }
            .frame(height: 1.5)
            // 높이는 고정 (섬이 단계마다 들썩이지 않게). 넘치는 줄은 안에서 스크롤되고, 쓰는 줄을 따라갑니다.
            content
                .frame(height: CGFloat(visibleLines) * rowHeight + (large ? 20 : 12), alignment: .top)
                .clipped()
        }
        .background(RoundedRectangle(cornerRadius: large ? 14 : 11, style: .continuous).fill(KongiTheme.code))
        .overlay(RoundedRectangle(cornerRadius: large ? 14 : 11, style: .continuous).strokeBorder(KongiTheme.line))
        .clipShape(RoundedRectangle(cornerRadius: large ? 14 : 11, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: activity?.id)
    }

    /// 고치면 초록, 읽으면 파랑, 명령은 주황, 나머지는 콩이 색
    private var barColor: Color {
        switch activity?.activity.kind {
        case .edit, .write: return KongiTheme.green
        case .read, .search: return Color(red: 0.42, green: 0.66, blue: 1.0)
        case .run: return KongiTheme.orange
        default: return KongiTheme.accent
        }
    }

    /// 코드가 아닌 단계(웹, 하위 에이전트, 계획 …)가 진행 중이면 그 단계를 크게 보여 줍니다.
    private var workingCard: AgentActivity? {
        guard let activity, activity.status == .running, activity.preview == nil, activity.excerpt == nil else { return nil }
        switch activity.activity.kind {
        case .web, .agent, .plan, .question, .other: return activity
        default: return nil
        }
    }

    private var path: String? {
        guard let activity else { return nil }
        if let excerpt = activity.excerpt { return excerpt.path }
        // 파일을 고치는 단계의 detail은 파일 경로입니다.
        return activity.preview != nil && activity.detail.hasPrefix("/") ? activity.detail : nil
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let path {
                FileBadge(name: (path as NSString).lastPathComponent, large: large)
                Text(verbatim: (path as NSString).lastPathComponent)
                    .font(.system(size: fontSize + 0.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(KongiTheme.text)
                    .lineLimit(1)
                if activity?.status == .running, activity?.preview != nil {
                    Circle().fill(KongiTheme.orange).frame(width: 6, height: 6)
                }
                Spacer(minLength: 8)
                Text(verbatim: Formatters.relativePath(path, in: session.launchDirectory ?? session.cwd))
                    .font(.system(size: fontSize - 0.5, design: .monospaced))
                    .foregroundStyle(KongiTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if let activity {
                Image(systemName: activity.activity.symbol)
                    .font(.system(size: fontSize))
                    .foregroundStyle(KongiTheme.secondary)
                GlowText(text: activity.activity.label, active: activity.status == .running,
                         base: activity.status == .running ? KongiTheme.secondary : KongiTheme.text)
                    .font(.system(size: fontSize + 0.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Text("No activity yet")
                    .font(.system(size: fontSize + 0.5))
                    .foregroundStyle(KongiTheme.muted)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, large ? 14 : 10)
        .frame(height: large ? 38 : 28)
        .background(Color.white.opacity(0.025))
    }

    @ViewBuilder
    private var content: some View {
        if let activity, let preview = activity.preview {
            EditLines(diff: preview, running: activity.status == .running, startedAt: activity.date,
                      fontSize: fontSize, rowHeight: rowHeight, scrollable: scrollable)
                .id(activity.id)
        } else if let activity, let excerpt = activity.excerpt {
            ReadLines(excerpt: excerpt, running: activity.status == .running, startedAt: activity.date,
                      fontSize: fontSize, rowHeight: rowHeight, scrollable: scrollable)
                .id(activity.id)
        } else if let activity, activity.activity.kind == .run || activity.activity.kind == .search {
            TerminalLines(activity: activity, fontSize: fontSize, rowHeight: rowHeight, visibleLines: visibleLines)
        } else if let working = workingCard {
            WorkingCard(activity: working, fontSize: fontSize, large: large)
        } else if let message = session.messages.last(where: { $0.role == .assistant }) {
            // 코드를 만지지 않는 동안에는 Claude가 마지막으로 한 말을 (방금 온 말이면 써 내려가며)
            VStack(alignment: .leading, spacing: 8) {
                BloomingMarkdown(id: "focus-" + message.id, text: message.text, date: message.date,
                                  fontSize: fontSize + 1, color: KongiTheme.secondary, lineSpacing: 3)
                if session.state == .thinking {
                    BeanDots()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(large ? 16 : 10)
        } else if session.state == .thinking || session.state == .starting {
            WorkingCard(activity: nil, fontSize: fontSize, large: large, label: session.state.label)
        } else {
            Color.clear
        }
    }
}

/// 코드가 아닌 단계 (웹 검색, 하위 에이전트, 계획, 생각 중): 큰 아이콘이 숨 쉬고, 하는 일에 빛이 지나갑니다.
private struct WorkingCard: View {
    let activity: AgentActivity?
    let fontSize: CGFloat
    let large: Bool
    var label: String? = nil

    private var symbol: String { activity?.activity.symbol ?? "sparkles" }
    private var title: String { label ?? activity?.activity.label ?? "" }

    var body: some View {
        VStack(spacing: large ? 14 : 9) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    // 퍼져 나가는 고리 두 개
                    ForEach(0..<2) { index in
                        let phase = (t / 1.8 + Double(index) / 2).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(KongiTheme.accent.opacity(0.5 * (1 - phase)), lineWidth: 1.2)
                            .scaleEffect(0.6 + phase * 0.9)
                    }
                    Image(systemName: symbol)
                        .font(.system(size: large ? 22 : 15, weight: .medium))
                        .foregroundStyle(KongiTheme.accent)
                        .scaleEffect(1 + 0.06 * sin(t * 3))
                }
                .frame(width: large ? 56 : 38, height: large ? 56 : 38)
            }
            GlowText(text: title)
                .font(.system(size: fontSize + 1.5, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            BeanDots(size: large ? 6 : 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(large ? 16 : 10)
    }
}

/// 파일 종류 배지 (TS, SW, PY …)
private struct FileBadge: View {
    let name: String
    let large: Bool

    private var info: (String, Color) {
        switch (name as NSString).pathExtension.lowercased() {
        case "ts", "tsx": return ("TS", Color(red: 0.19, green: 0.47, blue: 0.78))
        case "js", "jsx", "mjs": return ("JS", Color(red: 0.85, green: 0.74, blue: 0.16))
        case "swift": return ("SW", Color(red: 0.95, green: 0.42, blue: 0.24))
        case "py": return ("PY", Color(red: 0.22, green: 0.47, blue: 0.68))
        case "rs": return ("RS", Color(red: 0.72, green: 0.42, blue: 0.27))
        case "go": return ("GO", Color(red: 0.0, green: 0.68, blue: 0.84))
        case "json": return ("{}", Color(red: 0.45, green: 0.45, blue: 0.48))
        case "md": return ("MD", Color(red: 0.40, green: 0.42, blue: 0.48))
        case "html": return ("<>", Color(red: 0.89, green: 0.30, blue: 0.15))
        case "css", "scss": return ("CS", Color(red: 0.33, green: 0.38, blue: 0.85))
        case "sh", "zsh": return ("SH", Color(red: 0.30, green: 0.55, blue: 0.35))
        default: return ("··", Color(red: 0.35, green: 0.36, blue: 0.40))
        }
    }

    var body: some View {
        Text(verbatim: info.0)
            .font(.system(size: large ? 9 : 7.5, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: large ? 20 : 16, height: large ? 16 : 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(info.1))
    }
}

/// 고치는 줄: 지운 줄은 빨간 취소선, 새 줄은 초록으로 한 글자씩 써집니다.
/// 긴 줄은 잘리지 않고 접히며, 넘치면 쓰는 줄을 따라 스크롤됩니다.
private struct EditLines: View {
    let diff: LineDiff
    let running: Bool
    let startedAt: Date
    let fontSize: CGFloat
    let rowHeight: CGFloat
    let scrollable: Bool

    /// 여러 군데를 고치면 사이에 "⋯" 줄을 넣어 한 줄로 이어 붙입니다.
    private var rows: [LineDiff.Line?] {
        var result: [LineDiff.Line?] = []
        for (index, hunk) in diff.hunks.enumerated() {
            if index > 0 { result.append(nil) }
            result.append(contentsOf: hunk.lines.map(Optional.some))
        }
        return result
    }

    /// 새 줄의 글자 수 합 (다 쓰면 애니메이션을 멈춤)
    private var totalTyped: Int { diff.hunks.flatMap(\.lines).filter { $0.kind == .added }.reduce(0) { $0 + $1.text.count } }

    var body: some View {
        let rows = self.rows
        let total = totalTyped
        let elapsed = Date().timeIntervalSince(startedAt)
        let typing = running && Double(total) / Self.speed > elapsed
        ScrollViewReader { proxy in
            Scroll(enabled: scrollable) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { context in
                    let budget = running ? Int(context.date.timeIntervalSince(startedAt) * Self.speed) : Int.max
                    let blink = !typing || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    let typed = Self.typed(rows: rows, budget: budget)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(typed.rows.enumerated()), id: \.offset) { index, row in
                            Group {
                                if let line = row.line {
                                    CodeRow(
                                        number: line.kind == .removed ? line.oldNumber : line.newNumber,
                                        sign: line.kind == .added ? "+" : line.kind == .removed ? "-" : " ",
                                        text: row.shown,
                                        kind: line.kind,
                                        caret: row.caret && running && blink,
                                        fontSize: fontSize,
                                        minHeight: rowHeight
                                    )
                                    .equatable()
                                } else {
                                    Text(verbatim: "⋯")
                                        .font(.system(size: fontSize, design: .monospaced))
                                        .foregroundStyle(KongiTheme.muted)
                                        .padding(.leading, fontSize * 3 + 12)
                                        .frame(height: rowHeight)
                                }
                            }
                            .id(index)
                        }
                    }
                    .padding(.vertical, 6)
                    .onChange(of: typed.caretRow) { row in
                        guard scrollable, let row else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .center) }
                    }
                }
            }
            .onAppear {
                // 처음에는 바뀐 첫 줄이 보이게
                if scrollable, let first = rows.firstIndex(where: { $0?.kind != .context && $0 != nil }) {
                    proxy.scrollTo(max(first - 2, 0), anchor: .top)
                }
            }
        }
    }

    /// 초당 글자 수
    static let speed: Double = 80

    private struct TypedRow {
        var line: LineDiff.Line?
        var shown: String
        var caret: Bool
    }

    /// 새 줄은 앞에서부터 차례로, 주어진 글자 수만큼만 보여 줍니다. 아직 차례가 안 온 새 줄은 숨깁니다.
    private static func typed(rows: [LineDiff.Line?], budget: Int) -> (rows: [TypedRow], caretRow: Int?) {
        var remaining = budget
        var result: [TypedRow] = []
        var caretRow: Int?
        for row in rows {
            guard let line = row, line.kind == .added else {
                result.append(TypedRow(line: row, shown: row?.text ?? "", caret: false))
                continue
            }
            if remaining >= line.text.count {
                remaining -= line.text.count
                result.append(TypedRow(line: line, shown: line.text, caret: false))
            } else if caretRow == nil {
                result.append(TypedRow(line: line, shown: String(line.text.prefix(max(remaining, 0))), caret: true))
                caretRow = result.count - 1
                remaining = 0
            }
        }
        // 다 썼으면 마지막 새 줄 끝에서 커서가 깜빡입니다.
        if caretRow == nil, let index = result.lastIndex(where: { $0.line?.kind == .added }) {
            result[index].caret = true
            caretRow = index
        }
        return (result, caretRow)
    }
}

/// 읽는 곳: 줄 번호와 함께, 읽는 동안 훑는 빛이 아래로 지나갑니다 (빛 하나만 움직여 가볍게).
private struct ReadLines: View {
    let excerpt: CodeExcerpt
    let running: Bool
    let startedAt: Date
    let fontSize: CGFloat
    let rowHeight: CGFloat
    let scrollable: Bool

    /// 처음 열 때 줄이 위에서부터 차례로 불러와지듯 나타납니다 (초당 줄 수).
    private static let linesPerSecond: Double = 45

    var body: some View {
        let loading = running && Date().timeIntervalSince(startedAt) < Double(excerpt.lines.count) / Self.linesPerSecond
        Scroll(enabled: scrollable) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !loading)) { context in
                let loaded = loading ? context.date.timeIntervalSince(startedAt) * Self.linesPerSecond : .infinity
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(excerpt.lines.enumerated()), id: \.offset) { index, text in
                        CodeRow(number: excerpt.startLine + index, sign: nil, text: text, kind: .context,
                                caret: false, fontSize: fontSize, minHeight: rowHeight)
                            .equatable()
                            .opacity(min(1, max(0, loaded - Double(index))))
                            .offset(x: loaded - Double(index) < 1 ? 6 * (1 - max(0, loaded - Double(index))) : 0)
                    }
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .top) {
                if running {
                    GeometryReader { proxy in
                        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                            let travel = proxy.size.height + rowHeight * 3
                            let y = (context.date.timeIntervalSinceReferenceDate * Double(rowHeight) * 4)
                                .truncatingRemainder(dividingBy: Double(travel)) - Double(rowHeight * 1.5)
                            LinearGradient(
                                colors: [.clear, KongiTheme.accent.opacity(0.13), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: rowHeight * 3)
                            .offset(y: CGFloat(y))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// 켜면 세로 스크롤, 끄면 그대로 (스크린샷용)
private struct Scroll<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if enabled {
            ScrollView(.vertical) { content }.scrollIndicators(.never)
        } else {
            content
        }
    }
}

/// 명령·검색: 터미널처럼
private struct TerminalLines: View {
    let activity: AgentActivity
    let fontSize: CGFloat
    let rowHeight: CGFloat
    let visibleLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: activity.activity.kind == .search ? "⌕" : "$")
                    .foregroundStyle(KongiTheme.accent)
                Text(verbatim: activity.detail.isEmpty ? activity.activity.target : activity.detail)
                    .foregroundStyle(KongiTheme.text)
                    .lineLimit(3)
                if activity.status == .running { Spinner(size: fontSize, color: KongiTheme.secondary) }
            }
            if activity.status == .running, activity.output?.isEmpty ?? true {
                // 출력을 기다리는 동안 깜빡이는 커서
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Rectangle()
                        .fill(KongiTheme.accent.opacity(Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 0.9 : 0.15))
                        .frame(width: fontSize * 0.6, height: fontSize * 1.1)
                }
            }
            if let output = activity.output {
                Text(verbatim: output.split(separator: "\n", omittingEmptySubsequences: false).suffix(visibleLines - 2).joined(separator: "\n"))
                    .foregroundStyle(activity.status == .failed ? KongiTheme.red.opacity(0.9) : KongiTheme.secondary)
                    .lineSpacing(2)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 코드 한 줄: 줄 번호, 기호, 색칠한 코드. 긴 줄은 접힙니다.
/// 내용이 같으면 다시 그리지 않습니다 (Equatable) — 쓰는 중에도 바뀌는 줄만 새로 그림.
private struct CodeRow: View, Equatable {
    let number: Int?
    let sign: String?
    let text: String
    let kind: LineDiff.Line.Kind
    let caret: Bool
    let fontSize: CGFloat
    let minHeight: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: number.map(String.init) ?? "")
                .foregroundStyle(kind == .added ? KongiTheme.green : kind == .removed ? KongiTheme.red : KongiTheme.muted)
                .frame(width: fontSize * 3, alignment: .trailing)
                .padding(.trailing, 10)
            if let sign {
                Text(verbatim: sign)
                    .foregroundStyle(kind == .added ? KongiTheme.green : kind == .removed ? KongiTheme.red : .clear)
                    .frame(width: fontSize, alignment: .leading)
                    .padding(.trailing, 4)
            }
            (Text(SyntaxHighlighter.highlight(text, dimmed: kind == .removed))
                + Text(verbatim: caret ? "▏" : "").foregroundColor(KongiTheme.text))
                .strikethrough(kind == .removed, color: KongiTheme.red.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, (minHeight - fontSize * 1.3) / 2)
        .frame(minHeight: minHeight)
        .background(kind == .added ? KongiTheme.green.opacity(0.10) : kind == .removed ? KongiTheme.red.opacity(0.12) : .clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(kind == .added ? KongiTheme.green : kind == .removed ? KongiTheme.red : .clear)
                .frame(width: 2)
        }
    }
}

// MARK: - 간단한 문법 색칠 (여러 언어 공통 규칙)

enum SyntaxHighlighter {
    static let keywords: Set<String> = [
        "import", "from", "export", "default", "function", "return", "const", "let", "var", "func", "struct", "class",
        "enum", "protocol", "extension", "interface", "type", "if", "else", "for", "while", "in", "of", "switch", "case",
        "break", "continue", "public", "private", "fileprivate", "internal", "static", "final", "override", "async", "await",
        "try", "catch", "throw", "throws", "guard", "def", "lambda", "pass", "with", "as", "is", "new", "this", "self",
        "Self", "super", "true", "false", "nil", "null", "undefined", "None", "True", "False", "do", "fn", "pub", "mut",
        "impl", "use", "mod", "package", "go", "defer", "where", "some", "any", "init", "deinit", "get", "set", "yield",
    ]

    static let keyword = Color(red: 0.78, green: 0.57, blue: 0.92)
    static let string = Color(red: 0.76, green: 0.91, blue: 0.55)
    static let number = Color(red: 0.97, green: 0.55, blue: 0.42)
    static let type = Color(red: 1.0, green: 0.80, blue: 0.42)
    static let function = Color(red: 0.51, green: 0.67, blue: 1.0)
    static let comment = Color(red: 0.42, green: 0.45, blue: 0.50)
    static let plain = Color(red: 0.86, green: 0.88, blue: 0.91)

    /// 같은 줄을 매번 다시 색칠하지 않도록 기억해 둡니다.
    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
        return cache
    }()

    static func highlight(_ line: String, dimmed: Bool = false) -> AttributedString {
        let key = ((dimmed ? "1" : "0") + line) as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = compute(line, dimmed: dimmed)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    private static func compute(_ line: String, dimmed: Bool) -> AttributedString {
        var result = AttributedString()
        let chars = Array(line)
        var index = 0
        func append(_ text: String, _ color: Color) {
            var piece = AttributedString(text)
            piece.foregroundColor = dimmed ? color.opacity(0.55) : color
            result += piece
        }
        while index < chars.count {
            let c = chars[index]
            // 주석: //, #
            if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                append(String(chars[index...]), comment)
                break
            }
            if c == "#", index == chars.firstIndex(where: { !$0.isWhitespace }) {
                append(String(chars[index...]), comment)
                break
            }
            // 문자열
            if c == "\"" || c == "'" || c == "`" {
                var end = index + 1
                while end < chars.count, chars[end] != c { end += chars[end] == "\\" ? 2 : 1 }
                end = min(end + 1, chars.count)
                append(String(chars[index..<end]), string)
                index = end
                continue
            }
            // 숫자
            if c.isNumber {
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end] == "." || chars[end] == "_" { end += 1 }
                append(String(chars[index..<end]), number)
                index = end
                continue
            }
            // 이름
            if c.isLetter || c == "_" || c == "@" {
                var end = index + 1
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                let word = String(chars[index..<end])
                let next = chars[end...].first { !$0.isWhitespace }
                let color: Color
                if keywords.contains(word) || word.hasPrefix("@") { color = keyword }
                else if next == "(" { color = function }
                else if word.first?.isUppercase == true { color = type }
                else { color = plain }
                append(word, color)
                index = end
                continue
            }
            append(String(c), plain)
            index += 1
        }
        return result
    }
}
