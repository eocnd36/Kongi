import ClaudeUsageCore
import Darwin
import Foundation

// MARK: - Models

enum AgentState: Codable, Equatable {
    case starting
    case thinking
    case running(ToolActivity)
    /// 아일랜드에서 승인을 기다리는 중
    case waitingForApproval
    /// 터미널에 권한 질문이 떠 있음 (아일랜드가 처리하지 않은 경우)
    case waitingInTerminal
    case waitingForAnswer
    case waitingForInput
    case done
    case ended

    var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingInTerminal, .waitingForAnswer: return true
        default: return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .thinking, .running, .starting: return true
        default: return false
        }
    }
}

struct AgentActivity: Codable, Identifiable, Equatable {
    enum Status: String, Codable, Equatable { case running, succeeded, failed }

    var id: String
    var date: Date
    var activity: ToolActivity
    var detail: String
    var status: Status
    /// 이번 단계에서 고친 내용 (고치기 직전에 미리 계산해 바로 보여 줌)
    var preview: LineDiff?
    /// 명령이 출력한 마지막 몇 줄
    var output: String?
    /// 지금 읽고 있는 부분 (가장 최근 단계에만 남김)
    var excerpt: CodeExcerpt?
}

/// 파일의 일부 (Claude가 읽는 곳을 보여 줄 때)
struct CodeExcerpt: Codable, Equatable {
    var path: String
    /// 첫 줄 번호 (1부터)
    var startLine: Int
    var lines: [String]
}

/// 대화의 말 한 마디: 사용자가 보낸 것(터미널, 아일랜드, 휴대폰)과 Claude가 쓴 글
struct AgentMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id: String
    var date: Date
    var role: Role
    var text: String
    /// 대화가 바쁠 때 아일랜드에서 보낸 말: 다음에 멈추면 전달됩니다.
    var queued: Bool? = nil
}

struct FileChange: Codable, Identifiable, Equatable {
    var path: String
    var original: String?
    var existedBefore: Bool
    var current: String?
    var diff: LineDiff

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct AgentSession: Codable, Identifiable, Equatable {
    let id: String
    var cwd: String
    var context: HookContext
    var state: AgentState
    var startedAt: Date
    var updatedAt: Date
    var activities: [AgentActivity] = []
    var changes: [FileChange] = []
    var lastPrompt: String?
    /// 대화를 시작한 폴더 (VS Code 작업 영역). cwd는 대화 중 `cd`로 바뀔 수 있습니다.
    var launchDirectory: String?
    /// 사용자와 Claude가 주고받은 말 (최근 것만). 예전 기록 파일에는 없어서 선택 항목으로 저장합니다.
    var messageLog: [AgentMessage]?
    var messages: [AgentMessage] {
        get { messageLog ?? [] }
        set { messageLog = newValue }
    }
    var transcriptPath: String?
    /// 대화 기록을 어디까지 읽었는지
    var transcriptOffset: UInt64?
    /// 대화 기록 읽기 방식 버전 (바뀌면 처음부터 다시 읽음)
    var readerVersion: Int?
    /// 작업 중인 git 브랜치 (대화 기록에서)
    var gitBranch: String?
    /// 이번 요청을 시작한 시각 (완료 요약에 씀)
    var turnStartedAt: Date?
    /// 사용 한도 때문에 멈춘 시각 (이 대화에만 "초기화되면 이어서 하기"를 권합니다). 다시 입력하면 지워집니다.
    var limitStoppedAt: Date?
    /// Claude Code가 아닌 에이전트 (예: "codex"). 훅 도우미의 `--agent`로 붙습니다.
    var agent: String?

    var agentName: String { agent.map { $0 == "codex" ? "Codex" : $0.capitalized } ?? "Claude" }
    /// 화면에 보일 이름 (다른 에이전트면 이름을 붙임)
    var title: String { agent == nil ? projectName : "\(projectName) · \(agentName)" }

    var isAlive: Bool {
        state != .ended && (context.claudePid.map { $0 > 0 && kill($0, 0) == 0 } ?? false)
    }

    static let maxMessages = 150
    static let readerVersion = 2

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    var added: Int { changes.reduce(0) { $0 + $1.diff.added } }
    var removed: Int { changes.reduce(0) { $0 + $1.diff.removed } }

    static let maxActivities = 200
}

struct PermissionInfo: Equatable {
    var toolName: String
    var activity: ToolActivity
    /// 명령어 전체, 파일 경로 등 판단에 필요한 내용
    var detail: String
    var suggestions: [JSONValue]
}

struct AgentRequest: Identifiable {
    enum Kind {
        case permission(PermissionInfo)
        case question([AgentQuestion], toolInput: JSONValue)
    }

    let id = UUID()
    let sessionId: String
    let createdAt: Date
    let kind: Kind
    let connection: HookConnection?
}

// MARK: - Store

/// Claude Code 세션들의 실시간 상태. 훅 도우미가 보낸 이벤트로만 갱신됩니다 (모두 이 Mac 안에서 처리).
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var requests: [AgentRequest] = []
    /// 작업이 끝날 때마다 늘어납니다 (캐릭터가 기뻐하는 애니메이션 신호)
    @Published private(set) var lastCompletion: Date?
    @Published private(set) var serverRunning = false
    /// 멈춘 채 Kongi의 "이어서 하기"를 기다리는 대화들 (`--wait` 도우미가 연결돼 있음)
    @Published private(set) var resumable: Set<String> = []

