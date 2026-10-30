import ClaudeUsageCore
import SwiftUI

// MARK: - 마크다운 (Claude의 대답)

/// 문단, 제목, 목록, 표, 코드 블록, 인용을 제 모양대로 그립니다. 줄 안의 굵게·`코드`·링크는 MessageBubble.rendered가 맡습니다.
struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 12
    var color: Color = .white.opacity(0.9)
    var lineSpacing: CGFloat = 1.5

    var body: some View {
        let blocks = MarkdownCache.blocks(for: text)
        VStack(alignment: .leading, spacing: fontSize * 0.6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        Text(MarkdownCache.inline(text))
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(.system(size: fontSize + max(0, CGFloat(4 - level)) * 1.5, weight: .bold))
                .foregroundStyle(KongiTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 2 : 0)
        case let .paragraph(text):
            inline(text)
                .font(.system(size: fontSize))
                .foregroundStyle(color)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: fontSize * 0.3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marker(for: item)
                        inline(item.text)
                            .font(.system(size: fontSize))
                            .foregroundStyle(item.checked == true ? color.opacity(0.6) : color)
                            .strikethrough(item.checked == true, color: color.opacity(0.5))
                            .lineSpacing(lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * fontSize * 1.2)
                }
            }
        case let .code(language, text):
            CodeBlockView(language: language, text: text, fontSize: fontSize)
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(KongiTheme.accent.opacity(0.6))
                    .frame(width: 3)
                inline(text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(KongiTheme.secondary)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(table):
            MarkdownTableView(table: table, fontSize: fontSize, color: color)
        case .rule:
            Rectangle().fill(KongiTheme.line).frame(height: 1).padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(checked ? KongiTheme.green : KongiTheme.secondary)
        } else if let number = item.number {
            Text(verbatim: "\(number).")
                .font(.system(size: fontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(KongiTheme.secondary)
        } else {
            Circle()
                .fill(item.depth == 0 ? KongiTheme.accent : KongiTheme.secondary)
                .frame(width: fontSize * 0.36, height: fontSize * 0.36)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + fontSize * 0.15 }
        }
    }
}

/// 같은 글을 매번 다시 나누지 않도록 기억합니다 (대화는 자주 다시 그려짐).
@MainActor
enum MarkdownCache {
    private static var blocks: [String: [MarkdownBlock]] = [:]
    private static var inlines: [String: AttributedString] = [:]

    static func blocks(for text: String) -> [MarkdownBlock] {
        if let cached = blocks[text] { return cached }
        if blocks.count > 300 { blocks.removeAll() }
        let parsed = Markdown.parse(text)
        blocks[text] = parsed
        return parsed
    }

    static func inline(_ text: String) -> AttributedString {
        if let cached = inlines[text] { return cached }
        if inlines.count > 1500 { inlines.removeAll() }
        let rendered = MessageBubble.rendered(text)
        inlines[text] = rendered
        return rendered
    }
}

/// 표: 좁으면 옆으로 밀어서 봅니다.
private struct MarkdownTableView: View {
    let table: MarkdownTable
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }.scrollIndicators(.never)
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    self.cell(cell, column: column, header: true)
                }
            }
            .background(Color.white.opacity(0.07))
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                Rectangle().fill(KongiTheme.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column, header: false)
                    }
                }
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.025))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(KongiTheme.line))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func cell(_ text: String, column: Int, header: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(MarkdownCache.inline(text))
            .font(.system(size: fontSize - 0.5, weight: header ? .semibold : .regular))
            .foregroundStyle(header ? KongiTheme.text : color)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .frame(maxWidth: 260, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .gridColumnAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }
}

/// 코드 블록: 고정폭 글꼴, 언어 이름, 긴 줄은 옆으로 밀기
private struct CodeBlockView: View {
    let language: String
    let text: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(verbatim: language)
                    .font(.system(size: fontSize - 2.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(KongiTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal) {
                Text(verbatim: text)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(KongiTheme.text.opacity(0.9))
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KongiTheme.code))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(KongiTheme.line))
    }
}

// MARK: - 실시간 효과

/// 부드럽게 시작하고 끝나는 0 → 1
private func smooth(_ x: Double) -> Double {
    let v = min(max(x, 0), 1)
    return v * v * (3 - 2 * v)
}

/// 지금 하는 일: 콩이 색 빛이 글자를 천천히 훑고 지나간 뒤 잠깐 쉽니다 (2초에 한 번).
/// `active`가 꺼지면 멈춘 평범한 글자가 됩니다.
struct GlowText: View {
    let text: String
    var active = true
    var base: Color = KongiTheme.secondary
    var glow: Color = KongiTheme.accent

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0)
                // 1.4초 동안 훑고 0.6초 쉼. 빛 띠는 글자 밖(-0.25)에서 들어와 밖(1.25)으로 나갑니다.
                let center = CGFloat(-0.25 + 1.5 * smooth(cycle / 1.4))
                let peak = Color.white.opacity(0.95)
                Text(verbatim: text)
                    .foregroundStyle(LinearGradient(stops: [
                        .init(color: base, location: 0),
                        .init(color: base, location: clamp(center - 0.22)),
                        .init(color: glow, location: clamp(center - 0.08)),
                        .init(color: peak, location: clamp(center)),
                        .init(color: glow, location: clamp(center + 0.08)),
                        .init(color: base, location: clamp(center + 0.22)),
                        .init(color: base, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
            }
        } else {
            Text(verbatim: text).foregroundStyle(base)
        }
    }

    private func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
}

