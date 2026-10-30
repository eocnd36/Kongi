import ClaudeUsageCore
import Darwin
import Foundation
import os

/// 예약 프롬프트를 저장하고, 때가 되면 해당 폴더에서 `claude -p`로 실행합니다.
@MainActor
final class PromptScheduler: ObservableObject {
    @Published private(set) var prompts: [ScheduledPrompt] = []
    @Published private(set) var running: Set<UUID> = []

    private let usage: UsageStore
    private var processes: [UUID: Process] = [:]
    private var tickTask: Task<Void, Never>?
    private static let storageKey = "scheduledPrompts"
    private let log = Logger(subsystem: "io.github.claudeusagebar", category: "schedule")

    init(usage: UsageStore) {
        self.usage = usage
        load()
    }

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 20 * NSEC_PER_SEC)
            }
        }
    }

    // MARK: Editing

    func save(_ prompt: ScheduledPrompt) {
        if let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[index] = prompt
        } else {
            prompts.append(prompt)
        }
        persist()
        tick()
    }

    func delete(_ id: UUID) {
        stop(id)
        prompts.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var prompt = prompts.first(where: { $0.id == id }) else { return }
        prompt.enabled = enabled
        if enabled, !prompt.repeats { prompt.finished = false }
        save(prompt)
    }

    /// 한도에 닿았을 때 한 번에 잡는 "초기화되면 이어서 하기": 지금 그 대화에 "계속해"를 보냅니다.
    @discardableResult
    func scheduleContinue(session: AgentSession, trigger: ScheduledPrompt.Trigger) -> ScheduledPrompt {
        if let existing = pendingContinue(sessionId: session.id) { return existing }
        let prompt = ScheduledPrompt(
            projectPath: session.cwd,
            prompt: String(localized: "Continue where you left off."),
            trigger: trigger,
            continueConversation: true,
            permission: .acceptEdits,
            sessionId: session.id,
            sessionContext: session.context
        )
        save(prompt)
        return prompt
    }

    func pendingContinue(sessionId: String) -> ScheduledPrompt? {
        prompts.first { $0.sessionId == sessionId && !$0.finished && $0.enabled }
    }

    func nextRun(_ prompt: ScheduledPrompt) -> Date? {
        SchedulePlanner.nextRun(for: prompt, snapshot: usage.snapshot, now: Date())
    }

    // MARK: Running

    func runNow(_ id: UUID) {
        guard let prompt = prompts.first(where: { $0.id == id }) else { return }
        run(prompt, manual: true)
    }

    func stop(_ id: UUID) {
        processes[id]?.terminate()
    }

    private func tick() {
        let now = Date()
        // 초기화 시각을 미리 잡아 둡니다. 초기화가 지나면 사용량 정보가 다음 창 시각으로 바뀌어 놓치기 쉽습니다.
        for prompt in prompts {
            let armed = SchedulePlanner.armed(prompt, snapshot: usage.snapshot)
            if armed != prompt { update(armed) }
        }
        for prompt in prompts where !running.contains(prompt.id) {
            switch SchedulePlanner.decision(for: prompt, snapshot: usage.snapshot, now: now) {
            case .wait:
                break
            case .run:
                run(prompt, manual: false)
            case .missed:
                var missed = prompt
                missed.lastRunAt = now
                missed.lastOutcome = .missed
                if !missed.repeats { missed.finished = true }
                update(missed)
            }
        }
    }

    private func run(_ prompt: ScheduledPrompt, manual: Bool) {
        guard !running.contains(prompt.id) else { return }
        var updated = prompt
        if !manual {
            updated.lastRunAt = Date()
            if !updated.repeats { updated.finished = true }
        }
        update(updated)

        // 진행 중인 대화에 이어서: 멈춘 대화를 직접 깨우고(VS Code 포함), 안 되면 그 터미널에 입력합니다.
        let agents = AppServices.shared.agents
        let target = prompt.sessionId ?? (prompt.continueConversation ? agents.resumableSession(in: prompt.projectPath)?.id : nil)
        if let target, agents.wake(target, with: Self.wakeMessage(prompt.prompt)) {
            log.notice("Woke the conversation with the scheduled prompt")
            finish(prompt.id, outcome: .succeeded(summary: String(localized: "Sent to the conversation.")))
            return
        }
        // 그 대화가 아직 열려 있으면(실행 중) 절대 뒤에서 따로 실행하지 않습니다 (같은 대화의 복사본이 생김).
        // 터미널이면 직접 입력하고, 아니면 대화가 멈출 때 전달되도록 맡겨 둡니다.
        let live = prompt.sessionId.flatMap { agents.session($0) }.flatMap { $0.isAlive ? $0 : nil }
            ?? (prompt.sessionId == nil && prompt.continueConversation ? agents.liveSession(in: prompt.projectPath) : nil)
        if let live {
            if TerminalJumper.send(prompt.prompt, to: live.context) {
                log.notice("Sent scheduled prompt to the terminal session")
                finish(prompt.id, outcome: .succeeded(summary: String(localized: "Sent to the conversation in the terminal.")))
            } else if agents.canQueue(for: live.id) {
                agents.enqueue(prompt.prompt, for: live.id)
                finish(prompt.id, outcome: .succeeded(summary: String(localized: "Claude is still working, so it's sent when the conversation pauses.")))
            } else {
                finish(prompt.id, outcome: .failed(message: String(localized: "Update the Claude Code connection in Kongi's settings so it can continue this conversation.")))
            }
            return
        }
        // 대화가 닫혀 있으면 아래에서 `claude --resume <세션>`(또는 이 폴더의 마지막 대화)로 이어 갑니다.

        guard let executable = ClaudeRunner.executable() else {
            finish(prompt.id, outcome: .failed(message: String(localized: "Couldn't find the claude command. Install Claude Code first.")))
            return
        }
        let logURL = ClaudeRunner.logURL(for: prompt.id)
        let process: Process
        do {
            process = try ClaudeRunner.start(
                executable: executable, arguments: prompt.arguments,
                directory: URL(fileURLWithPath: prompt.projectPath), log: logURL
            )
        } catch {
            finish(prompt.id, outcome: .failed(message: error.localizedDescription))
            return
        }

        running.insert(prompt.id)
        processes[prompt.id] = process
        log.notice("Started scheduled prompt in \(prompt.projectName, privacy: .public)")
        Notifier.post(
            title: String(localized: "Scheduled prompt started"),
            body: String(localized: "\(prompt.projectName): \(prompt.prompt)")
        )

        let id = prompt.id
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor [weak self] in
                let output = ClaudeRunner.tail(of: logURL)
                let outcome: ScheduledPrompt.Outcome = status == 0
                    ? .succeeded(summary: output)
                    : .failed(message: reason == .uncaughtSignal ? String(localized: "Stopped.") : (output.isEmpty ? "exit \(status)" : output))
                self?.finish(id, outcome: outcome)
            }
        }
    }

    /// 깨운 대화에서 모델이 보는 말. 사용자가 예약한 메시지임을 알려 줍니다.
    static func wakeMessage(_ prompt: String) -> String {
        "Message from the user, scheduled with Kongi to send after the usage limit reset:\n\n" + prompt
    }

    private func finish(_ id: UUID, outcome: ScheduledPrompt.Outcome) {
        running.remove(id)
        processes[id] = nil
        guard var prompt = prompts.first(where: { $0.id == id }) else { return }
        prompt.lastOutcome = outcome
        update(prompt)
        switch outcome {
        case let .succeeded(summary):
            Notifier.post(title: String(localized: "\(prompt.projectName): scheduled prompt finished"), body: summary)
        case let .failed(message):
            Notifier.post(title: String(localized: "\(prompt.projectName): scheduled prompt failed"), body: message)
        case .missed:
            break
        }
    }

    func logURL(for id: UUID) -> URL? {
        let url = ClaudeRunner.logURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Storage

    private func update(_ prompt: ScheduledPrompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[index] = prompt
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ScheduledPrompt].self, from: data) else { return }
        prompts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(prompts) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// `claude` CLI 실행
enum ClaudeRunner {
    private static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    }

    static func executable() -> URL? {
        for directory in searchPaths {
            let path = "\(directory)/claude"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // 그 밖의 위치: 사용자의 셸 설정으로 찾아봅니다.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func logURL(for id: UUID) -> URL {
        HookPaths.supportDirectory.appendingPathComponent("runs/\(id.uuidString).log")
    }

    static func start(executable: URL, arguments: [String], directory: URL, log: URL) throws -> Process {
        let fm = FileManager.default
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    /// 결과 알림용: 출력 마지막 부분
    static func tail(of url: URL, limit: Int = 280) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? "…" + String(trimmed.suffix(limit)) : trimmed
    }
}