    private var waiters: [String: HookConnection] = [:]
    /// 대화가 바쁠 때 아일랜드·휴대폰에서 보낸 말. 대화가 멈추면(기다리는 도우미가 연결되면) 전달합니다.
    @Published private(set) var queued: [String: [String]] = [:]
    /// 대화마다 쓰다 만 말 (섬을 접었다 펴도, 파일을 끌어 놓아도 남음)
    @Published var drafts: [String: String] = [:]

    /// 끌어 놓은 파일 경로를 입력 칸에 붙입니다.
    func appendDraft(_ text: String, to sessionId: String) {
        let current = drafts[sessionId] ?? ""
        let quoted = text.contains(" ") ? "\"\(text)\"" : text
        drafts[sessionId] = current.isEmpty ? quoted + " " : current + (current.hasSuffix(" ") ? "" : " ") + quoted + " "
    }
    private var transcriptReads: Set<String> = []
    /// 기다리는 도우미가 한 번이라도 연결된 대화 (이 대화에는 훅이 있다는 뜻)
    private var waiterSeen: Set<String> = []

    /// 이 대화가 멈출 때 말을 전달할 수 있는지 (연결이 최신이거나, 이 대화에서 도우미를 본 적이 있음)
    func canQueue(for sessionId: String) -> Bool {
        HookInstaller.canContinue || waiterSeen.contains(sessionId)
    }

    private let server = HookServer()
    private var pruneTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var fallbackTasks: [UUID: Task<Void, Never>] = [:]

    init() {}

