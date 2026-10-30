import ClaudeUsageCore
import SwiftUI

/// 아일랜드에 사는 캐릭터 "콩이". 새싹이 난 강낭콩입니다.
/// 이미지 파일 없이 Canvas에 도형으로만 그리며, 하는 일에 따라 움직임과 표정이 달라집니다.
/// 안드로이드 앱의 KongiCharacter.kt와 같은 수식으로 그립니다.
struct Kongi: View {
    /// 이름은 휴대폰 앱에도 그대로 보냅니다.
    enum Mood: String, Equatable {
        /// 세션 없음
        case sleeping
        /// 대기 중 (가끔 두리번거리고 하품함)
        case idle
        /// Claude가 일하는 중 (그 밖의 도구)
        case working
        /// 승인·답변이 필요함
        case alert
        /// 작업 완료
        case happy
        /// 파일을 읽는 중: 눈이 줄을 따라 왼쪽에서 오른쪽으로
        case reading
        /// 파일을 고치는 중: 통통거리며 초록 +가 올라감
        case editing
        /// 명령을 실행하는 중: 뛰면서 김이 남
        case running
        /// 찾는 중 (검색, 웹): 고개를 돌리며 두리번
        case searching
        /// 생각하는 중: 눈을 위로, 생각 방울
        case thinking
        /// 명령이 실패함: 잎이 처지고 식은땀
        case sad

        /// Claude가 일하고 있는 기분인지
        var isBusy: Bool {
            switch self {
            case .working, .reading, .editing, .running, .searching, .thinking: return true
            default: return false
            }
        }

        /// 지금 하는 도구에 맞는 기분
        static func doing(_ kind: ToolActivity.Kind) -> Mood {
            switch kind {
            case .read: return .reading
            case .edit, .write: return .editing
            case .run: return .running
            case .search, .web: return .searching
            case .question: return .alert
            case .agent, .plan, .other: return .working
            }
        }
    }

    var mood: Mood
    var size: CGFloat = 22
    /// 오늘 쓴 만큼 자랍니다 (0…1, 5시간 사용량). 잎이 커지고 많이 쓰면 꽃이 핍니다.
    @Environment(\.kongiGrowth) private var growth

    /// 기분이 바뀔 때 이전 움직임에서 새 움직임으로 부드럽게 넘어갑니다.
    @State private var previousMood: Mood?
    @State private var shownMood: Mood?
    @State private var changedAt = Date.distantPast
    @State private var tappedAt = Date.distantPast
    @State private var hovering = false

    private static let blendDuration = 0.45

    var body: some View {
        let lively = mood != .sleeping && mood != .idle
        TimelineView(.animation(minimumInterval: lively || hovering ? 1 / 30 : (mood == .idle ? 1 / 20 : 1 / 8))) { context in
            let now = context.date
            Canvas { canvas, area in
                let s = min(area.width, area.height) / 1.5
                let t = now.timeIntervalSinceReferenceDate
                var pose = KongiPose.make(mood, t: t, growth: growth)
                let blend = blendProgress(at: now)
                if blend < 1, let previousMood, previousMood != mood {
                    pose = KongiPose.make(previousMood, t: t, growth: growth).mixed(with: pose, blend)
                }
                if hovering, mood == .idle || mood == .sleeping { pose.eye = .wide }
                pose.tapAge = now.timeIntervalSince(tappedAt)
                KongiPainter.draw(in: &canvas, size: area, s: s, pose: pose, t: t)
            }
        }
        .onAppear { shownMood = mood }
        .onChange(of: mood) { newMood in
            previousMood = shownMood ?? newMood
            shownMood = newMood
            changedAt = Date()
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tappedAt = Date() }
        .accessibilityLabel(Text(verbatim: "Kongi"))
    }

