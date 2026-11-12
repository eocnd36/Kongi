import Darwin
import Foundation

// MARK: - Hook event (Claude Code → hook stdin)
// https://code.claude.com/docs/en/hooks

/// Claude Code가 훅에 넘겨주는 이벤트 중 이 앱이 쓰는 필드
public struct HookEvent: Sendable {
    public var name: String
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var permissionMode: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var toolResponse: JSONValue?
    public var toolUseId: String?
    public var prompt: String?
    public var message: String?
    public var notificationType: String?
    public var source: String?
    public var permissionSuggestions: [JSONValue]
    public var raw: JSONValue

    public init(json: JSONValue) {
        raw = json
        name = json["hook_event_name"]?.stringValue ?? ""
        sessionId = json["session_id"]?.stringValue ?? "unknown"
        cwd = json["cwd"]?.stringValue
        transcriptPath = json["transcript_path"]?.stringValue
        permissionMode = json["permission_mode"]?.stringValue
        toolName = json["tool_name"]?.stringValue
        toolInput = json["tool_input"]
        toolResponse = json["tool_response"]
        toolUseId = json["tool_use_id"]?.stringValue
        prompt = json["prompt"]?.stringValue
        message = json["message"]?.stringValue
        notificationType = json["notification_type"]?.stringValue
        source = json["source"]?.stringValue
        permissionSuggestions = json["permission_suggestions"]?.arrayValue ?? []
    }

    /// 앱의 답을 기다려야 하는 이벤트 (권한 요청, Claude의 선택형 질문)
    public var needsReply: Bool {
        name == "PermissionRequest" || (name == "PreToolUse" && toolName == "AskUserQuestion")
    }

    /// Codex 훅 입력: turn_id가 있거나 대화 기록이 ~/.codex/ 아래에 있음 (Claude Code는 둘 다 아님)
    public static func looksLikeCodex(_ json: JSONValue) -> Bool {
        json["turn_id"] != nil || json["transcript_path"]?.stringValue?.contains("/.codex/") == true
    }

    /// 터미널 위치 같은 정보를 다시 모을 만한 이벤트 (도구 이벤트마다 프로세스를 띄우지 않도록)
    public var wantsTerminalContext: Bool {
        ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop"].contains(name)
            || needsReply
    }
}

// MARK: - Wire format (hook ⇄ app, one JSON object per line over a Unix socket)

public struct HookContext: Codable, Equatable, Sendable {
    /// TERM_PROGRAM (Apple_Terminal, iTerm.app, WarpTerminal, ghostty, vscode …)
    public var termProgram: String?
    /// 터미널 앱의 번들 ID (__CFBundleIdentifier)
    public var bundleId: String?
    /// Claude가 실행 중인 터미널 (/dev/ttys003)
    public var tty: String?
    public var termSessionId: String?
    public var itermSessionId: String?
    /// Claude Code 프로세스 (세션이 끝났는지 확인하는 용도)
    public var claudePid: Int32?
    /// 파일을 고치기 직전의 내용 (변경 내역 비교용)
    public var originalFile: OriginalFile?
    /// CLAUDE_CODE_ENTRYPOINT (cli, claude-vscode …). VS Code 확장에서 실행된 대화는 그 탭으로 바로 이동합니다.
    public var entrypoint: String?
    /// 파일을 고친 뒤의 내용 (PostToolUse). 도우미가 읽어 보냅니다.
    /// 앱이 사용자 파일을 직접 열면 외장 디스크·문서 폴더 권한 창이 떠 앱이 멈출 수 있어서입니다.
    public var currentFile: OriginalFile?

    public init(
        termProgram: String? = nil, bundleId: String? = nil, tty: String? = nil,
        termSessionId: String? = nil, itermSessionId: String? = nil,
        claudePid: Int32? = nil, originalFile: OriginalFile? = nil, entrypoint: String? = nil
    ) {
        self.termProgram = termProgram
        self.bundleId = bundleId
        self.tty = tty
        self.termSessionId = termSessionId
        self.itermSessionId = itermSessionId
        self.claudePid = claudePid
        self.originalFile = originalFile
        self.entrypoint = entrypoint
    }
}

public struct OriginalFile: Codable, Equatable, Sendable {
    public var path: String
    public var content: String?
    public var existed: Bool

