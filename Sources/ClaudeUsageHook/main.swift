// Claude Code 훅 도우미.
//
// Claude Code가 이벤트마다 실행합니다. stdin의 이벤트를 Kongi 앱으로 넘기고,
// 권한 요청과 선택형 질문은 앱의 답을 기다렸다가 stdout으로 돌려줍니다.
// 앱이 꺼져 있거나 문제가 생기면 아무것도 출력하지 않고 바로 끝나서, Claude Code는 평소대로 동작합니다.
//
// `--wait`로 실행되면(대화가 멈춘 뒤, asyncRewake) 뒤에서 기다리다가 Kongi가 이어서 보낼 말을 주면
// 그 말을 stderr로 내고 종료 코드 2로 끝나 같은 대화를 깨웁니다. 그 밖에는 조용히 0으로 끝납니다.
import ClaudeUsageCore
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

// `kongi` 명령: 개발자가 만든 앱·스크립트·확장이 아일랜드에 알림을 보내거나, 빌드·테스트를 감싸 진행률을 보냅니다.
if let command = CommandLine.arguments.dropFirst().first, ["notify", "task", "widget", "status", "run", "codex", "help", "--help"].contains(command) {
    exit(KongiCommand.main(Array(CommandLine.arguments.dropFirst(2)), command: command))
}

// 셸 연동: 오래 걸린 명령이 끝났을 때 (--shell 상태 초 폴더 명령)
let shellArgs = Array(CommandLine.arguments.dropFirst())
if shellArgs.first == "--shell", shellArgs.count >= 5 {
    let event: JSONValue = .object([
        "hook_event_name": .string("ShellCommand"),
        "session_id": .string("shell"),
        "status": .number(Double(shellArgs[1]) ?? 0),
        "seconds": .number(Double(shellArgs[2]) ?? 0),
        "cwd": .string(shellArgs[3]),
        "command": .string(shellArgs[4...].joined(separator: " ")),
    ])
    if let fd = UnixSocket.connect(path: HookPaths.socketPath),
       let data = try? JSONEncoder().encode(HookEnvelope(event: event, context: HookContext(), expectsReply: false)) {
        UnixSocket.writeLine(fd, data)
        close(fd)
    }
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var json = try? JSONDecoder().decode(JSONValue.self, from: input) else { exit(0) }
// 다른 에이전트(Codex 등)의 훅: `--agent codex`. Claude Code와 같은 형식이라 그대로 넘기고 이름만 붙입니다.
// Codex 앱은 Claude Code의 훅 설정을 가져다 쓰기도 해서, 플래그가 없어도 Codex 형식이면 알아봅니다.
if case .object(var fields) = json {
    if let flag = CommandLine.arguments.firstIndex(of: "--agent"), flag + 1 < CommandLine.arguments.count {
        fields["kongi_agent"] = .string(String(CommandLine.arguments[flag + 1].prefix(20)))
    } else if HookEvent.looksLikeCodex(json) {
        fields["kongi_agent"] = .string("codex")
    }
    json = .object(fields)
}
let event = HookEvent(json: json)

if CommandLine.arguments.dropFirst().contains(HookSettingsEditor.waitArgument) {
    waitForContinue()
}

var context = event.wantsTerminalContext ? TerminalProbe.current() : HookContext()
// 파일 내용은 도우미가 읽어 보냅니다 (Claude Code의 파일 접근 권한으로). 앱은 사용자 파일을 직접 열지 않습니다.
if event.name == "PreToolUse", let path = ToolActivity.editedFilePath(toolName: event.toolName, input: event.toolInput)
    ?? (event.toolName == "Read" ? event.toolInput?["file_path"]?.stringValue : nil) {
    context.originalFile = OriginalFile.read(path)
}
if event.name == "PostToolUse", let path = ToolActivity.editedFilePath(toolName: event.toolName, input: event.toolInput) {
    context.currentFile = OriginalFile.read(path)
}

guard let fd = UnixSocket.connect(path: HookPaths.socketPath) else { exit(0) }
defer { close(fd) }

let envelope = HookEnvelope(event: json, context: context, expectsReply: event.needsReply)
guard let data = try? JSONEncoder().encode(envelope), UnixSocket.writeLine(fd, data) else { exit(0) }

if envelope.expectsReply,
   let line = UnixSocket.readLine(fd),
   let reply = try? JSONDecoder().decode(HookReply.self, from: line),
   let output = reply.output {
    FileHandle.standardOutput.write(output.encodedData())
}
exit(0)

/// 대화 하나에 기다리는 도우미는 하나만 남깁니다. 새 도우미가 이 파일에 자기 pid를 쓰면 예전 것은 물러납니다
/// (앱이 켜져 있으면 앱이 직접 정리하고, 꺼져 있는 동안 재시도하던 것은 이 파일을 보고 끝납니다).
func waitForContinue() -> Never {
    let context = TerminalProbe.current()
    let safeId = event.sessionId.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    let ownerFile = safeId
        ? HookPaths.supportDirectory.appendingPathComponent("waiters/\(event.sessionId).pid") : nil
    let me = String(getpid())
    if let ownerFile {
        try? FileManager.default.createDirectory(at: ownerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(me.utf8).write(to: ownerFile, options: .atomic)
    }
    func stillMine() -> Bool {
        guard let ownerFile else { return true }
        return (try? String(contentsOf: ownerFile, encoding: .utf8)) == me
    }
    func claudeAlive() -> Bool {
        guard let pid = context.claudePid, pid > 0 else { return getppid() != 1 }
        return kill(pid, 0) == 0 || errno == EPERM
    }
    func leave(_ code: Int32) -> Never {
        if let ownerFile, stillMine() { try? FileManager.default.removeItem(at: ownerFile) }
        exit(code)
    }

    let deadline = Date().addingTimeInterval(TimeInterval(HookSettingsEditor.waitTimeout))
    let envelope = HookEnvelope(event: json, context: context, expectsReply: true, waitsForContinue: true)
    guard let data = try? JSONEncoder().encode(envelope) else { exit(0) }
    while Date() < deadline {
        guard stillMine() else { exit(0) }
        guard claudeAlive() else { leave(0) }
        if let fd = UnixSocket.connect(path: HookPaths.socketPath) {
            let sent = UnixSocket.writeLine(fd, data)
            let line = sent ? UnixSocket.readLine(fd) : nil
            close(fd)
            if let line {
                // 앱이 답했으면: 이어서 보낼 말이 있으면 깨우고, 없으면(새 도우미로 바뀜, 사용자가 직접 입력함) 끝냅니다.
                if let reply = try? JSONDecoder().decode(HookReply.self, from: line),
                   let prompt = reply.output?["continuePrompt"]?.stringValue, !prompt.isEmpty {
                    FileHandle.standardError.write(Data(prompt.utf8))
                    leave(2)
                }
                leave(0)
            }
            // 답 없이 끊김: 앱이 종료·재시작됨. 잠시 뒤 다시 연결합니다.
        }
        sleep(15)
    }
    leave(0)
}
