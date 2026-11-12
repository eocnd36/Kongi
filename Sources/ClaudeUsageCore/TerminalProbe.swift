import Foundation

/// 훅이 실행된 터미널을 찾아 "해당 터미널로 이동"에 쓸 정보를 모읍니다.
public enum TerminalProbe {
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> HookContext {
        let process = claudeProcess()
        return HookContext(
            termProgram: environment["TERM_PROGRAM"],
            bundleId: environment["__CFBundleIdentifier"],
            tty: process?.tty,
            termSessionId: environment["TERM_SESSION_ID"],
            itermSessionId: environment["ITERM_SESSION_ID"],
            claudePid: process?.pid,
            entrypoint: environment["CLAUDE_CODE_ENTRYPOINT"]
        )
    }

    struct ProcessRow: Equatable {
        var pid: Int32
        var ppid: Int32
        var tty: String
        var command: String
    }

    static func parse(psOutput: String) -> [Int32: ProcessRow] {
        var rows: [Int32: ProcessRow] = [:]
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            rows[pid] = ProcessRow(pid: pid, ppid: ppid, tty: String(parts[2]), command: String(parts[3]))
        }
        return rows
    }

    /// 부모 프로세스를 따라 올라가며 Claude Code 프로세스(claude 또는 node)와 그 터미널을 찾습니다.
    static func findClaude(from pid: Int32, in rows: [Int32: ProcessRow]) -> (pid: Int32, tty: String?)? {
        var current = pid
        var firstTTY: String?
        for _ in 0..<12 {
            guard let row = rows[current] else { break }
            let hasTTY = row.tty != "??" && !row.tty.isEmpty
            if hasTTY, firstTTY == nil { firstTTY = "/dev/" + row.tty }
            let name = (row.command as NSString).lastPathComponent.lowercased()
            if name.contains("claude") || name == "node" || name.hasPrefix("codex") {
                return (row.pid, hasTTY ? "/dev/" + row.tty : firstTTY)
            }
            current = row.ppid
            if current <= 1 { break }
        }
        return firstTTY.map { (getppid(), $0) }
    }

    private static func claudeProcess() -> (pid: Int32, tty: String?)? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,tty=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return findClaude(from: getppid(), in: parse(psOutput: String(decoding: data, as: UTF8.self)))
    }
}
