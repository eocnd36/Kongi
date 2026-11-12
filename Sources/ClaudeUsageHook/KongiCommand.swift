import ClaudeUsageCore
import Darwin
import Foundation

/// `kongi notify | task | widget | status | run | codex` — Kongi 앱이 꺼져 있으면 조용히 넘어갑니다 (`run`은 명령만 그대로 실행).
enum KongiCommand {
    static let usage = """
    kongi notify <title> [detail] [--symbol <SF Symbol>] [--seconds <n>] [--url <url>] [--id <id>]
    kongi task <id> [--name <label>] [--progress <0-1 or NN%>] [--detail <text>] [--done | --failed]
    kongi widget <id> [--title <t>] [--value <v>] [--detail <d>] [--symbol <s>] [--progress <0-1>] [--url <url>] | --remove
    kongi status                                   (JSON: usage, sessions, builds)
    kongi run [--name <label>] -- <command> [args…]
    Codex hooks: kongi --agent codex  (stdin = hook JSON, like Claude Code)
    """

    static func main(_ args: [String], command: String) -> Int32 {
        switch command {
        case "notify": return notify(args)
        case "task": return task(args)
        case "widget": return widget(args)
        case "status": return status()
        case "run": return run(args)
        case "codex": return codex(args)
        default:
            print(usage)
            return 0
        }
    }

    /// 앱의 로컬 소켓으로 이벤트 한 줄을 보냅니다 (같은 사용자만 열 수 있는 소켓). 확장에서 실행되면 확장 이름을 붙입니다.
    @discardableResult
    static func send(_ fields: [String: JSONValue], expectsReply: Bool = false) -> JSONValue? {
        guard let fd = UnixSocket.connect(path: HookPaths.socketPath) else { return nil }
        defer { close(fd) }
        var fields = fields
        let environment = ProcessInfo.processInfo.environment
        if fields["source"] == nil, let name = environment["KONGI_EXTENSION_NAME"] { fields["source"] = .string(name) }
        if let owner = environment["KONGI_EXTENSION"] { fields["owner"] = .string(owner) }
        guard let data = try? JSONEncoder().encode(HookEnvelope(event: .object(fields), context: HookContext(), expectsReply: expectsReply)),
              UnixSocket.writeLine(fd, data), expectsReply,
              let line = UnixSocket.readLine(fd) else { return nil }
        return (try? JSONDecoder().decode(HookReply.self, from: line))?.output
    }

