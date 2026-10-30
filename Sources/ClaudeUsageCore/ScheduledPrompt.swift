import Foundation

/// 정해진 때(한도 초기화 직후나 지정한 시각)에 특정 프로젝트에서 Claude Code로 보낼 프롬프트
public struct ScheduledPrompt: Codable, Identifiable, Equatable, Sendable {
    public enum Trigger: Codable, Equatable, Sendable {
        /// 5시간 세션 한도가 초기화된 직후
        case sessionReset
        /// 주간 한도가 초기화된 직후
        case weeklyReset
        /// 지정한 시각 (반복이면 매일 같은 시각)
        case at(Date)
    }

    /// 예약 실행에는 승인할 사람이 없으므로 미리 정합니다 (`claude --permission-mode`).
    public enum Permission: String, Codable, CaseIterable, Sendable {
        /// 승인이 필요한 작업은 하지 않음
        case standard = "default"
        /// 파일 편집은 허용
        case acceptEdits
        /// 모든 작업 허용 (주의)
        case bypassPermissions
    }

    public enum Outcome: Codable, Equatable, Sendable {
        case succeeded(summary: String)
        case failed(message: String)
        /// Mac이 잠들어 있는 등의 이유로 실행 시각을 너무 많이 놓쳤음
        case missed
    }

    public var id: UUID
    public var projectPath: String
    public var prompt: String
    public var trigger: Trigger
    public var repeats: Bool
    /// 이 폴더의 마지막 대화를 이어서 진행 (`claude --continue`)
    public var continueConversation: Bool
    public var permission: Permission
    public var enabled: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var lastOutcome: Outcome?
    /// 1회성 예약이 실행(또는 놓침)되어 끝났는지
    public var finished: Bool
    /// 지금 진행 중인 대화(Claude Code 세션)에 이어서 보낼 때의 세션 ID.
    /// 터미널이 열려 있으면 그 터미널에 직접 입력하고, 없으면 `claude --resume`으로 같은 대화를 이어 갑니다.
    public var sessionId: String?
    /// 그 세션이 실행 중인 터미널 정보 (예약 당시)
    public var sessionContext: HookContext?
    /// 기다리는 초기화 시각. 초기화가 지나면 사용량 정보가 다음 창 시각(또는 없음)으로 바뀌므로 미리 잡아 둡니다.
    public var resetAt: Date?

    public init(
        id: UUID = UUID(), projectPath: String, prompt: String, trigger: Trigger, repeats: Bool = false,
        continueConversation: Bool = false, permission: Permission = .acceptEdits, enabled: Bool = true,
        createdAt: Date = Date(), lastRunAt: Date? = nil, lastOutcome: Outcome? = nil, finished: Bool = false,
        sessionId: String? = nil, sessionContext: HookContext? = nil, resetAt: Date? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.prompt = prompt
        self.trigger = trigger
        self.repeats = repeats
        self.continueConversation = continueConversation
        self.permission = permission
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
        self.finished = finished
        self.sessionId = sessionId
        self.sessionContext = sessionContext
        self.resetAt = resetAt
    }

    public var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    /// `claude`에 넘길 인자
    public var arguments: [String] {
        var args = ["-p", prompt, "--permission-mode", permission.rawValue]
        if let sessionId {
            args += ["--resume", sessionId]
        } else if continueConversation {
            args.append("--continue")
        }
        return args
    }
}

public enum SchedulePlanner {
    /// 초기화 직후 바로 보내면 서버에 아직 반영 전일 수 있어 조금 기다립니다.
    public static let resetDelay: TimeInterval = 60
    /// 이 시간보다 늦었으면 (잠자기 등) 실행하지 않고 놓친 것으로 처리합니다.
    public static let grace: TimeInterval = 6 * 3600

    /// 다음 실행 시각. 실행할 수 없거나(초기화 시각을 모름) 끝난 예약이면 nil.
    public static func nextRun(for prompt: ScheduledPrompt, snapshot: UsageSnapshot?, now: Date) -> Date? {
        guard prompt.enabled, !prompt.finished else { return nil }
        switch prompt.trigger {
        case .sessionReset, .weeklyReset:
            return afterReset(armed(prompt, snapshot: snapshot).resetAt, prompt: prompt)
        case let .at(date):
            guard prompt.repeats else { return date }
            // 매일 같은 시각: 마지막 실행 이후의 첫 시각 (지난 날은 건너뜀)
            var next = date
            let after = max(prompt.lastRunAt ?? .distantPast, now.addingTimeInterval(-grace))
            while next <= after { next = Calendar.current.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86400) }
            return next
        }
    }

    /// 초기화 예약이 기다릴 시각을 정합니다. 이미 잡혀 있고 아직 실행 전이면 그대로 두고,
    /// 없거나 이미 실행했으면 사용량 정보의 다음 초기화 시각(마지막 실행·예약 이후인 것만)을 잡습니다.
    public static func armed(_ prompt: ScheduledPrompt, snapshot: UsageSnapshot?) -> ScheduledPrompt {
        let kind: LimitKind
        switch prompt.trigger {
        case .sessionReset: kind = .session
        case .weeklyReset: kind = .weekly
        case .at: return prompt
        }
        let handled = prompt.lastRunAt ?? prompt.createdAt.addingTimeInterval(-resetDelay)
        if let current = prompt.resetAt, current.addingTimeInterval(resetDelay) > handled { return prompt }
        guard let known = snapshot?.limit(kind)?.resetsAt, known > handled else { return prompt }
        var updated = prompt
        updated.resetAt = known
        return updated
    }

    private static func afterReset(_ resetsAt: Date?, prompt: ScheduledPrompt) -> Date? {
        guard let resetsAt else { return nil }
        let run = resetsAt.addingTimeInterval(resetDelay)
        // 이번 초기화에 대해 이미 실행했다면 다음 초기화 시각이 들어올 때까지 기다립니다.
        if let last = prompt.lastRunAt, last >= run.addingTimeInterval(-resetDelay) { return nil }
        return run
    }

    public enum Decision: Equatable {
        case wait
        case run
        case missed
    }

    public static func decision(for prompt: ScheduledPrompt, snapshot: UsageSnapshot?, now: Date) -> Decision {
        guard let next = nextRun(for: prompt, snapshot: snapshot, now: now), next <= now else { return .wait }
        return now.timeIntervalSince(next) <= grace ? .run : .missed
    }
}