    /// 너무 큰 파일이나 텍스트가 아닌 파일은 내용 없이 보냅니다.
    public static let maxBytes = 1_000_000

    public init(path: String, content: String?, existed: Bool) {
        self.path = path
        self.content = content
        self.existed = existed
    }

    public static func read(_ path: String) -> OriginalFile {
        guard FileManager.default.fileExists(atPath: path) else {
            return OriginalFile(path: path, content: nil, existed: false)
        }
        // 일반 파일만, 정해진 크기까지만 읽습니다. 장치 파일(/dev/zero)이나 FIFO는 끝없이 읽거나 멈출 수 있어
        // 열지 않고, 열 때도 막히지 않게(O_NONBLOCK) 엽니다. 링크는 따라가지 않습니다.
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= off_t(maxBytes) else {
            return OriginalFile(path: path, content: nil, existed: true)
        }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return OriginalFile(path: path, content: nil, existed: true) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else {
            return OriginalFile(path: path, content: nil, existed: true)
        }
        return OriginalFile(path: path, content: String(data: data, encoding: .utf8), existed: true)
    }

}

public struct HookEnvelope: Codable, Sendable {
    public var version: Int
    public var event: JSONValue
    public var context: HookContext
    public var expectsReply: Bool
    /// 대화가 멈춘 동안 뒤에서 기다리는 도우미(`--wait`)의 연결. 앱이 이어서 보낼 말을 답하면 그 대화가 다시 깨어납니다.
    public var waitsForContinue: Bool?

    public init(event: JSONValue, context: HookContext, expectsReply: Bool, waitsForContinue: Bool = false) {
        version = 1
        self.event = event
        self.context = context
        self.expectsReply = expectsReply
        self.waitsForContinue = waitsForContinue ? true : nil
    }
}

/// 앱 → 훅. output이 있으면 훅이 그대로 stdout에 출력하고, 없으면 Claude Code의 기본 동작(터미널에서 묻기)으로 넘어갑니다.
public struct HookReply: Codable, Sendable {
    public var output: JSONValue?

    public init(output: JSONValue?) {
        self.output = output
    }
}

public enum HookPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsageBar", isDirectory: true)
    }

    public static var socketPath: String {
        supportDirectory.appendingPathComponent("hook.sock").path
    }

    public static let helperName = "claude-usage-hook"

    /// 앱을 옮기거나 지워도 훅 경로가 깨지지 않도록 도우미를 고정된 위치에 복사해 둡니다.
    public static var installedHelper: URL {
        supportDirectory.appendingPathComponent("bin/\(helperName)")
    }
}

// MARK: - Replies

public enum HookReplies {
    /// `--wait` 도우미에게: 이 말로 대화를 깨웁니다 (Claude Code의 asyncRewake, 종료 코드 2 + stderr).
    public static func continuePrompt(_ text: String) -> JSONValue {
        .object(["continuePrompt": .string(text)])
    }

    /// PermissionRequest 응답. always면 Claude Code가 제안한 규칙(permission_suggestions)을 그대로 저장하게 합니다.
    public static func permission(allow: Bool, always suggestions: [JSONValue]? = nil, message: String? = nil) -> JSONValue {
        var decision: [String: JSONValue] = ["behavior": .string(allow ? "allow" : "deny")]
        if allow, let suggestions, !suggestions.isEmpty {
            decision["updatedPermissions"] = .array(suggestions)
        }
        if !allow, let message {
            decision["message"] = .string(message)
        }
        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ]),
        ])
    }

    /// AskUserQuestion 응답. 원래 입력에 answers(질문 → 선택한 라벨)를 더해 허용합니다.
    public static func answers(toolInput: JSONValue, answers: [String: String]) -> JSONValue {
        var input = toolInput.objectValue ?? [:]
        input["answers"] = .object(answers.mapValues(JSONValue.string))
        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string("allow"),
                "updatedInput": .object(input),
            ]),
        ])
    }
}

// MARK: - AskUserQuestion