    func start() {
        guard !serverRunning else { return }
        loadHistory()
        // 지난 대화의 말도 채워 둡니다 (뒤에서 읽음).
        for session in sessions where session.transcriptOffset == nil { readTranscript(of: session.id) }
        server.onEnvelope = { [weak self] envelope, connection in
            self?.handle(envelope, connection: connection)
        }
        serverRunning = server.start()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pruneDeadSessions()
                try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
            }
        }
        // 일하는 동안에는 Claude가 쓰는 글을 자주 읽어 실시간으로 보여 줍니다.
        transcriptTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                for session in self.sessions where session.state.isBusy || session.state.needsAttention {
                    self.readTranscript(of: session.id)
                }
            }
        }
    }

    // MARK: History (앱을 껐다 켜도 남는 세션 기록)

    private var saveTask: Task<Void, Never>?

    static var historyURL: URL {
        HookPaths.supportDirectory.appendingPathComponent("history/sessions.json")
    }

    /// 지난 세션 (끝났거나 Claude가 종료됨)
    var pastSessions: [AgentSession] { sessions.filter { $0.state == .ended } }

    private func loadHistory() {
        guard AppSettings.historyRetentionDays > 0,
              let data = try? Data(contentsOf: Self.historyURL),
              let saved = try? JSONDecoder().decode([AgentSession].self, from: data) else { return }
        // 앱이 꺼져 있던 사이 상태를 모르므로, 아직 살아 있는 Claude만 진행 중으로 두고 나머지는 끝난 것으로 봅니다.
        sessions = saved.map { session in
            var session = session
            // 읽는 방식이 바뀌었으면 처음부터(끝부분) 다시 읽어 사용자 말까지 채웁니다.
            if session.readerVersion != AgentSession.readerVersion {
                session.transcriptOffset = nil
                session.messages.removeAll { $0.queued != true }
            }
            // 앱이 꺼져 있던 사이 끝났을 수 있으니, 일하는 중이던 대화는 기록 끝을 다시 읽어 확인합니다.
            if session.state.isBusy { session.transcriptOffset = nil }
            let alive = session.context.claudePid.map { $0 > 0 && kill($0, 0) == 0 } ?? false
            if !alive { session.state = .ended }
            for index in session.activities.indices where session.activities[index].status == .running && !alive {
                session.activities[index].status = .succeeded
            }
            return session
        }
        applyRetention()
    }

    /// 변경이 생기면 잠시 모았다가 저장합니다. 일하는 동안 이벤트가 계속 와도 2초마다는 저장되게,
    /// 이미 잡힌 저장을 미루지 않습니다.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.saveHistory()
        }
    }

    func saveHistory() {
        let url = Self.historyURL
        guard AppSettings.historyRetentionDays > 0 else {
            Self.writeQueue.async { try? FileManager.default.removeItem(at: url) }
            return
        }
        // 바뀐 파일 내용까지 담겨 커질 수 있어, 변환과 쓰기는 뒤에서 합니다 (일하는 동안 화면이 끊기지 않게).
        let snapshot = sessions
        Self.writeQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
            // 파일 내용이 들어 있으므로 나만 읽을 수 있게 합니다.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// 저장은 순서대로 하나씩 (늦게 시작한 저장이 먼저 끝나 예전 내용으로 덮지 않게)
    private static let writeQueue = DispatchQueue(label: "io.github.claudeusagebar.history", qos: .utility)

    /// 앱을 끝낼 때: 마지막 저장이 끝날 때까지 기다립니다.
    func flushHistory() {
        saveHistory()
        Self.writeQueue.sync {}
    }

    /// 보관 기간이 지난 기록을 지웁니다. 진행 중인 세션은 남깁니다.
    func applyRetention() {
        let days = AppSettings.historyRetentionDays
        let cutoff = Date().addingTimeInterval(-Double(max(days, 0)) * 86400)
        let before = sessions.count
        sessions.removeAll { $0.state == .ended && (days == 0 || $0.updatedAt < cutoff) }
        if sessions.count != before { scheduleSave() }
    }

    func deleteSession(_ id: String) {
        sessions.removeAll { $0.id == id && $0.state == .ended }
        scheduleSave()
    }

    func clearHistory() {
        sessions.removeAll { $0.state == .ended }
        saveHistory()
    }

    #if DEBUG
    init(preview sessions: [AgentSession], requests: [AgentRequest] = [], completedRecently: Bool = false) {
        self.sessions = sessions
        self.requests = requests
        lastCompletion = completedRecently ? Date() : nil
    }

    /// 데모 영상: 장면마다 가짜 세션과 요청으로 바꿉니다.
    func setPreview(sessions: [AgentSession], requests: [AgentRequest] = [], completed: Bool = false) {
        self.sessions = sessions
        self.requests = requests
        if completed { lastCompletion = Date() }
    }
    #endif

    // MARK: Derived state

    var activeSessions: [AgentSession] { sessions.filter { $0.state != .ended } }

    func session(_ id: String) -> AgentSession? { sessions.first { $0.id == id } }

    func requests(for sessionId: String) -> [AgentRequest] { requests.filter { $0.sessionId == sessionId } }

    // MARK: Event handling

    func handle(_ envelope: HookEnvelope, connection: HookConnection?) {
        let event = HookEvent(json: envelope.event)
        var connection = connection
        if event.name == "ShellCommand" {
            ShellIntegration.handle(envelope.event)
            connection?.reply(nil)
            return
        }
        if event.name.hasPrefix("Kongi") {
            // kongi 명령 (notify, task, widget, status). status만 답을 돌려줍니다.
            // connection?.reply(handle(…))로 쓰면 답이 필요 없는 이벤트(연결 nil)는 handle이 아예 불리지 않습니다.
            let reply = AppServices.shared.tasks.handle(envelope.event)
            connection?.reply(reply)
            return
        }
        if envelope.waitsForContinue == true {
            if let connection { addWaiter(connection, for: event.sessionId) }
            // 오류(한도 등)로 멈춘 것은 기다리는 도우미로만 알려지므로 여기서 함께 처리합니다.
            guard event.name == "StopFailure" else { return }
            connection = nil
        }
        let now = Date()
        var session = upsertSession(for: event, context: envelope.context, now: now)

        switch event.name {
        case "SessionStart":
            session.state = .waitingForInput
            emit("session.start", session)
        case "UserPromptSubmit":
            session.state = .thinking
            session.lastPrompt = event.prompt
            session.limitStoppedAt = nil
            session.turnStartedAt = now
            if let prompt = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                Self.append(AgentMessage(id: UUID().uuidString, date: now, role: .user, text: Self.clipped(prompt)), to: &session)
            }
            // 직접 입력했으니 기다리던 도우미는 물러납니다 (다음에 멈추면 새로 생김).
            cancelWaiter(for: session.id)
            emit("session.prompt", session, ["prompt": .string(String((event.prompt ?? "").prefix(2000)))])
            // 터미널에서 직접 입력한 말과 함께 Claude가 읽으므로, 바쁠 때 보낸 말은 그대로 다음 멈춤까지 기다립니다.
        case "PreToolUse":
            if event.toolName == "AskUserQuestion", let connection {
                session.state = .waitingForAnswer
                save(session)
                addQuestion(event: event, session: session, connection: connection)
                return
            }
            preToolUse(event, context: envelope.context, session: &session, now: now)
        case "PermissionRequest":
            if let connection {
                session.state = .waitingForApproval
                save(session)
                emit("session.approval", session, ["tool": .string(event.toolName ?? ""),
                                                   "detail": .string(String(Self.detail(toolName: event.toolName ?? "", input: event.toolInput).prefix(2000)))])
                addPermission(event: event, session: session, connection: connection)
                return
            }
        case "PostToolUse", "PostToolUseFailure":
            postToolUse(event, context: envelope.context, failed: event.name == "PostToolUseFailure", session: &session)
        case "Notification":
            switch event.notificationType {
            case "permission_prompt":
                if requests(for: session.id).isEmpty { session.state = .waitingInTerminal }
            case "idle_prompt":
                session.state = .waitingForInput
            default:
                break
            }
        case "Stop", "StopFailure":
            session.state = event.name == "Stop" ? .done : .waitingForInput
            markRunningActivities(in: &session, as: event.name == "Stop" ? .succeeded : .failed)
            // 한도 때문에 멈췄는지: 오류 종류(StopFailure)나 마지막 안내 문구로 가려냅니다.
            let error = event.raw["error"]?.stringValue ?? ""
            let lastText = event.raw["last_assistant_message"]?.stringValue ?? ""
            if ["rate_limit", "billing_error"].contains(error) || Self.mentionsUsageLimit(lastText) {
                session.limitStoppedAt = now
            }
            // 마지막 대답은 훅에도 실려 옵니다 (대화 기록을 아직 못 읽었을 때를 위해).
            if let last = event.raw["last_assistant_message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !last.isEmpty, !session.messages.contains(where: { $0.role == .assistant && $0.text == Self.clipped(last) }) {
                Self.append(AgentMessage(id: UUID().uuidString, date: now, role: .assistant, text: Self.clipped(last)), to: &session)
            }
            emit(event.name == "Stop" ? "session.done" : "session.error", session,
                 ["message": .string(String((event.raw["last_assistant_message"]?.stringValue ?? "").prefix(2000)))])
            guard event.name == "Stop" else { break }
            postSummary(for: session, now: now)
            lastCompletion = now
            if UserDefaults.standard.bool(forKey: AppSettings.agentNotifications) {
                Notifier.post(
                    title: String(localized: "\(session.projectName): done"),
                    body: session.agent == nil ? String(localized: "Claude finished working.") : String(localized: "\(session.agentName) finished working.")
                )
            }
        case "SessionEnd":
            // 지우지 않고 기록으로 남깁니다 (보관 기간이 지나면 자동 삭제).
            session.state = .ended
            markRunningActivities(in: &session, as: .succeeded)
            cancelWaiter(for: session.id)
            save(session)
            emit("session.end", session)
            return
        default:
            break
        }
        // 답이 필요 없는 이벤트인데 연결이 남아 있으면 바로 돌려보냅니다.
        connection?.reply(nil)
        save(session)
        readTranscript(of: session.id)
    }

    private func upsertSession(for event: HookEvent, context: HookContext, now: Date) -> AgentSession {
        var session = self.session(event.sessionId) ?? AgentSession(
            id: event.sessionId,
            cwd: event.cwd ?? "",
            context: HookContext(),
            state: .starting,
            startedAt: now,
            updatedAt: now
        )
        if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let agent = event.raw["kongi_agent"]?.stringValue { session.agent = agent }
        if session.launchDirectory == nil, session.agent == nil, let cwd = event.cwd, let transcript = event.transcriptPath {
            session.launchDirectory = LaunchDirectory.find(cwd: cwd, transcriptPath: transcript)
        }
        // 대화 기록 파일은 Claude Code 형식만 읽습니다 (다른 에이전트는 훅으로 온 말만 보여 줌).
        if session.agent == nil, let transcript = event.transcriptPath, !transcript.isEmpty, session.transcriptPath != transcript {
            session.transcriptPath = transcript
            session.transcriptOffset = nil
        }
        // 새로 온 값만 덮어씁니다 (도구 이벤트에는 터미널 정보가 없음).
        var merged = session.context
        merged.termProgram = context.termProgram ?? merged.termProgram
        merged.bundleId = context.bundleId ?? merged.bundleId
        merged.tty = context.tty ?? merged.tty
        merged.termSessionId = context.termSessionId ?? merged.termSessionId
        merged.itermSessionId = context.itermSessionId ?? merged.itermSessionId
        merged.claudePid = context.claudePid ?? merged.claudePid
        merged.entrypoint = context.entrypoint ?? merged.entrypoint
        merged.originalFile = nil
        merged.currentFile = nil
        session.context = merged
        session.updatedAt = now
        if session.state == .ended { session.state = .starting }
        return session
    }

    private func preToolUse(_ event: HookEvent, context: HookContext, session: inout AgentSession, now: Date) {
        let toolName = event.toolName ?? "Tool"
        let activity = ToolActivity.describe(toolName: toolName, input: event.toolInput)
        session.state = .running(activity)
        // 파일을 고치는 단계면 무엇이 바뀌는지 바로 계산해 둡니다 (승인 전에도 보임).
        // 아주 큰 파일은 화면이 멈추지 않게 미리 보기를 건너뜁니다 (끝난 뒤 변경 내역에는 남음).
        let isEdit = ToolActivity.editedFilePath(toolName: toolName, input: event.toolInput) != nil
        let preview = (isEdit ? context.originalFile : nil).flatMap { ($0.content?.utf8.count ?? 0) < 400_000 ? $0 : nil }.flatMap { original in
            EditPreview.diff(toolName: toolName, input: event.toolInput, original: original.existed ? original.content : nil, context: 4)
        }
        // 읽는 곳은 가장 최근 단계에만 남깁니다 (기록이 커지지 않게).
        for index in session.activities.indices where session.activities[index].excerpt != nil {
            session.activities[index].excerpt = nil
        }
        session.activities.append(AgentActivity(
            id: event.toolUseId ?? UUID().uuidString,
            date: now,
            activity: activity,
            detail: Self.detail(toolName: toolName, input: event.toolInput),
            status: .running,
            preview: preview,
            excerpt: toolName == "Read" ? Self.excerpt(for: event.toolInput, file: context.originalFile) : nil
        ))
        if session.activities.count > AgentSession.maxActivities {
            session.activities.removeFirst(session.activities.count - AgentSession.maxActivities)
        }
        // 세션에서 처음 고치는 파일이면 고치기 전 내용을 기억해 둡니다.
        if isEdit, let original = context.originalFile, !session.changes.contains(where: { $0.path == original.path }) {
            session.changes.append(FileChange(
                path: original.path,
                original: original.content,
                existedBefore: original.existed,
                current: original.content,
                diff: .empty
            ))
        }
    }

    private func postToolUse(_ event: HookEvent, context: HookContext, failed: Bool, session: inout AgentSession) {
        let index = event.toolUseId.flatMap { id in session.activities.lastIndex { $0.id == id } }
            ?? session.activities.lastIndex { $0.status == .running }
        if let index {
            session.activities[index].status = failed ? .failed : .succeeded
            session.activities[index].output = Self.output(of: event)
        }
        session.state = .thinking

        guard !failed, let path = ToolActivity.editedFilePath(toolName: event.toolName, input: event.toolInput) else { return }
        // 고친 뒤 내용은 도우미가 보낸 것만 씁니다 (앱이 직접 열면 권한 창 때문에 멈출 수 있음).
        guard let file = context.currentFile, file.path == path else { return }
        let current = file.existed ? file.content : nil
        if let index = session.changes.firstIndex(where: { $0.path == path }) {
            session.changes[index].current = current
            session.changes[index].diff = LineDiff.compute(old: session.changes[index].original, new: current)
        } else {
            // PreToolUse를 놓친 경우: 비교할 원본이 없으므로 새 파일처럼 셉니다.
            session.changes.append(FileChange(
                path: path, original: nil, existedBefore: false, current: current,
                diff: LineDiff.compute(old: nil, new: current)
            ))
        }
        // 되돌려서 차이가 없어진 파일은 목록에서 뺍니다.
        session.changes.removeAll { $0.diff == .empty && $0.existedBefore }
    }

    private func markRunningActivities(in session: inout AgentSession, as status: AgentActivity.Status) {
        for index in session.activities.indices where session.activities[index].status == .running {
            session.activities[index].status = status
        }
    }

    private func save(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        scheduleSave()
    }

    /// SessionEnd 없이 터미널을 닫은 세션도 정리합니다.
    private func pruneDeadSessions() {
        // SessionEnd 없이 끝난 세션(터미널을 닫음 등)도 기록으로 남깁니다.
        let now = Date()
        var changed = false
        for index in sessions.indices where sessions[index].state != .ended {
            let session = sessions[index]
            let dead = session.context.claudePid.map { $0 > 0 && kill($0, 0) != 0 && errno == ESRCH } ?? false
            if dead || (now.timeIntervalSince(session.updatedAt) > 12 * 3600 && waiters[session.id] == nil) {
                sessions[index].state = .ended
                cancelWaiter(for: session.id)
                changed = true
            }
        }
        if changed { scheduleSave() }
        applyRetention()
        removeStaleWaiterFiles()
        let alive = Set(activeSessions.map(\.id))
        for request in requests where !alive.contains(request.sessionId) {
            finish(request, reply: nil)
        }
    }

    // MARK: Conversation (대화 내용과 아일랜드에서 보내기)

    /// Claude Code가 한도에 닿았을 때 보여 주는 안내인지 ("5-hour limit reached ∙ resets 3pm" 등)
    static func mentionsUsageLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.count < 400 else { return false }
        return (lower.contains("limit") && (lower.contains("reached") || lower.contains("resets")))
            || lower.contains("usage limit")
    }

    /// 이 폴더(또는 이 폴더를 품은 작업 영역)에서 아직 실행 중인 가장 최근 대화
    func liveSession(in path: String) -> AgentSession? {
        sessions.filter { session in
            guard session.isAlive else { return false }
            if session.cwd == path { return true }
            guard let root = session.launchDirectory else { return false }
            return path == root || path.hasPrefix(root + "/")
        }
        .max { $0.updatedAt < $1.updatedAt }
    }

    /// 대화가 다음에 멈출 때 전달할 말 (예약 실행용). 기다리는 도우미가 설치돼 있어야 합니다.
    func enqueue(_ text: String, for sessionId: String) {
        queued[sessionId, default: []].append(text)
        guard var session = session(sessionId) else { return }
        Self.append(AgentMessage(id: UUID().uuidString, date: Date(), role: .user, text: Self.clipped(text), queued: true), to: &session)
        save(session)
    }

    private static func clipped(_ text: String) -> String {
        text.count > TranscriptReader.maxText ? String(text.prefix(TranscriptReader.maxText)) + "…" : text
    }

    private static func append(_ message: AgentMessage, to session: inout AgentSession) {
        session.messages.append(message)
        if session.messages.count > AgentSession.maxMessages {
            session.messages.removeFirst(session.messages.count - AgentSession.maxMessages)
        }
    }

    /// Read 도구가 읽는 부분 (파일의 offset부터 최대 40줄)
    private static func excerpt(for input: JSONValue?, file: OriginalFile?) -> CodeExcerpt? {
        guard let file, let text = file.content else { return nil }
        let path = file.path
        let lines = text.components(separatedBy: "\n")
        // 훅 입력은 믿지 않습니다: 무한대·NaN·아주 큰 수도 안전한 범위로 맞춥니다.
        func clamped(_ value: Double?, default fallback: Int, in range: ClosedRange<Int>) -> Int {
            guard let value, value.isFinite else { return fallback }
            return Int(min(max(value.rounded(.down), Double(range.lowerBound)), Double(range.upperBound)))
        }
        let start = clamped(input?["offset"]?.numberValue, default: 1, in: 1...max(lines.count, 1))
        let count = clamped(input?["limit"]?.numberValue, default: 40, in: 0...40)
        let lower = start - 1
        let upper = min(lower + count, lines.count)
        guard lower < upper else { return nil }
        let slice = lines[lower..<upper].map { $0.count > 400 ? String($0.prefix(400)) : $0 }
        return CodeExcerpt(path: path, startLine: start, lines: Array(slice))
    }

    /// 명령의 출력(마지막 몇 줄). 파일 읽기처럼 길고 뻔한 결과는 담지 않습니다.
    private static func output(of event: HookEvent) -> String? {
        guard event.toolName == "Bash" || event.name == "PostToolUseFailure" else { return nil }
        let response = event.toolResponse
        let text = [response?["stdout"]?.stringValue, response?["stderr"]?.stringValue, response?["error"]?.stringValue,
                    event.raw["error"]?.stringValue, response?.stringValue]
            .compactMap { $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n")
        return lines.count > 1500 ? "…" + String(lines.suffix(1500)) : lines
    }

    /// Claude가 쓴 글을 대화 기록에서 새로 읽어 옵니다 (파일 읽기는 뒤에서).
    func readTranscript(of sessionId: String) {
        guard !transcriptReads.contains(sessionId), let session = session(sessionId),
              let path = session.transcriptPath else { return }
        transcriptReads.insert(sessionId)
        let offset = session.transcriptOffset
        Task.detached(priority: .utility) { [weak self] in
            let result = TranscriptReader.readWithTurn(URL(fileURLWithPath: path), from: offset)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.transcriptReads.remove(sessionId)
                guard var session = self.session(sessionId), session.transcriptPath == path else { return }
                session.transcriptOffset = result.offset
                session.readerVersion = AgentSession.readerVersion
                let known = Set(session.messages.map(\.id))
                var changed = false
                for message in result.messages where !known.contains(message.id) {
                    let role: AgentMessage.Role = message.role == .user ? .user : .assistant
                    // 훅으로 먼저 받은 같은 글(입력한 말, 마지막 대답)은 대화 기록의 것으로 바꿉니다.
                    session.messages.removeAll { $0.role == role && $0.queued != true && $0.text == message.text }
                    Self.append(AgentMessage(id: message.id, date: message.date, role: role, text: message.text), to: &session)
                    changed = true
                }
                if changed { session.messages.sort { $0.date < $1.date } }
                // 훅 이벤트를 놓쳤어도(앱 재시작, Esc로 중단) 대화 기록이 끝났다고 하면 "일하는 중"을 풀어 줍니다.
                if let index = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                    self.reconcile(index: index, with: result.turn)
                }
                // 바뀐 것이 없으면 건드리지 않습니다 (배열을 고치기만 해도 화면 전체가 다시 그려짐).
                if let index = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                    let current = self.sessions[index]
                    let moved = current.transcriptOffset != session.transcriptOffset
                    let branchChanged = result.branch != nil && result.branch != current.gitBranch
                    guard changed || moved || branchChanged || current.readerVersion != AgentSession.readerVersion else { return }
                    var updated = current
                    if let branch = result.branch { updated.gitBranch = branch }
                    updated.transcriptOffset = session.transcriptOffset
                    updated.readerVersion = AgentSession.readerVersion
                    if changed { updated.messages = session.messages }
                    self.sessions[index] = updated
                    self.scheduleSave()
                }
            }
        }
    }

    private func reconcile(index: Int, with turn: TranscriptReader.TurnState?) {
        guard sessions[index].state.isBusy, let turn else { return }
        let state: AgentState
        switch turn {
        case let .ended(date) where date >= sessions[index].updatedAt.addingTimeInterval(-2): state = .done
        case let .interrupted(date) where date >= sessions[index].updatedAt.addingTimeInterval(-2): state = .waitingForInput
        default: return
        }
        sessions[index].state = state
        for activity in sessions[index].activities.indices where sessions[index].activities[activity].status == .running {
            sessions[index].activities[activity].status = .succeeded
        }
        scheduleSave()
    }

    /// 일이 끝나면 아일랜드에 잠깐: "my-app 완료 · 파일 3개  +120 −40 · 4분"
    private func postSummary(for session: AgentSession, now: Date) {
        guard UserDefaults.standard.bool(forKey: AppSettings.islandShowsCompletion) else { return }
        let start = session.turnStartedAt ?? session.activities.first?.date ?? now
        let steps = session.activities.filter { $0.date >= start }
        guard !steps.isEmpty else { return }
        let edits = steps.filter { $0.preview != nil }
        let files = Set(edits.map(\.detail)).count
        let added = edits.reduce(0) { $0 + ($1.preview?.added ?? 0) }
        let removed = edits.reduce(0) { $0 + ($1.preview?.removed ?? 0) }
        let minutes = max(Int(now.timeIntervalSince(start) / 60), 1)
        var trailing = String(localized: "\(minutes) min")
        if added + removed > 0 { trailing = "+\(added) −\(removed) · " + trailing }
        AppServices.shared.devices.post(.init(
            key: "done-\(session.id)",
            symbol: "checkmark.circle.fill",
            tint: KongiTheme.green,
            title: String(localized: "\(session.projectName): done"),
            detail: files > 0 ? String(localized: "\(files) files") : String(localized: "\(steps.count) steps"),
            trailing: trailing,
            action: .openSession(session.id)
        ), for: 6)
    }

    enum SendResult: Equatable {
        /// 멈춰 있던 대화에 바로 전달됨 (또는 터미널에 입력함)
        case sent
        /// 대화가 바빠서, 다음에 멈출 때 전달됨
        case queued
        /// 대화가 끝나 있어 같은 대화를 뒤에서 이어 실행함
        case resumed
        /// 연결을 업데이트해야 보낼 수 있음
        case needsUpdate
        case failed
    }

    /// 아일랜드나 휴대폰에서 대화에 이어서 말하기
    @discardableResult
    func send(_ text: String, to sessionId: String, from source: String = "Kongi") -> SendResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var session = session(sessionId) else { return .failed }
        let alive = session.isAlive
        // Codex 등 다른 에이전트는 실행 중인 터미널에 입력하는 것만 됩니다.
        if session.agent != nil {
            return alive && session.state != .ended && TerminalJumper.send(text, to: session.context) ? .sent : .failed
        }
        var message = AgentMessage(id: UUID().uuidString, date: Date(), role: .user, text: Self.clipped(text))

        let result: SendResult
        if wake(sessionId, with: Self.userMessage(text, from: source)) {
            result = .sent
        } else if alive, session.state != .ended, TerminalJumper.send(text, to: session.context) {
            // 터미널 입력은 UserPromptSubmit으로 다시 들어오므로 여기서는 기록하지 않습니다.
            return .sent
        } else if !alive || session.state == .ended {
            let prompt = ScheduledPrompt(
                projectPath: session.cwd, prompt: text, trigger: .at(Date()),
                continueConversation: true, permission: .acceptEdits,
                sessionId: session.id, sessionContext: session.context
            )
            AppServices.shared.scheduler.save(prompt)
            result = .resumed
        } else if !canQueue(for: sessionId) {
            return .needsUpdate
        } else {
            queued[sessionId, default: []].append(text)
            message.queued = true
            result = .queued
        }
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            session = sessions[index]
            Self.append(message, to: &session)
            if result == .sent {
            session.state = .thinking
            session.turnStartedAt = Date()
        }
            session.updatedAt = Date()
            save(session)
        }
        return result
    }

    /// 아직 전달하지 않은 말을 취소합니다.
    func cancelQueued(for sessionId: String) {
        queued[sessionId] = nil
        guard var session = session(sessionId) else { return }
        session.messages.removeAll { $0.queued == true }
        save(session)
    }

    private static func userMessage(_ text: String, from source: String) -> String {
        "Message from the user, sent with \(source):\n\n" + text
    }

    /// 기다리는 도우미가 연결되면 바쁠 때 보낸 말을 바로 전달합니다.
    private func deliverQueued(_ sessionId: String) {
        guard let texts = queued[sessionId], !texts.isEmpty else { return }
        guard wake(sessionId, with: Self.userMessage(texts.joined(separator: "\n\n"), from: "Kongi")) else { return }
        queued[sessionId] = nil
        guard var session = session(sessionId) else { return }
        for index in session.messages.indices where session.messages[index].queued == true {
            session.messages[index].queued = nil
        }
        save(session)
    }

    // MARK: Continue (멈춘 대화 깨우기)

    private func addWaiter(_ connection: HookConnection, for sessionId: String) {
        // 대화마다 하나만: 예전 도우미는 끝냅니다.
        waiters[sessionId]?.reply(nil)
        waiters[sessionId] = connection
        waiterSeen.insert(sessionId)
        resumable.insert(sessionId)
        connection.onClose = { [weak self, weak connection] in
            guard let self, let connection, self.waiters[sessionId] === connection else { return }
            self.waiters[sessionId] = nil
            self.resumable.remove(sessionId)
        }
        deliverQueued(sessionId)
    }

    private func cancelWaiter(for sessionId: String) {
        waiters.removeValue(forKey: sessionId)?.reply(nil)
        resumable.remove(sessionId)
    }

    /// 대화가 닫히며 강제로 끝난 도우미가 남긴 표시 파일을 지웁니다.
    private func removeStaleWaiterFiles() {
        let folder = HookPaths.supportDirectory.appendingPathComponent("waiters")
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "pid" {
            let pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int32($0) } ?? 0
            if pid <= 0 || (kill(pid, 0) != 0 && errno == ESRCH) { try? fm.removeItem(at: file) }
        }
    }

    /// 멈춘 대화에 말을 보내 같은 대화에서 이어서 하게 합니다 (터미널 종류와 상관없이, VS Code 포함).
    /// 기다리는 도우미가 없으면 false.
    @discardableResult
    func wake(_ sessionId: String, with prompt: String) -> Bool {
        guard let connection = waiters.removeValue(forKey: sessionId) else { return false }
        resumable.remove(sessionId)
        connection.reply(HookReplies.continuePrompt(prompt))
        setState(.thinking, for: sessionId)
        return true
    }

    /// 이 폴더(또는 이 폴더를 품은 작업 영역)에서 가장 최근에 멈춘, 깨울 수 있는 대화 (폴더 단위 "이어서 하기" 예약용)
    func resumableSession(in path: String) -> AgentSession? {
        sessions
            .filter { session in
                guard resumable.contains(session.id) else { return false }
                if session.cwd == path { return true }
                guard let root = session.launchDirectory else { return false }
                return path == root || path.hasPrefix(root + "/")
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: Requests

    private func addPermission(event: HookEvent, session: AgentSession, connection: HookConnection) {
        guard UserDefaults.standard.bool(forKey: AppSettings.approvalsInIsland) else {
            connection.reply(nil)
            return
        }
        let toolName = event.toolName ?? "Tool"
        let info = PermissionInfo(
            toolName: toolName,
            activity: ToolActivity.describe(toolName: toolName, input: event.toolInput),
            detail: Self.detail(toolName: toolName, input: event.toolInput),
            // 화면에 보여 줄 수 있는 프로젝트 범위 규칙만 "항상 허용"에 씁니다.
            suggestions: PermissionRule.safeSuggestions(event.permissionSuggestions)
        )
        enqueue(AgentRequest(sessionId: session.id, createdAt: Date(), kind: .permission(info), connection: connection))
        notifyAttention(session, body: String(localized: "Claude wants to use \(toolName)."))
    }

    private func addQuestion(event: HookEvent, session: AgentSession, connection: HookConnection) {
        let questions = AgentQuestion.parse(event.toolInput)
        guard UserDefaults.standard.bool(forKey: AppSettings.approvalsInIsland), !questions.isEmpty, let input = event.toolInput else {
            connection.reply(nil)
            return
        }
        enqueue(AgentRequest(sessionId: session.id, createdAt: Date(), kind: .question(questions, toolInput: input), connection: connection))
        notifyAttention(session, body: questions.first?.question ?? "")
    }

    private func enqueue(_ request: AgentRequest) {
        requests.append(request)
        request.connection?.onClose = { [weak self] in
            // Claude를 멈추거나 터미널을 닫아 훅이 끝났습니다.
            self?.drop(request.id)
        }
        let seconds = UserDefaults.standard.integer(forKey: AppSettings.approvalFallbackSeconds)
        if seconds > 0 {
            fallbackTasks[request.id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                self?.replyInTerminal(request)
            }
        }
    }

    private func notifyAttention(_ session: AgentSession, body: String) {
        guard UserDefaults.standard.bool(forKey: AppSettings.agentNotifications) else { return }
        Notifier.post(title: String(localized: "\(session.projectName): needs you"), body: body, phone: false)
    }

    func allow(_ request: AgentRequest, always: Bool = false) {
        guard case let .permission(info) = request.kind else { return }
        finish(request, reply: HookReplies.permission(allow: true, always: always ? info.suggestions : nil))
        setState(.running(info.activity), for: request.sessionId)
    }

    func deny(_ request: AgentRequest) {
        finish(request, reply: HookReplies.permission(allow: false, message: String(localized: "Denied from Kongi.")))
        setState(.thinking, for: request.sessionId)
    }

    func answer(_ request: AgentRequest, answers: [String: String]) {
        guard case let .question(_, input) = request.kind else { return }
        finish(request, reply: HookReplies.answers(toolInput: input, answers: answers))
        setState(.thinking, for: request.sessionId)
    }

    /// 앱에서 답하지 않고 터미널의 평소 질문으로 넘깁니다.
    func replyInTerminal(_ request: AgentRequest) {
        guard requests.contains(where: { $0.id == request.id }) else { return }
        finish(request, reply: nil)
        setState(.waitingInTerminal, for: request.sessionId)
    }

    private func finish(_ request: AgentRequest, reply: JSONValue?) {
        request.connection?.reply(reply)
        drop(request.id)
    }

    private func drop(_ id: UUID) {
        fallbackTasks[id]?.cancel()
        fallbackTasks[id] = nil
        guard let request = requests.first(where: { $0.id == id }) else { return }
        requests.removeAll { $0.id == id }
        if requests(for: request.sessionId).isEmpty, let session = session(request.sessionId), session.state.needsAttention,
           session.state != .waitingInTerminal {
            setState(.thinking, for: request.sessionId)
        }
    }

    private func setState(_ state: AgentState, for sessionId: String) {
        guard var session = session(sessionId) else { return }
        session.state = state
        session.updatedAt = Date()
        save(session)
    }

    // MARK: Helpers

    /// 확장의 events 파일에 알립니다.
    private func emit(_ name: String, _ session: AgentSession, _ extra: [String: JSONValue] = [:]) {
        var payload: [String: JSONValue] = [
            "session_id": .string(session.id), "agent": .string(session.agent ?? "claude"),
            "project": .string(session.projectName), "cwd": .string(session.cwd),
        ]
        payload.merge(extra) { $1 }
        AppServices.shared.extensions.emit(name, payload)
    }

    static func detail(toolName: String, input: JSONValue?) -> String {
        switch toolName {
        // 명령 전체, apply_patch는 패치 전체 (승인 화면에 쓰임). 명령을 못 찾으면 아래에서 입력 전체를 보여 줍니다.
        case "Bash", "shell", "exec_command", "apply_patch" where ToolActivity.commandText(input) != nil:
            return ToolActivity.commandText(input) ?? ""
        case "Edit", "MultiEdit", "Write", "Read": return input?["file_path"]?.stringValue ?? ""
        case "NotebookEdit": return input?["notebook_path"]?.stringValue ?? ""
        case "WebFetch": return input?["url"]?.stringValue ?? ""
        case "WebSearch": return input?["query"]?.stringValue ?? ""
        case "Glob", "Grep": return input?["pattern"]?.stringValue ?? ""
        case "Task", "Agent": return input?["prompt"]?.stringValue ?? input?["description"]?.stringValue ?? ""
        default:
            guard let input else { return "" }
            let text = String(decoding: input.encodedData(), as: UTF8.self)
            return text.count > 400 ? String(text.prefix(400)) + "…" : text
        }
    }

}