    /// `--key value` 옵션과 나머지 단어로 나눕니다. flags는 값 없는 옵션.
    static func parse(_ args: [String], flags: Set<String> = []) -> (options: [String: String], words: [String]) {
        var options: [String: String] = [:], words: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--"), arg.count > 2 {
                let key = String(arg.dropFirst(2))
                if flags.contains(key) {
                    options[key] = "1"
                    index += 1
                    continue
                }
                if index + 1 < args.count {
                    options[key] = args[index + 1]
                    index += 2
                    continue
                }
            }
            words.append(arg)
            index += 1
        }
        return (options, words)
    }

    static func fail(_ text: String) -> Int32 {
        FileHandle.standardError.write(Data("usage: \(text)\n".utf8))
        return 64
    }

    /// "40%"나 "0.4" → 0.4
    static func fraction(_ text: String?) -> Double? {
        guard let text else { return nil }
        if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
        return Double(text).map { $0 > 1 ? $0 / 100 : $0 }
    }

    // MARK: notify

    static func notify(_ args: [String]) -> Int32 {
        let (options, words) = parse(args)
        guard let title = words.first, !title.isEmpty else { return fail("kongi notify <title> [detail]") }
        var fields: [String: JSONValue] = ["hook_event_name": .string("KongiNotify"), "session_id": .string("kongi"), "title": .string(title)]
        if words.count > 1 { fields["detail"] = .string(words[1...].joined(separator: " ")) }
        if let seconds = options["seconds"] { fields["seconds"] = .number(Double(seconds) ?? 5) }
        for key in ["symbol", "url", "id"] { if let value = options[key] { fields[key] = .string(value) } }
        send(fields)
        return 0
    }

    // MARK: task — 오래 걸리는 일을 직접 알릴 때 (run으로 감쌀 수 없는 것)

    static func task(_ args: [String]) -> Int32 {
        let (options, words) = parse(args, flags: ["done", "failed"])
        guard let id = words.first, !id.isEmpty else { return fail("kongi task <id> [--name <label>] [--progress 40%] [--done | --failed]") }
        let state = options["failed"] != nil ? "failed" : options["done"] != nil ? "succeeded" : "running"
        var fields: [String: JSONValue] = [
            "hook_event_name": .string("KongiTask"), "session_id": .string("kongi"),
            "id": .string(id), "state": .string(state), "cwd": .string(FileManager.default.currentDirectoryPath),
        ]
        if let name = options["name"] { fields["name"] = .string(name) }
        if let fraction = fraction(options["progress"]) { fields["fraction"] = .number(min(max(fraction, 0), 1)) }
        for key in ["passed", "failed-count"] { if let value = options[key].flatMap(Double.init) { fields[key == "passed" ? "passed" : "failed"] = .number(value) } }
        send(fields)
        return 0
    }

    // MARK: widget — 메뉴 막대 창에 작은 줄 하나 (값을 계속 바꿀 수 있음)

    static func widget(_ args: [String]) -> Int32 {
        let (options, words) = parse(args, flags: ["remove"])
        guard let id = words.first, !id.isEmpty else { return fail("kongi widget <id> --title <t> --value <v>") }
        var fields: [String: JSONValue] = ["hook_event_name": .string("KongiWidget"), "session_id": .string("kongi"), "id": .string(id)]
        if options["remove"] != nil { fields["remove"] = .bool(true) }
        for key in ["title", "value", "detail", "symbol", "url"] { if let value = options[key] { fields[key] = .string(value) } }
        if let fraction = fraction(options["progress"]) { fields["progress"] = .number(fraction) }
        send(fields)
        return 0
    }

    // MARK: status

    static func status() -> Int32 {
        guard let reply = send(["hook_event_name": .string("KongiStatus"), "session_id": .string("kongi")], expectsReply: true) else {
            FileHandle.standardError.write(Data("kongi: Kongi isn't running, or app notices are off\n".utf8))
            return 1
        }
        print(String(decoding: reply.encodedData(), as: UTF8.self))
        return 0
    }

    // MARK: codex

    /// Codex CLI의 `notify` 설정이 마지막 인자로 JSON을 넘깁니다 (턴이 끝났을 때).
    static func codex(_ args: [String]) -> Int32 {
        guard let text = args.last, let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              json["type"]?.stringValue == "agent-turn-complete" else { return 0 }
        let message = json["last-assistant-message"]?.stringValue?
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        send([
            "hook_event_name": .string("KongiNotify"), "session_id": .string("kongi"),
            "title": .string("Codex finished"), "detail": .string(String(message.prefix(120))),
            "symbol": .string("checkmark.circle.fill"), "source": .string("Codex"),
        ])
        return 0
    }

    // MARK: run

    /// 명령을 그대로 실행하고(출력도 그대로), 진행률·통과/실패 수·결과를 Kongi에 보냅니다. 종료 코드는 명령의 것.
    static func run(_ args: [String]) -> Int32 {
        var name: String?
        var rest = args[...]
        if rest.first == "--name", rest.count >= 2 {
            name = rest.dropFirst().first
            rest = rest.dropFirst(2)
        }
        if rest.first == "--" { rest = rest.dropFirst() }
        guard !rest.isEmpty else {
            FileHandle.standardError.write(Data("usage: kongi run [--name <label>] -- <command> [args…]\n".utf8))
            return 64
        }
        let command = Array(rest)
        let id = UUID().uuidString
        let label = name ?? command.joined(separator: " ")
        let cwd = FileManager.default.currentDirectoryPath
        let started = Date()

        // shortcut: 출력은 파이프로 받아서 도구가 색을 끌 수 있습니다. 색이 꼭 필요하면 pty로 바꿀 것.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let lock = NSLock()
        var progress = TaskProgress()
        var pending = ["", ""]
        var lastSent = Date.distantPast
        var dirty = false

        func report(_ state: String, code: Int32? = nil) {
            var fields: [String: JSONValue] = [
                "hook_event_name": .string("KongiTask"), "session_id": .string("kongi"),
                "id": .string(id), "name": .string(label), "cwd": .string(cwd), "state": .string(state),
                "passed": .number(Double(progress.passed)), "failed": .number(Double(progress.failed)),
                "seconds": .number(Date().timeIntervalSince(started)),
            ]
            if let fraction = progress.fraction { fields["fraction"] = .number(fraction) }
            if let code { fields["code"] = .number(Double(code)) }
            send(fields)
        }

        func pump(_ pipe: Pipe, into handle: FileHandle, slot: Int) {
            pipe.fileHandleForReading.readabilityHandler = { reader in
                let data = reader.availableData
                guard !data.isEmpty else { reader.readabilityHandler = nil; return }
                handle.write(data)
                lock.lock()
                defer { lock.unlock() }
                pending[slot] += String(decoding: data, as: UTF8.self)
                // 진행 막대는 \r로 같은 줄을 고쳐 쓰므로 \r도 줄 끝으로 봅니다.
                var lines = pending[slot].components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                pending[slot] = lines.removeLast()
                for line in lines where progress.read(line) { dirty = true }
                if pending[slot].count > 4000 { pending[slot] = "" }
                if dirty, Date().timeIntervalSince(lastSent) > 0.5 {
                    dirty = false
                    lastSent = Date()
                    report("running")
                }
            }
        }
        pump(out, into: .standardOutput, slot: 0)
        pump(err, into: .standardError, slot: 1)

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("kongi: couldn't run \(command[0])\n".utf8))
            return 127
        }
        // Ctrl-C는 터미널이 명령에도 보내므로, kongi는 남아서 결과를 알립니다.
        signal(SIGINT, SIG_IGN)
        report("running")
        process.waitUntilExit()
        // 남은 출력까지 읽은 뒤 결과를 보냅니다.
        for pipe in [out, err] {
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty {
                (pipe === out ? FileHandle.standardOutput : FileHandle.standardError).write(rest)
                lock.lock()
                String(decoding: rest, as: UTF8.self).components(separatedBy: CharacterSet(charactersIn: "\r\n")).forEach { progress.read($0) }
                lock.unlock()
            }
        }
        let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        lock.lock()
        report(code == 0 ? "succeeded" : "failed", code: code)
        lock.unlock()
        return code
    }
}
