import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite struct SchedulePlannerTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func snapshot(sessionReset: Date?, weeklyReset: Date? = nil) -> UsageSnapshot {
        var limits = [LimitItem(kind: .session, percent: 100, resetsAt: sessionReset)]
        if let weeklyReset { limits.append(LimitItem(kind: .weekly, percent: 70, resetsAt: weeklyReset)) }
        return UsageSnapshot(limits: limits, fetchedAt: now)
    }

    func prompt(_ trigger: ScheduledPrompt.Trigger, repeats: Bool = false, lastRun: Date? = nil) -> ScheduledPrompt {
        ScheduledPrompt(projectPath: "/p", prompt: "continue", trigger: trigger, repeats: repeats, createdAt: now.addingTimeInterval(-3600), lastRunAt: lastRun)
    }

    @Test func keepsTheResetTimeAfterTheUsageWindowMoves() {
        // 한도에 닿았을 때 예약: 초기화 시각을 잡아 둡니다.
        let reset = now.addingTimeInterval(1800)
        let armed = SchedulePlanner.armed(prompt(.sessionReset), snapshot: snapshot(sessionReset: reset))
        #expect(armed.resetAt == reset)
        // 초기화가 지나 사용량 정보가 비거나(0%) 다음 창으로 바뀌어도 그대로 실행됩니다.
        let after = reset.addingTimeInterval(90)
        #expect(SchedulePlanner.armed(armed, snapshot: snapshot(sessionReset: nil)).resetAt == reset)
        #expect(SchedulePlanner.decision(for: armed, snapshot: snapshot(sessionReset: nil), now: after) == .run)
        #expect(SchedulePlanner.decision(for: armed, snapshot: snapshot(sessionReset: after.addingTimeInterval(5 * 3600)), now: after) == .run)
    }

    @Test func rearmsRepeatingResetOnlyForALaterWindow() {
        let reset = now.addingTimeInterval(-600)
        var ran = SchedulePlanner.armed(prompt(.sessionReset, repeats: true), snapshot: snapshot(sessionReset: reset))
        ran.lastRunAt = reset.addingTimeInterval(60)
        // 아직 예전 창 시각이면 다시 잡지 않습니다.
        #expect(SchedulePlanner.armed(ran, snapshot: snapshot(sessionReset: reset)).resetAt == reset)
        #expect(SchedulePlanner.nextRun(for: ran, snapshot: snapshot(sessionReset: reset), now: now) == nil)
        let next = reset.addingTimeInterval(5 * 3600)
        #expect(SchedulePlanner.armed(ran, snapshot: snapshot(sessionReset: next)).resetAt == next)
    }

    @Test func ignoresAResetThatPassedBeforeScheduling() {
        let stale = now.addingTimeInterval(-7200)
        var fresh = prompt(.sessionReset)
        fresh.createdAt = now
        #expect(SchedulePlanner.armed(fresh, snapshot: snapshot(sessionReset: stale)).resetAt == nil)
        #expect(SchedulePlanner.decision(for: fresh, snapshot: snapshot(sessionReset: stale), now: now) == .wait)
    }

    @Test func runsOneMinuteAfterSessionReset() {
        let reset = now.addingTimeInterval(1800)
        let next = SchedulePlanner.nextRun(for: prompt(.sessionReset), snapshot: snapshot(sessionReset: reset), now: now)
        #expect(next == reset.addingTimeInterval(60))
        #expect(SchedulePlanner.decision(for: prompt(.sessionReset), snapshot: snapshot(sessionReset: reset), now: now) == .wait)
        #expect(SchedulePlanner.decision(for: prompt(.sessionReset), snapshot: snapshot(sessionReset: reset), now: reset.addingTimeInterval(61)) == .run)
    }

    @Test func doesNotRunTwiceForSameReset() {
        let reset = now.addingTimeInterval(-30)
        let ran = prompt(.sessionReset, repeats: true, lastRun: reset.addingTimeInterval(60))
        #expect(SchedulePlanner.nextRun(for: ran, snapshot: snapshot(sessionReset: reset), now: now) == nil)
        // 다음 창의 초기화 시각이 들어오면 다시 잡힙니다.
        let nextReset = reset.addingTimeInterval(5 * 3600)
        #expect(SchedulePlanner.nextRun(for: ran, snapshot: snapshot(sessionReset: nextReset), now: now) == nextReset.addingTimeInterval(60))
    }

    @Test func weeklyAndUnknownReset() {
        let weekly = now.addingTimeInterval(86400)
        #expect(SchedulePlanner.nextRun(for: prompt(.weeklyReset), snapshot: snapshot(sessionReset: nil, weeklyReset: weekly), now: now) == weekly.addingTimeInterval(60))
        #expect(SchedulePlanner.nextRun(for: prompt(.sessionReset), snapshot: snapshot(sessionReset: nil), now: now) == nil)
        #expect(SchedulePlanner.nextRun(for: prompt(.sessionReset), snapshot: nil, now: now) == nil)
    }

    @Test func fixedTimeOnceAndDaily() {
        let at = now.addingTimeInterval(-3600)
        #expect(SchedulePlanner.decision(for: prompt(.at(at)), snapshot: nil, now: now) == .run)
        #expect(SchedulePlanner.decision(for: prompt(.at(now.addingTimeInterval(-7 * 3600))), snapshot: nil, now: now) == .missed)

        let daily = prompt(.at(at), repeats: true, lastRun: at)
        #expect(SchedulePlanner.nextRun(for: daily, snapshot: nil, now: now) == Calendar.current.date(byAdding: .day, value: 1, to: at))
    }

    @Test func finishedOrDisabledNeverRuns() {
        var done = prompt(.at(now))
        done.finished = true
        #expect(SchedulePlanner.nextRun(for: done, snapshot: nil, now: now) == nil)
        var off = prompt(.at(now))
        off.enabled = false
        #expect(SchedulePlanner.decision(for: off, snapshot: nil, now: now.addingTimeInterval(10)) == .wait)
    }

    @Test func argumentsAndCoding() throws {
        var p = prompt(.weeklyReset)
        p.continueConversation = true
        p.permission = .standard
        #expect(p.arguments == ["-p", "continue", "--permission-mode", "default", "--continue"])
        let data = try JSONEncoder().encode([p])
        #expect(try JSONDecoder().decode([ScheduledPrompt].self, from: data) == [p])
    }

    @Test func resumesSpecificSession() {
        var p = prompt(.sessionReset)
        p.sessionId = "abc-123"
        p.continueConversation = true
        #expect(p.arguments == ["-p", "continue", "--permission-mode", "acceptEdits", "--resume", "abc-123"])
    }

    @Test func passesModelAndEffort() throws {
        var p = prompt(.sessionReset)
        p.model = "opus"
        p.effort = "high"
        #expect(p.arguments == ["-p", "continue", "--permission-mode", "acceptEdits", "--model", "opus", "--effort", "high"])
        p.effort = "turbo"  // 모르는 값은 넘기지 않음
        #expect(!p.arguments.contains("--effort"))
        // 예전에 저장된 예약(필드 없음)도 그대로 읽힘
        let old = try JSONEncoder().encode(prompt(.sessionReset))
        #expect(try JSONDecoder().decode(ScheduledPrompt.self, from: old).model == nil)
    }
}