    /// 0 → 1: 이전 기분에서 지금 기분으로 넘어간 정도 (부드럽게 시작하고 끝남)
    private func blendProgress(at date: Date) -> Double {
        let x = min(max(date.timeIntervalSince(changedAt) / Self.blendDuration, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

// MARK: - 자세 (기분 + 시간 → 그릴 값)

struct KongiPose {
    enum Eye { case open(Double), closed, happy, sad, wide }
    enum Mouth { case dash, small, smile, frown, yawn(Double) }

    var lift = 0.0
    var squash = 0.0
    /// 새싹이 흔들리는 각도 (도)
    var sway = 0.0
    /// 몸 전체 기울기 (도)
    var tilt = 0.0
    var lookX = 0.0
    var lookY = 0.0
    /// 잎이 처지는 각도 (도)
    var droop = 0.0
    var eye: Eye = .open(0.12)
    var mouth: Mouth = .dash
    var growth = 0.3
    /// 장식: 각 0…1 세기
    var sparkles = 0.0, bubble = 0.0, snore = 0.0, steam = 0.0, plus = 0.0, thought = 0.0, sweat = 0.0
    /// 눌린 뒤 지난 시간 (초): 찌그러지고 하트가 올라감
    var tapAge = 99.0

    static func make(_ mood: Kongi.Mood, t: Double, growth: Double) -> KongiPose {
        var p = KongiPose()
        p.growth = growth
        let blink = t.truncatingRemainder(dividingBy: 4.2) < 0.13
        switch mood {
        case .sleeping:
            p.squash = sin(t * 1.2) * 0.02
            p.eye = .closed
            p.snore = 1
        case .idle:
            p.squash = sin(t * 2) * 0.025
            p.sway = sin(t * 1.3) * 4
            p.eye = blink ? .closed : .open(0.12)
            // 7초마다 한 번 두리번
            let look = t.truncatingRemainder(dividingBy: 7)
            if look > 4, look < 5.6 { p.lookX = sin((look - 4) / 1.6 * 2 * .pi) * 0.08 }
            // 23초마다 한 번 하품
            let yawn = t.truncatingRemainder(dividingBy: 23)
            if yawn < 1.4 {
                let amount = sin(yawn / 1.4 * .pi)
                p.mouth = .yawn(amount)
                if amount > 0.3 { p.eye = .closed }
                p.squash += amount * 0.04
            }
        case .working:
            p.lift = -abs(sin(t * 9)) * 0.06
            p.squash = sin(t * 18) * 0.03
            p.sway = sin(t * 6) * 14
            p.lookX = sin(t * 1.7) * 0.07
            p.eye = blink ? .closed : .open(0.12)
        case .reading:
            // 줄을 따라 왼쪽 → 오른쪽, 끝에서 다음 줄로 빠르게 돌아가며 살짝 끄덕
            let line = (t / 1.6).truncatingRemainder(dividingBy: 1)
            p.lookX = line < 0.8 ? -0.07 + 0.14 * (line / 0.8) : 0.07 - 0.14 * ((line - 0.8) / 0.2)
            p.lookY = 0.02
            p.lift = line > 0.8 ? -0.03 * sin((line - 0.8) / 0.2 * .pi) : 0
            p.squash = sin(t * 2) * 0.02
            p.sway = sin(t * 1.6) * 5
            p.eye = blink ? .closed : .open(0.1)
        case .editing:
            p.lift = -abs(sin(t * 10)) * 0.05
            p.squash = sin(t * 20) * 0.025
            p.sway = sin(t * 14) * 9
            p.lookY = 0.035
            p.eye = .open(0.11)
            p.plus = 1
        case .running:
            let stride = abs(sin(t * 8))
            p.lift = -stride * 0.12
            p.squash = pow(1 - stride, 4) * -0.08
            p.sway = sin(t * 8) * 10
            p.eye = .open(0.12)
            p.mouth = .small
            p.steam = 1
        case .searching:
            p.tilt = sin(t * 2.2) * 7
            p.lookX = sin(t * 2.2) * 0.1
            p.sway = sin(t * 2.2) * 8
            p.eye = blink ? .closed : .wide
            p.mouth = .small
        case .thinking:
            p.lookX = 0.05
            p.lookY = -0.045
            p.sway = sin(t * 1.5) * 5
            p.squash = sin(t * 1.8) * 0.02
            p.eye = blink ? .closed : .open(0.12)
            p.thought = 1
        case .alert:
            p.lift = -abs(sin(t * 7)) * 0.16
            p.sway = sin(t * 14) * 10
            p.eye = .wide
            p.mouth = .small
            p.bubble = 1
        case .happy:
            p.lift = -abs(sin(t * 6)) * 0.22
            p.squash = -sin(t * 12) * 0.04
            p.sway = sin(t * 6) * 18
            p.eye = .happy
            p.mouth = .smile
            p.sparkles = 1
        case .sad:
            p.squash = -0.04 + sin(t * 1.5) * 0.01
            p.droop = 35
            p.sway = sin(t * 1.1) * 2
            p.lookY = 0.03
            p.eye = .sad
            p.mouth = .frown
            p.sweat = 1
        }
        return p
    }

    /// 다른 자세로 섞기 (움직임은 섞고, 표정은 절반을 넘으면 바뀜)
    func mixed(with other: KongiPose, _ amount: Double) -> KongiPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        var result = amount < 0.5 ? self : other
        result.lift = mix(lift, other.lift)
        result.squash = mix(squash, other.squash)
        result.sway = mix(sway, other.sway)
        result.tilt = mix(tilt, other.tilt)
        result.lookX = mix(lookX, other.lookX)
        result.lookY = mix(lookY, other.lookY)
        result.droop = mix(droop, other.droop)
        result.sparkles = mix(sparkles, other.sparkles)
        result.bubble = mix(bubble, other.bubble)
        result.snore = mix(snore, other.snore)
        result.steam = mix(steam, other.steam)
        result.plus = mix(plus, other.plus)
        result.thought = mix(thought, other.thought)
        result.sweat = mix(sweat, other.sweat)
        return result
    }
}

// MARK: - 그리기

private enum KongiPainter {
    static let bodyTop = Color(red: 0.71, green: 0.93, blue: 0.75)
    static let bodyBottom = Color(red: 0.50, green: 0.78, blue: 0.56)
    static let leaf = Color(red: 0.33, green: 0.72, blue: 0.40)
    static let ink = Color(red: 0.12, green: 0.17, blue: 0.14)
    static let cheek = Color(red: 1.0, green: 0.62, blue: 0.66)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.04)

    static func draw(in canvas: inout GraphicsContext, size: CGSize, s: CGFloat, pose: KongiPose, t: Double) {
        let cx = size.width / 2
        let cy = size.height / 2 + s * 0.12
        let bottom = CGPoint(x: cx, y: cy + s * 0.41)

        // 눌리면 납작해졌다가 튕겨 돌아옵니다.
        let tap = pose.tapAge < 0.6 ? -0.14 * exp(-pose.tapAge * 7) * cos(pose.tapAge * 22) : 0

        var body = canvas
        body.translateBy(x: 0, y: CGFloat(pose.lift) * s)
        rotate(&body, degrees: pose.tilt, around: bottom)
        scale(&body, x: 1 - CGFloat(pose.squash + tap) / 2, y: 1 + CGFloat(pose.squash + tap), around: bottom)

        // 새싹
        let stemBase = CGPoint(x: cx, y: cy - s * 0.36)
        var sprout = body
        rotate(&sprout, degrees: pose.sway, around: stemBase)
        let leafSize = 0.85 + pose.growth * 0.5
        let stemTop = CGPoint(x: cx, y: stemBase.y - s * CGFloat(0.18 + pose.growth * 0.1))
        var stem = Path()
        stem.move(to: stemBase)
        stem.addLine(to: stemTop)
        sprout.stroke(stem, with: .color(leaf), style: StrokeStyle(lineWidth: s * 0.07, lineCap: .round))
        for side in [-1.0, 1.0] {
            var leafContext = sprout
            let base = CGPoint(x: stemTop.x, y: stemTop.y + (side > 0 ? s * 0.02 : 0))
            rotate(&leafContext, degrees: side * pose.droop, around: base)
            let w = s * CGFloat(side < 0 ? 0.27 : 0.23) * CGFloat(leafSize)
            let h = s * CGFloat(side < 0 ? 0.15 : 0.13) * CGFloat(leafSize)
            leafContext.fill(leafPath(base: base, side: CGFloat(side), width: w, height: h), with: .color(side < 0 ? leaf : leaf.opacity(0.9)))
        }
        if pose.growth >= 0.8 {
            let center = CGPoint(x: stemTop.x, y: stemTop.y - s * 0.05)
            sprout.fill(circle(center, s * 0.06), with: .color(cheek))
            sprout.fill(circle(center, s * 0.025), with: .color(yellow))
        }

        // 몸통과 하이라이트
        let bean = CGRect(x: cx - s / 2, y: cy - s * 0.41, width: s, height: s * 0.82)
        body.fill(Path(ellipseIn: bean), with: .linearGradient(Gradient(colors: [bodyTop, bodyBottom]),
                                                               startPoint: CGPoint(x: cx, y: bean.minY), endPoint: CGPoint(x: cx, y: bean.maxY)))
        var shine = body
        rotate(&shine, degrees: -25, around: CGPoint(x: cx - s * 0.23, y: cy - s * 0.22))
        shine.fill(Path(ellipseIn: CGRect(x: cx - s * 0.34, y: cy - s * 0.28, width: s * 0.22, height: s * 0.12)), with: .color(.white.opacity(0.55)))

        // 얼굴
        let lookX = CGFloat(pose.lookX) * s
        let eyeY = cy - s * 0.02 + CGFloat(pose.lookY) * s
        for side in [-1.0, 1.0] {
            let ex = cx + CGFloat(side) * s * 0.17 + lookX
            drawEye(&body, pose.eye, at: CGPoint(x: ex, y: eyeY), side: side, s: s)
            body.fill(Path(ellipseIn: CGRect(x: cx + CGFloat(side) * s * 0.305 - s * 0.075, y: cy + s * 0.075, width: s * 0.15, height: s * 0.09)),
                      with: .color(cheek.opacity(0.75)))
        }
        drawMouth(&body, pose.mouth, at: CGPoint(x: cx + lookX, y: cy + s * 0.13 + CGFloat(pose.lookY) * s * 0.5), s: s)

        // 장식
        if pose.sparkles > 0 { drawSparkles(&canvas, cx: cx, cy: cy, s: s, t: t, alpha: pose.sparkles) }
        if pose.bubble > 0 { drawBubble(&canvas, cx: cx, cy: cy, s: s, t: t, alpha: pose.bubble) }
        if pose.snore > 0 { drawSnore(&canvas, cx: cx, cy: cy, s: s, t: t, alpha: pose.snore) }
        if pose.steam > 0 { drawSteam(&canvas, cx: cx, cy: cy, s: s, t: t, alpha: pose.steam) }
        if pose.plus > 0 { drawPlus(&canvas, cx: cx, cy: cy, s: s, t: t, alpha: pose.plus) }
        if pose.thought > 0 { drawThought(&canvas, cx: cx, cy: cy, s: s, t: t, alpha: pose.thought) }
        if pose.sweat > 0 { drawSweat(&canvas, cx: cx, cy: cy, s: s, t: t, alpha: pose.sweat) }
        if pose.tapAge < 1.1 { drawHeart(&canvas, cx: cx, cy: cy, s: s, age: pose.tapAge) }
    }

    // MARK: 얼굴

    private static func drawEye(_ c: inout GraphicsContext, _ eye: KongiPose.Eye, at p: CGPoint, side: Double, s: CGFloat) {
        switch eye {
        case let .open(height):
            c.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.05, y: p.y - s * CGFloat(height) / 2, width: s * 0.1, height: s * CGFloat(height))), with: .color(ink))
        case .closed:
            var line = Path()
            line.move(to: CGPoint(x: p.x - s * 0.055, y: p.y))
            line.addLine(to: CGPoint(x: p.x + s * 0.055, y: p.y))
            c.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: s * 0.035, lineCap: .round))
        case .happy:
            var arc = Path()
            arc.move(to: CGPoint(x: p.x - s * 0.07, y: p.y + s * 0.03))
            arc.addQuadCurve(to: CGPoint(x: p.x + s * 0.07, y: p.y + s * 0.03), control: CGPoint(x: p.x, y: p.y - s * 0.07))
            c.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
        case .sad:
            c.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.045, y: p.y - s * 0.04, width: s * 0.09, height: s * 0.09)), with: .color(ink))
            // 안쪽 끝이 올라간 눈썹
            var brow = Path()
            brow.move(to: CGPoint(x: p.x + CGFloat(side) * s * 0.07, y: p.y - s * 0.08))
            brow.addLine(to: CGPoint(x: p.x - CGFloat(side) * s * 0.04, y: p.y - s * 0.12))
            c.stroke(brow, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: s * 0.03, lineCap: .round))
        case .wide:
            c.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.06, y: p.y - s * 0.075, width: s * 0.12, height: s * 0.15)), with: .color(ink))
            c.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.01, y: p.y - s * 0.05, width: s * 0.04, height: s * 0.04)), with: .color(.white.opacity(0.9)))
        }
    }

    private static func drawMouth(_ c: inout GraphicsContext, _ mouth: KongiPose.Mouth, at p: CGPoint, s: CGFloat) {
        switch mouth {
        case .dash:
            var line = Path()
            line.move(to: CGPoint(x: p.x - s * 0.02, y: p.y))
            line.addLine(to: CGPoint(x: p.x + s * 0.02, y: p.y))
            c.stroke(line, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: s * 0.025, lineCap: .round))
        case .small:
            c.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.03, y: p.y - s * 0.035, width: s * 0.06, height: s * 0.07)), with: .color(ink))
        case .smile, .frown:
            let up: CGFloat = { if case .smile = mouth { return 1 } else { return -1 } }()
            var curve = Path()
            curve.move(to: CGPoint(x: p.x - s * 0.06, y: p.y - up * s * 0.02))
            curve.addQuadCurve(to: CGPoint(x: p.x + s * 0.06, y: p.y - up * s * 0.02), control: CGPoint(x: p.x, y: p.y + up * s * 0.06))
            c.stroke(curve, with: .color(ink), style: StrokeStyle(lineWidth: s * 0.04, lineCap: .round))
        case let .yawn(amount):
            let h = s * CGFloat(0.04 + 0.08 * amount)
            c.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.04, y: p.y - h / 2, width: s * 0.08, height: h)), with: .color(ink))
        }
    }

    // MARK: 장식

    private static func drawSparkles(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, t: Double, alpha: Double) {
        for index in 0..<3 {
            let angle = t * 2 + Double(index) * 2.1
            let center = CGPoint(x: cx + CGFloat(cos(angle)) * s * 0.68, y: cy + CGFloat(sin(angle)) * s * 0.42 - s * 0.1)
            let r = s * 0.11 * CGFloat(0.7 + 0.3 * sin(t * 6 + Double(index)))
            c.fill(star(center, r), with: .color(yellow.opacity(alpha * (0.5 + 0.5 * sin(t * 6 + Double(index))))))
        }
    }

    private static func drawBubble(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, t: Double, alpha: Double) {
        let center = CGPoint(x: cx + s * 0.52, y: cy - s * 0.5)
        let r = s * 0.21 * CGFloat(1 + sin(t * 8) * 0.08)
        c.fill(circle(center, r), with: .color(yellow.opacity(alpha)))
        var bar = Path()
        bar.move(to: CGPoint(x: center.x, y: center.y - r * 0.5))
        bar.addLine(to: CGPoint(x: center.x, y: center.y + r * 0.12))
        c.stroke(bar, with: .color(.black.opacity(alpha)), style: StrokeStyle(lineWidth: s * 0.06, lineCap: .round))
        c.fill(circle(CGPoint(x: center.x, y: center.y + r * 0.48), s * 0.03), with: .color(.black.opacity(alpha)))
    }

    private static func drawSnore(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, t: Double, alpha: Double) {
        for index in 0..<2 {
            let phase = (t / 2.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            let size = s * CGFloat(0.12 + 0.08 * phase)
            let origin = CGPoint(x: cx + s * (0.42 + CGFloat(phase) * 0.18), y: cy - s * (0.32 + CGFloat(phase) * 0.36))
            var z = Path()
            z.move(to: origin)
            z.addLine(to: CGPoint(x: origin.x + size, y: origin.y))
            z.addLine(to: CGPoint(x: origin.x, y: origin.y + size))
            z.addLine(to: CGPoint(x: origin.x + size, y: origin.y + size))
            c.stroke(z, with: .color(.white.opacity(alpha * 0.8 * (1 - phase))), style: StrokeStyle(lineWidth: s * 0.035, lineCap: .round, lineJoin: .round))
        }
    }

    /// 뛰는 동안 머리 위로 김이 피어오릅니다.
    private static func drawSteam(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, t: Double, alpha: Double) {
        for index in 0..<3 {
            let phase = (t / 1.2 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let center = CGPoint(x: cx - s * 0.45 - CGFloat(phase) * s * 0.15 + CGFloat(sin(phase * 9)) * s * 0.03,
                                 y: cy - s * 0.1 - CGFloat(phase) * s * 0.4)
            c.fill(circle(center, s * CGFloat(0.05 + phase * 0.06)), with: .color(.white.opacity(alpha * 0.5 * (1 - phase))))
        }
    }

    /// 고치는 동안 초록 +가 하나씩 떠오릅니다 (늘어난 줄).
    private static func drawPlus(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, t: Double, alpha: Double) {
        for index in 0..<2 {
            let phase = (t / 1.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            let center = CGPoint(x: cx + s * (0.5 + CGFloat(index) * 0.08), y: cy + s * 0.1 - CGFloat(phase) * s * 0.55)
            let arm = s * 0.06
            var plus = Path()
            plus.move(to: CGPoint(x: center.x - arm, y: center.y))
            plus.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            plus.move(to: CGPoint(x: center.x, y: center.y - arm))
            plus.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            let fade = phase < 0.2 ? phase / 0.2 : 1 - (phase - 0.2) / 0.8
            c.stroke(plus, with: .color(KongiTheme.green.opacity(alpha * fade)), style: StrokeStyle(lineWidth: s * 0.035, lineCap: .round))
        }
    }

    /// 생각 방울 세 개가 차례로 커집니다.
    private static func drawThought(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, t: Double, alpha: Double) {
        let cycle = (t / 1.8).truncatingRemainder(dividingBy: 1)
        for index in 0..<3 {
            let appear = min(1, max(0, (cycle - Double(index) * 0.2) / 0.15))
            let center = CGPoint(x: cx + s * (0.4 + CGFloat(index) * 0.13), y: cy - s * (0.32 + CGFloat(index) * 0.15))
            c.fill(circle(center, s * CGFloat(0.03 + Double(index) * 0.025) * CGFloat(appear)), with: .color(.white.opacity(alpha * 0.85)))
        }
    }

    /// 식은땀 한 방울이 옆으로 흘러내립니다.
    private static func drawSweat(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, t: Double, alpha: Double) {
        let phase = (t / 2).truncatingRemainder(dividingBy: 1)
        let x = cx + s * 0.4
        let y = cy - s * 0.2 + CGFloat(phase) * s * 0.25
        var drop = Path()
        drop.move(to: CGPoint(x: x, y: y - s * 0.07))
        drop.addQuadCurve(to: CGPoint(x: x, y: y + s * 0.04), control: CGPoint(x: x + s * 0.07, y: y + s * 0.03))
        drop.addQuadCurve(to: CGPoint(x: x, y: y - s * 0.07), control: CGPoint(x: x - s * 0.07, y: y + s * 0.03))
        c.fill(drop, with: .color(Color(red: 0.55, green: 0.78, blue: 1).opacity(alpha * (1 - phase * 0.6))))
    }

    /// 누르면 하트가 떠오릅니다.
    private static func drawHeart(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat, age: Double) {
        let rise = CGFloat(age / 1.1)
        let center = CGPoint(x: cx + s * 0.38, y: cy - s * 0.35 - rise * s * 0.35)
        let r = s * 0.1 * (0.6 + min(1, CGFloat(age) * 4) * 0.4)
        var heart = Path()
        heart.move(to: CGPoint(x: center.x, y: center.y + r))
        heart.addCurve(to: CGPoint(x: center.x - r, y: center.y - r * 0.2), control1: CGPoint(x: center.x - r * 0.3, y: center.y + r * 0.7), control2: CGPoint(x: center.x - r, y: center.y + r * 0.3))
        heart.addArc(center: CGPoint(x: center.x - r * 0.5, y: center.y - r * 0.2), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        heart.addArc(center: CGPoint(x: center.x + r * 0.5, y: center.y - r * 0.2), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        heart.addCurve(to: CGPoint(x: center.x, y: center.y + r), control1: CGPoint(x: center.x + r, y: center.y + r * 0.3), control2: CGPoint(x: center.x + r * 0.3, y: center.y + r * 0.7))
        c.fill(heart, with: .color(cheek.opacity(1 - Double(rise) * 0.9)))
    }

    // MARK: 도형

    private static func circle(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    /// 네 갈래 반짝이
    private static func star(_ c: CGPoint, _ r: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        return path
    }

    /// 끝이 뾰족한 잎. side가 -1이면 왼쪽 위, 1이면 오른쪽 위로 뻗습니다.
    private static func leafPath(base: CGPoint, side: CGFloat, width: CGFloat, height: CGFloat) -> Path {
        let tip = CGPoint(x: base.x + side * width, y: base.y - height)
        var path = Path()
        path.move(to: base)
        path.addQuadCurve(to: tip, control: CGPoint(x: base.x + side * width * 0.1, y: tip.y))
        path.addQuadCurve(to: base, control: CGPoint(x: tip.x, y: base.y))
        return path
    }

    private static func rotate(_ c: inout GraphicsContext, degrees: Double, around p: CGPoint) {
        guard degrees != 0 else { return }
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .degrees(degrees))
        c.translateBy(x: -p.x, y: -p.y)
    }

    private static func scale(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, around p: CGPoint) {
        c.translateBy(x: p.x, y: p.y)
        c.scaleBy(x: x, y: y)
        c.translateBy(x: -p.x, y: -p.y)
    }
}

private struct KongiGrowthKey: EnvironmentKey {
    static let defaultValue: Double = 0.3
}

extension EnvironmentValues {
    /// 콩이가 얼마나 자랐는지 (0…1)
    var kongiGrowth: Double {
        get { self[KongiGrowthKey.self] }
        set { self[KongiGrowthKey.self] = newValue }
    }
}
