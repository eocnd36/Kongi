import Foundation

/// `kongi run -- <명령>`의 출력에서 진행률과 통과·실패 수를 읽습니다 (빌드·테스트 스코어보드).
/// 도구마다 형식이 달라 흔한 모양만 봅니다: "42%", cargo의 "running N tests"와 "test x ... ok",
/// jest·vitest·pytest의 요약 "N passed, M failed".
public struct TaskProgress: Equatable, Sendable {
    /// 0…1. 알 수 없으면 nil (빙글 도는 링)
    public var fraction: Double?
    public var passed: Int { donePassed + livePassed }
    public var failed: Int { doneFailed + liveFailed }

    // cargo는 묶음(크레이트)마다 "running N tests" → 줄마다 결과 → "test result:" 요약을 냅니다.
    private var donePassed = 0, doneFailed = 0
    private var livePassed = 0, liveFailed = 0
    private var expected = 0, seen = 0

    public init() {}

    private static let percent = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,3}(?:\.\d+)?)\s?%"#)
    private static let passedCount = try! NSRegularExpression(pattern: #"(\d+) (?:passed|passing)"#)
    private static let failedCount = try! NSRegularExpression(pattern: #"(\d+) (?:failed|failing)"#)
    private static let running = try! NSRegularExpression(pattern: #"^running (\d+) tests?$"#)
    private static let testLine = try! NSRegularExpression(pattern: #"^test .+ \.\.\. (ok|FAILED|ignored)$"#)

    /// 출력 한 줄을 읽고 바뀐 게 있으면 true
    @discardableResult
    public mutating func read(_ rawLine: String) -> Bool {
        // 색 코드(ESC[…m)와 앞뒤 공백은 지우고 봅니다.
        let line = rawLine.replacingOccurrences(of: #"\u{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count < 2000 else { return false }
        let before = self

        if let n = Self.number(Self.running, in: line) {
            expected += n
        } else if let result = Self.capture(Self.testLine, in: line) {
            if result == "ok" { livePassed += 1 } else if result == "FAILED" { liveFailed += 1 }
            seen += 1
            if expected > 0 { fraction = min(Double(seen) / Double(expected), 1) }
        } else if line.hasPrefix("test result:") {
            // 이 묶음의 요약: 줄마다 센 값을 요약 값으로 바꿉니다.
            donePassed += Self.number(Self.passedCount, in: line) ?? livePassed
            doneFailed += Self.number(Self.failedCount, in: line) ?? liveFailed
            livePassed = 0
            liveFailed = 0
        } else if let p = Self.number(Self.passedCount, in: line), line.lowercased().contains("test") || line.contains("passed") {
            // jest·vitest·pytest 요약은 전체 수를 한 줄에 줍니다.
            donePassed = p
            doneFailed = Self.number(Self.failedCount, in: line) ?? 0
            livePassed = 0
            liveFailed = 0
        } else if let value = Self.lastPercent(in: line) {
            fraction = value / 100
        }
        return self != before
    }

    private static func number(_ regex: NSRegularExpression, in line: String) -> Int? {
        capture(regex, in: line).flatMap { Int($0) }
    }

    private static func capture(_ regex: NSRegularExpression, in line: String) -> String? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[group])
    }

    private static func lastPercent(in line: String) -> Double? {
        guard let match = percent.matches(in: line, range: NSRange(line.startIndex..., in: line)).last,
              let group = Range(match.range(at: 1), in: line),
              let value = Double(line[group]), value <= 100 else { return nil }
        return value
    }
}

/// 확장(익스텐션) 설치 주소: "owner/repo" 또는 "owner/repo/하위/폴더", github.com 주소도 받습니다.
public struct ExtensionSource: Equatable, Sendable {
    public var owner: String
    public var repo: String
    public var path: String

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        var parts = value.split(separator: "/").map(String.init)
        // 브라우저 주소의 /tree/<브랜치>/ 는 기본 브랜치만 받으므로 떼어 냅니다.
        if parts.count >= 4, parts[2] == "tree" { parts.removeSubrange(2...3) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        owner = parts[0]
        repo = parts[1]
        path = parts.dropFirst(2).joined(separator: "/")
    }

    /// 기본 브랜치의 zip
    public var archiveURL: URL { URL(string: "https://codeload.github.com/\(owner)/\(repo)/zip/HEAD")! }
    public var pageURL: URL { URL(string: "https://github.com/\(owner)/\(repo)")! }
    /// 설치 폴더 이름 (같은 저장소의 다른 폴더도 따로 설치)
    public var folderName: String { ([owner, repo] + path.split(separator: "/").map(String.init)).joined(separator: "--") }
}

/// 확장 폴더의 kongi-extension.json
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var version: String?
    /// 확장 폴더 안에서 실행할 파일 (예: "main.sh")
    public var run: String
    /// 이벤트(세션 시작·완료·승인 요청, 빌드 끝 등)마다 실행할 파일. 이벤트 이름은 첫 인자, 내용은 stdin JSON.
    public var events: String?
    /// 지우기 직전에 한 번 실행할 파일 (설정 되돌리기 등)
    public var uninstall: String?

    public init(name: String, description: String? = nil, version: String? = nil, run: String, events: String? = nil, uninstall: String? = nil) {
        self.name = name
        self.description = description
        self.version = version
        self.run = run
        self.events = events
        self.uninstall = uninstall
    }

    public static let fileName = "kongi-extension.json"

    /// 실행 파일이 확장 폴더 밖을 가리키지 못하게 합니다 (../, 절대 경로, 폴더 밖으로 가는 링크).
    public func executable(in folder: URL) -> URL? { Self.file(run, in: folder) }

    /// events·uninstall도 같은 규칙으로 (없으면 nil)
    public func file(_ path: String?, in folder: URL) -> URL? { path.flatMap { Self.file($0, in: folder) } }

    static func file(_ run: String, in folder: URL) -> URL? {
        guard !run.isEmpty, !run.hasPrefix("/"), !run.split(separator: "/").contains("..") else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let file = folder.appendingPathComponent(run).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// 압축을 푼 폴더에 밖을 가리키는 링크나 이상한 파일이 있는지 (설치 전에 확인)
    public static func isSafeTree(_ folder: URL) -> Bool {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else { return false }
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                let target = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard target.hasPrefix(root + "/") else { return false }
            } else if values?.isRegularFile != true, values?.isDirectory != true {
                return false
            }
        }
        return true
    }
}

/// 일하는 중인 요청의 남은 시간 어림 (초). 근거가 없으면 nil.
public enum TurnEstimate {
    /// 할 일 목록이 있으면 진행률로 (끝난 하나당 걸린 시간 × 남은 수),
    /// 없으면 지난 요청 시간의 가운데값에서 지금까지 걸린 시간을 뺀 것 (지난 요청이 3개 이상일 때만).
    public static func remaining(elapsed: Double, done: Int?, total: Int?, past: [Double]) -> Double? {
        if let done, let total, done > 0, done < total {
            return elapsed / Double(done) * Double(total - done)
        }
        guard past.count >= 3 else { return nil }
        let left = past.sorted()[past.count / 2] - elapsed
        return left > 15 ? left : nil
    }
}