/// 끝을 모르는 진행 막대: 짧은 빛줄기가 왼쪽에서 오른쪽으로 계속 지나갑니다.
struct IndeterminateBar: View {
    var color: Color = KongiTheme.accent
    var height: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let width = proxy.size.width * 0.35
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: height)
                    .offset(x: CGFloat(t) * (proxy.size.width + width) - width)
            }
        }
        .frame(height: height)
        .clipped()
    }
}

/// 콩 세 알이 차례로 통통 튀어 오르고, 내려앉을 때 살짝 납작해집니다 (생각하거나 쓰는 중).
struct BeanDots: View {
    var color: Color = KongiTheme.accent
    var size: CGFloat = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, area in
                for index in 0..<3 {
                    let phase = (t * 1.5 - Double(index) * 0.17).truncatingRemainder(dividingBy: 1)
                    let p = phase < 0 ? phase + 1 : phase
                    // 앞 절반은 뛰어오르고, 바로 뒤에 납작하게 내려앉습니다.
                    let hop = p < 0.5 ? sin(p / 0.5 * .pi) : 0
                    let land = p >= 0.5 && p < 0.62 ? sin((p - 0.5) / 0.12 * .pi) : 0
                    let w = size * 1.25 * CGFloat(1 + land * 0.2)
                    let h = size * CGFloat(1 - land * 0.25)
                    let x = size * 0.9 + CGFloat(index) * size * 2.1
                    let bottom = area.height - 1
                    let y = bottom - h - CGFloat(hop) * size * 1.3
                    let rect = CGRect(x: x - w / 2, y: y, width: w, height: h)
                    canvas.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.45 + 0.55 * hop)))
                }
            }
        }
        .frame(width: size * 6.2, height: size * 2.6)
    }
}

/// 방금 들어온 대답은 단어가 하나씩 흐릿하게 피어나며 써지고, 끝에서 콩이 색 점이 숨 쉽니다.
/// 다 쓰면 마크다운 모양으로 바뀝니다. 같은 대답을 다시 그려도 두 번 써지지 않도록 써 본 대답을 기억합니다.
struct BloomingMarkdown: View {
    let id: String
    let text: String
    let date: Date
    var fontSize: CGFloat = 12
    var color: Color = .white.opacity(0.9)
    var lineSpacing: CGFloat = 1.5

    @State private var start: Date?

    @MainActor private static var played: Set<String> = []

    /// 단어마다 빈칸까지 붙여 둡니다 (줄바꿈을 그대로 두려고).
    private var words: [Substring] {
        var result: [Substring] = []
        var begin = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == " " || text[index] == "\n" {
                let next = text.index(after: index)
                result.append(text[begin..<next])
                begin = next
            }
            index = text.index(after: index)
        }
        if begin < text.endIndex { result.append(text[begin...]) }
        return result
    }

    /// 단어당 45ms, 전체는 0.8 ~ 5초
    private var duration: Double { min(5, max(0.8, Double(words.count) * 0.045)) }
    private static let fade = 0.25

    var body: some View {
        Group {
            if let start {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    bloom(elapsed: context.date.timeIntervalSince(start), t: context.date.timeIntervalSinceReferenceDate)
                        .font(.system(size: fontSize))
                        .lineSpacing(lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            } else {
                MarkdownView(text: text, fontSize: fontSize, color: color, lineSpacing: lineSpacing)
                    .transition(.opacity)
            }
        }
        .onAppear {
            guard !Self.played.contains(id) else { return }
            Self.played.insert(id)
            // 방금(10초 안) 들어온 대답만 피어납니다.
            guard Date().timeIntervalSince(date) < 10 else { return }
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + Self.fade + 0.2) {
                withAnimation(.easeOut(duration: 0.25)) { start = nil }
            }
        }
    }

    private func bloom(elapsed: Double, t: Double) -> Text {
        let words = self.words
        let step = duration / Double(max(words.count, 1))
        var settled = ""
        var result = Text(verbatim: "")
        for (index, word) in words.enumerated() {
            let age = elapsed - Double(index) * step
            if age >= Self.fade {
                settled += word
                continue
            }
            // 아직 피어나는 중인 단어들
            if !settled.isEmpty {
                result = result + Text(verbatim: settled).foregroundColor(color)
                settled = ""
            }
            if age <= 0 { break }
            result = result + Text(verbatim: String(word)).foregroundColor(color.opacity(smooth(age / Self.fade)))
        }
        if !settled.isEmpty { result = result + Text(verbatim: settled).foregroundColor(color) }
        // 끝에서 숨 쉬는 콩이 색 점
        let breath = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 5))
        return result + Text(verbatim: " ●").foregroundColor(KongiTheme.accent.opacity(breath))
    }
}