public struct AgentQuestion: Identifiable, Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable {
        public var label: String
        public var description: String?
        public var id: String { label }
    }

    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    public var id: String { question }

    public static func parse(_ toolInput: JSONValue?) -> [AgentQuestion] {
        (toolInput?["questions"]?.arrayValue ?? []).compactMap { value in
            guard let question = value["question"]?.stringValue else { return nil }
            let options = (value["options"]?.arrayValue ?? []).compactMap { option -> Option? in
                guard let label = option["label"]?.stringValue else { return nil }
                return Option(label: label, description: option["description"]?.stringValue)
            }
            return AgentQuestion(
                question: question,
                header: value["header"]?.stringValue,
                options: options,
                multiSelect: value["multiSelect"]?.boolValue ?? false
            )
        }
    }

    /// 복수 선택은 라벨을 쉼표로 이어 붙입니다 (Claude Code 형식).
    public static func answerText(_ labels: [String]) -> String {
        labels.joined(separator: ", ")
    }
}

// MARK: - Tool activity

public struct ToolActivity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case read, edit, write, run, search, web, agent, plan, question, other
    }

    public var kind: Kind
    public var toolName: String
    /// 파일 이름, 명령어, 검색어 등 사람이 알아볼 대상
    public var target: String

    public init(kind: Kind, toolName: String, target: String) {
        self.kind = kind
        self.toolName = toolName
        self.target = target
    }

    public static func describe(toolName: String, input: JSONValue?) -> ToolActivity {
        func file(_ key: String) -> String {
            guard let path = input?[key]?.stringValue else { return "" }
            return (path as NSString).lastPathComponent
        }
        func short(_ text: String?, limit: Int = 80) -> String {
            let line = (text ?? "").split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }

        switch toolName {
        case "Read":
            return ToolActivity(kind: .read, toolName: toolName, target: file("file_path"))
        case "Edit", "MultiEdit":
            return ToolActivity(kind: .edit, toolName: toolName, target: file("file_path"))
        case "Write":
            return ToolActivity(kind: .write, toolName: toolName, target: file("file_path"))
        case "NotebookEdit":
            return ToolActivity(kind: .edit, toolName: toolName, target: file("notebook_path"))
        case "Bash", "BashOutput", "shell", "exec_command":
            // Claude Code가 명령마다 붙이는 짧은 설명이 있으면 그것을 (긴 명령 대신)
            let description = input?["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolActivity(kind: .run, toolName: "Bash",
                                target: short(description?.isEmpty == false ? description : commandText(input)))
        case "apply_patch":
            // Codex: 패치 안의 "*** Update File: 경로"
            let path = patchedFiles(commandText(input)).first ?? ""
            return ToolActivity(kind: .edit, toolName: "Edit", target: (path as NSString).lastPathComponent)
        case "Glob", "Grep":
            return ToolActivity(kind: .search, toolName: toolName, target: short(input?["pattern"]?.stringValue))
        case "WebFetch":
            let url = input?["url"]?.stringValue.flatMap(URL.init(string:))
            return ToolActivity(kind: .web, toolName: toolName, target: url?.host ?? "")
        case "WebSearch":
            return ToolActivity(kind: .web, toolName: toolName, target: short(input?["query"]?.stringValue))
        case "Task", "Agent":
            return ToolActivity(kind: .agent, toolName: toolName, target: short(input?["description"]?.stringValue))
        case "TodoWrite", "ExitPlanMode", "EnterPlanMode":
            return ToolActivity(kind: .plan, toolName: toolName, target: "")
        case "AskUserQuestion":
            let first = AgentQuestion.parse(input).first?.question
            return ToolActivity(kind: .question, toolName: toolName, target: short(first))
        default:
            // MCP 도구는 mcp__server__tool 형태 → 마지막 부분만
            let name = toolName.components(separatedBy: "__").last ?? toolName
            return ToolActivity(kind: .other, toolName: name, target: "")
        }
    }

    /// Codex는 명령을 문자열이나 ["bash", "-lc", "…"] 배열로 보냅니다.
    public static func commandText(_ input: JSONValue?) -> String? {
        if let text = input?["command"]?.stringValue { return text }
        if case .array(let parts)? = input?["command"] { return parts.compactMap(\.stringValue).last }
        return input?["input"]?.stringValue
    }

    /// apply_patch 내용에서 고치는 파일들
    public static func patchedFiles(_ patch: String?) -> [String] {
        (patch ?? "").split(separator: "\n").compactMap { line in
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    /// 변경 내역을 추적할 파일 경로 (파일을 고치는 도구만)
    public static func editedFilePath(toolName: String?, input: JSONValue?) -> String? {
        switch toolName {
        case "Edit", "MultiEdit", "Write": return input?["file_path"]?.stringValue
        case "NotebookEdit": return input?["notebook_path"]?.stringValue
        default: return nil
        }
    }
}

// MARK: - "Always allow" rules

/// "항상 허용"으로 저장될 규칙. 사용자에게 정확히 보여 줄 수 있는 것만 통과시킵니다.
public struct PermissionRule: Equatable, Sendable {
    public var toolName: String
    public var content: String?
    public var destination: String

    /// `Bash(npm test)` 형태 (Claude Code 권한 규칙 문법)
    public var text: String {
        guard let content, !content.isEmpty else { return toolName }
        return "\(toolName)(\(content))"
    }

    /// 프로젝트 범위 저장소만 허용합니다. 권한 모드 변경(setMode)이나 모든 프로젝트(userSettings)에 적용되는 제안은 뺍니다.
    public static let allowedDestinations: Set<String> = ["session", "localSettings", "projectSettings"]

    /// 화면에 전부 그대로 보여 줄 수 있는 규칙인지 (줄바꿈·제어 문자·글자 방향 문자가 없고 너무 길지 않음)
    static func isDisplayable(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 300 else { return false }
        return !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || (0x200E...0x200F).contains(scalar.value)
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
        }
    }

    /// 보여 줄 "항상 허용" 규칙. 규칙 하나라도 검증을 통과하지 못하면 그 제안 전체를 버립니다.
    public static func rules(in suggestions: [JSONValue]) -> [PermissionRule] {
        suggestions.flatMap { suggestion -> [PermissionRule] in
            guard suggestion["type"]?.stringValue == "addRules",
                  suggestion["behavior"]?.stringValue == "allow",
                  let destination = suggestion["destination"]?.stringValue,
                  allowedDestinations.contains(destination),
                  let raw = suggestion["rules"]?.arrayValue, !raw.isEmpty else { return [] }
            let rules = raw.compactMap { rule -> PermissionRule? in
                guard let tool = rule["toolName"]?.stringValue, isDisplayable(tool) else { return nil }
                let content = rule["ruleContent"]?.stringValue
                if let content, !isDisplayable(content) { return nil }
                return PermissionRule(toolName: tool, content: content, destination: destination)
            }
            return rules.count == raw.count ? rules : []
        }
    }

    /// "항상 허용" 응답에 넣을 제안. 받은 JSON을 그대로 쓰지 않고, 화면에 보여 준 규칙만으로 새로 만듭니다.
    public static func safeSuggestions(_ suggestions: [JSONValue]) -> [JSONValue] {
        rules(in: suggestions).map { rule in
            var entry: [String: JSONValue] = ["toolName": .string(rule.toolName)]
            if let content = rule.content { entry["ruleContent"] = .string(content) }
            return .object([
                "type": .string("addRules"),
                "behavior": .string("allow"),
                "destination": .string(rule.destination),
                "rules": .array([.object(entry)]),
            ])
        }
    }
}

/// Claude Code가 대화를 시작한 폴더. 대화 중 `cd`로 바뀌는 cwd와 달리 VS Code 창(작업 영역)과 맞습니다.
public enum LaunchDirectory {
    /// ~/.claude/projects 아래 폴더 이름: 영문·숫자 말고는 모두 '-' (UTF-16 글자 단위)
    public static func encoded(_ path: String) -> String {
        String(decoding: path.utf16.map { unit -> UInt16 in
            let isAlnum = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            return isAlnum ? unit : 0x2D
        }, as: UTF16.self)
    }

    /// cwd와 그 상위 폴더 중 대화 기록(transcript) 폴더 이름과 맞는 곳
    public static func find(cwd: String, transcriptPath: String) -> String? {
        let folder = ((transcriptPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !folder.isEmpty, cwd.hasPrefix("/") else { return nil }
        var candidate = (cwd as NSString).standardizingPath
        while true {
            if encoded(candidate) == folder { return candidate }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { return nil }
            candidate = parent
        }
    }
}
