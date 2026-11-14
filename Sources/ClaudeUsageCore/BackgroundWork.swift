import Darwin
import Foundation

/// Claude Code가 Bash 도구로 띄운 셸 중, 대답이 끝난 뒤에도 돌고 있는 것 (백그라운드 빌드·테스트·서버 등).
/// Claude Code는 명령마다 `zsh -c source ~/.claude/shell-snapshots/… && eval '<명령>' < /dev/null && pwd -P >| …`를
/// Claude 프로세스의 자식으로 띄웁니다. 언어 서버·MCP 서버·훅 도우미는 이 모양이 아니라 섞이지 않습니다.
public enum BackgroundWork {
    public struct Job: Equatable, Sendable {
        public var pid: Int32
        public var label: String
        public var startedAt: Date
        /// 출력이 파일로 가면 그 경로 (Claude Code의 백그라운드 명령은 tasks/<id>.output에 씀)
        public var outputPath: String?

        public init(pid: Int32, label: String, startedAt: Date, outputPath: String? = nil) {
            self.pid = pid
            self.label = label
            self.startedAt = startedAt
            self.outputPath = outputPath
        }
    }

    public static let maxLabel = 60

    /// 셸 명령 줄에서 사람이 알아볼 이름: 마지막 명령 (cd·파이프 뒤·리디렉션은 뺌). Claude Code 셸이 아니면 nil.
    public static func label(fromShellCommand command: String) -> String? {
        guard command.contains("/.claude/shell-snapshots/"), let open = command.range(of: "eval '") else { return nil }
        var body = String(command[open.upperBound...])
        if let close = body.range(of: "' < /dev/null", options: .backwards) ?? body.range(of: "'", options: .backwards) {
            body = String(body[..<close.lowerBound])
        }
        body = body.replacingOccurrences(of: "'\\''", with: "'")
        let statements = body
            .replacingOccurrences(of: "&&", with: ";")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("cd ") }
        guard var last = statements.last else { return nil }
        for cut in [" | ", " 2>&1", " >", " &"] {
            if let range = last.range(of: cut) { last = String(last[..<range.lowerBound]) }
        }
        last = last.trimmingCharacters(in: .whitespaces)
        guard !last.isEmpty else { return nil }
        return last.count > maxLabel ? String(last.prefix(maxLabel - 1)) + "…" : last
    }

    /// parent(Claude 프로세스) 바로 아래에서 도는 Claude Code 셸들
    public static func jobs(under parent: Int32) -> [Job] {
        let type = UInt32(PROC_PPID_ONLY)
        let estimate = proc_listpids(type, UInt32(parent), nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) / MemoryLayout<Int32>.size + 16)
        let bytes = proc_listpids(type, UInt32(parent), &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { $0 > 0 }.compactMap { pid in
            guard let command = arguments(of: pid), let label = label(fromShellCommand: command) else { return nil }
            return Job(pid: pid, label: label, startedAt: startTime(of: pid) ?? Date(), outputPath: outputPath(of: pid))
        }
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// 표준 출력(fd 1)이 일반 파일이면 그 경로
    static func outputPath(of pid: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, 1, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") && !path.hasPrefix("/dev/") ? path : nil
    }

    /// 출력 파일 끝부분의 진행률 (0…1, 모르면 nil): "42%", 테스트 수, "[12/40]" 같은 줄
    public static func progress(ofOutputAt path: String, tail: Int = 16 * 1024) -> Double? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return progress(ofOutput: text)
    }

    static func progress(ofOutput text: String) -> Double? {
        var progress = TaskProgress()
        var fraction: Double?
        // 진행 표시줄은 \r로 같은 줄을 덮어씁니다.
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(line)
            progress.read(line)
            fraction = progress.fraction ?? fraction
            if let step = Self.step(in: line) { fraction = step }
        }
        guard let fraction, fraction > 0, fraction < 1 else { return nil }
        return fraction
    }

    private static let stepPattern = try! NSRegularExpression(pattern: #"(?:^|[\s\[(])(\d{1,6})\s?/\s?(\d{1,6})(?=$|[\s\])])"#)

    /// "[12/40]", "(3 / 10)", "step 4/9" 같은 진행 (날짜·경로는 앞뒤 글자로 거름)
    static func step(in line: String) -> Double? {
        guard let match = stepPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).last,
              let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line),
              let done = Double(line[a]), let total = Double(line[b]), total >= 2, done <= total else { return nil }
        return done / total
    }

    /// 진행률로 남은 시간 (너무 이른 진행률은 믿지 않음)
    public static func remaining(elapsed: Double, fraction: Double) -> Double? {
        guard fraction >= 0.02, fraction < 1, elapsed > 5 else { return nil }
        return elapsed / fraction * (1 - fraction)
    }

    /// 같은 명령으로 보는 이름: 숫자는 버전·날짜마다 바뀌어 지움 (v32 → v#)
    public static func historyKey(_ label: String) -> String {
        label.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
    }

    /// 프로세스의 인자 전체 (내 프로세스의 자식만 읽을 수 있으면 됨: 같은 사용자)
    static func arguments(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // argc 다음: 실행 파일 경로, 빈 바이트들, 인자들(각각 0으로 끝남)
        let parts = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().prefix(Int(argc)).joined(separator: " ")
    }

    /// 같은 명령이 예전에 걸린 시간(가운데값)으로 남은 시간. 기록이 없거나 이미 넘겼으면 nil.
    public static func remaining(elapsed: Double, past: [Double]) -> Double? {
        TurnEstimate.fromPast(elapsed: elapsed, past: past)
    }

    /// 여러 일을 한눈에: 가장 오래 일한 시간과, 모두 끝나기까지의 시간 (하나라도 모르면 nil)
    public static func overall(_ items: [(elapsed: Double, remaining: Double?)]) -> (elapsed: Double, remaining: Double?)? {
        guard let longest = items.map(\.elapsed).max() else { return nil }
        let known = items.compactMap(\.remaining)
        return (longest, known.count == items.count ? known.max() : nil)
    }
}
