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
    public var archiveURL: URL { archiveURL(ref: nil) }

    /// 정해진 커밋·태그의 zip (예전 Kongi에 맞는 예전 확장). 이상한 글자가 있으면 기본 브랜치로.
    public func archiveURL(ref: String?) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = ref.flatMap { $0.isEmpty || !$0.unicodeScalars.allSatisfy(allowed.contains) ? nil : $0 } ?? "HEAD"
        return URL(string: "https://codeload.github.com/\(owner)/\(repo)/zip/\(safe)")!
    }
    public var pageURL: URL { URL(string: "https://github.com/\(owner)/\(repo)")! }
    /// 설치 폴더 이름 (같은 저장소의 다른 폴더도 따로 설치)
    public var folderName: String { ([owner, repo] + path.split(separator: "/").map(String.init)).joined(separator: "--") }
}

/// 확장 폴더의 kongi-extension.json
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var version: String?
    /// 확장 폴더 안에서 계속 실행할 파일 (예: "main.sh"). 누를 때만 도는 actions만 있는 확장은 없어도 됩니다.
    public var run: String?
    /// 이벤트(세션 시작·완료·승인 요청, 빌드 끝 등)마다 실행할 파일. 이벤트 이름은 첫 인자, 내용은 stdin JSON.
    public var events: String?
    /// 지우기 직전에 한 번 실행할 파일 (설정 되돌리기 등)
    public var uninstall: String?
    /// 아일랜드에서 입력을 받아 실행하는 일 (입력 칸 + 선택지 → 결과, 복사·대화에 넣기)
    public var actions: [Action]?
    /// 이 확장이 돌아가는 가장 낮은 Kongi 버전 (예: "2.2.3"). 이보다 낮은 Kongi에서는 실행하지 않습니다.
    public var minKongi: String?
    /// 이 확장이 하는 일 (설치 전에 보여 줌): claude, files-read, files-write, network, processes, notifications
    public var permissions: [String]?

    /// 알려진 권한만, 정해진 순서로 (모르는 값은 "other"로 한 번)
    public static func knownPermissions(_ list: [String]?) -> [String] {
        let known = ["claude", "files-read", "files-write", "network", "processes", "notifications"]
        let given = Set(list ?? [])
        return known.filter(given.contains) + (given.subtracting(known).isEmpty ? [] : ["other"])
    }

    /// 확장이 보여 주는 글: "글" 하나 또는 언어별 {"en": "…", "ko": "…"}
    public struct LocalizedText: Codable, Equatable, Sendable {
        public var values: [String: String]

        public init(_ text: String) { values = ["": text] }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { values = ["": text] } else { values = try container.decode([String: String].self) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if values.count == 1, let text = values[""] { try container.encode(text) } else { try container.encode(values) }
        }

        /// 앱 언어(zh-Hans, pt-BR …) → 그 언어 → 앞 두 글자(pt) → 영어 → 아무거나
        public func text(_ language: String) -> String {
            values[language] ?? values[String(language.prefix(2))] ?? values["en"] ?? values[""] ?? values.values.sorted().first ?? ""
        }
    }

    public struct Action: Codable, Equatable, Sendable {
        public struct Choice: Codable, Equatable, Sendable {
            public var id: String
            public var title: LocalizedText
        }

        public var id: String
        public var title: LocalizedText
        public var placeholder: LocalizedText?
        /// 확장 폴더 안의 실행 파일. 입력은 stdin, 고른 것은 $KONGI_CHOICE, 결과는 stdout.
        public var run: String
        public var choiceTitle: LocalizedText?
        public var choices: [Choice]?
        /// 초 (기본 120, 최대 600)
        public var timeout: Double?
        /// 입력 칸 옆에 둘 것: "project" (프로젝트·대화 고르기), "files" (파일 첨부)
        public var context: [String]?
        /// false면 입력 칸 없이 화면을 열 때 바로 실행 (상태 보기 같은 일)
        public var input: Bool?
        /// "monospaced"면 결과를 고정폭 글꼴로 (표처럼 줄 맞춤)
        public var output: String?

        public var takesInput: Bool { input != false }
        public var monospaced: Bool { output == "monospaced" }

        public var wantsProject: Bool { context?.contains("project") == true }
        public var wantsFiles: Bool { context?.contains("files") == true }

        public init(id: String, title: LocalizedText, placeholder: LocalizedText? = nil, run: String,
                    choiceTitle: LocalizedText? = nil, choices: [Choice]? = nil, timeout: Double? = nil, context: [String]? = nil) {
            self.context = context
            self.id = id
            self.title = title
            self.placeholder = placeholder
            self.run = run
            self.choiceTitle = choiceTitle
            self.choices = choices
            self.timeout = timeout
        }
    }

    public init(name: String, description: String? = nil, version: String? = nil, run: String?, events: String? = nil, uninstall: String? = nil, actions: [Action]? = nil) {
        self.name = name
        self.description = description
        self.version = version
        self.run = run
        self.events = events
        self.uninstall = uninstall
        self.actions = actions
    }

    public static let fileName = "kongi-extension.json"

    /// 실행 파일이 확장 폴더 밖을 가리키지 못하게 합니다 (../, 절대 경로, 폴더 밖으로 가는 링크).
    public func executable(in folder: URL) -> URL? { file(run, in: folder) }

    /// 확장으로 쓸 수 있는지: 계속 도는 파일이 있거나, 모든 action의 파일이 폴더 안에 있음
    public func isRunnable(in folder: URL) -> Bool {
        let actions = actions ?? []
        guard executable(in: folder) != nil || !actions.isEmpty else { return false }
        return actions.allSatisfy { !$0.id.isEmpty && Self.file($0.run, in: folder) != nil }
    }

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
    /// 없으면 지난 요청 기록으로 (3개 이상일 때만, `fromPast`).
    public static func remaining(elapsed: Double, done: Int?, total: Int?, past: [Double]) -> Double? {
        if let done, let total, done > 0, done < total {
            return elapsed / Double(done) * Double(total - done)
        }
        guard past.count >= 3 else { return nil }
        return fromPast(elapsed: elapsed, past: past)
    }

    /// 지금까지 걸린 시간보다 오래 걸렸던 지난 기록만 보고(가운데값) 남은 시간.
    /// 전체 가운데값만 쓰면 평소보다 긴 일은 금방 어림이 사라져, 긴 일일수록 남은 시간이 안 보였습니다.
    /// 그보다 오래 걸린 기록이 없으면 nil (평소보다 오래 걸리는 중, 지어내지 않음).
    public static func fromPast(elapsed: Double, past: [Double]) -> Double? {
        let longer = past.filter { $0 > elapsed + 15 }.sorted()
        guard !longer.isEmpty else { return nil }
        return longer[longer.count / 2] - elapsed
    }
}

/// 확장의 일에 넘기는 맥락 ($KONGI_CONTEXT가 가리키는 JSON 파일)
public struct ActionContext: Codable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var text: String
        public init(role: String, text: String) { self.role = role; self.text = text }
    }

    public struct Answer: Codable, Equatable, Sendable {
        public var question: String
        public var answer: String
        public init(question: String, answer: String) { self.question = question; self.answer = answer }
    }

    public var language: String
    /// 고른 프로젝트 폴더
    public var project: String?
    /// 고른 대화의 제목, 최근 말 (오래된 것부터), 이 대화에서 바꾼 파일
    public var conversation: String?
    public var messages: [Message]
    public var changedFiles: [String]
    /// 첨부한 파일 (절대 경로)
    public var files: [String]
    /// 앞서 확장이 물은 질문과 사용자의 답
    public var answers: [Answer]
    /// 사용자가 "건너뛰기"를 눌렀음: 더 묻지 말고 바로 결과를
    public var skipQuestions: Bool

    public init(language: String, project: String? = nil, conversation: String? = nil, messages: [Message] = [],
                changedFiles: [String] = [], files: [String] = [], answers: [Answer] = [], skipQuestions: Bool = false) {
        self.language = language
        self.project = project
        self.conversation = conversation
        self.messages = messages
        self.changedFiles = changedFiles
        self.files = files
        self.answers = answers
        self.skipQuestions = skipQuestions
    }
}

/// 확장의 일이 돌려준 것: 결과 글, 또는 더 알아야 할 질문들
/// (stdout이 {"questions": [{"question": "…", "options": ["…"]}]} 모양의 JSON이면 질문)
public enum ActionOutput: Equatable, Sendable {
    public struct Question: Codable, Equatable, Sendable {
        public var question: String
        public var options: [String]?
        /// 보기를 여러 개 고름 (답은 고른 보기를 줄바꿈으로 이은 것)
        public var multiSelect: Bool?
        /// 확인 단추 이름 (예: "삭제"). 첫 질문의 것을 씁니다.
        public var confirm: String?

        public init(question: String, options: [String]? = nil, multiSelect: Bool? = nil, confirm: String? = nil) {
            self.question = question
            self.options = options
            self.multiSelect = multiSelect
            self.confirm = confirm
        }
    }

    case text(String)
    case questions([Question])
    /// {"result": "…", "note": "…"}: 결과 글과 그 아래 작은 메모 (예: 실제로 쓴 모델)
    case result(String, note: String)

    public static let maxQuestions = 3

    public static func parse(_ output: String) -> ActionOutput {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 모델이 ```json … ``` 으로 감싸는 경우도 받아 줍니다.
        var body = trimmed
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        struct Wrapper: Decodable { var questions: [Question] }
        struct Noted: Decodable { var result: String; var note: String? }
        if body.hasPrefix("{"), let noted = try? JSONDecoder().decode(Noted.self, from: Data(body.utf8)) {
            // 감싼 결과가 질문이면 질문으로 (메모는 버림)
            if case .questions = parse(noted.result) { return parse(noted.result) }
            let note = noted.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return note.isEmpty ? .text(noted.result) : .result(noted.result, note: note)
        }
        if body.hasPrefix("{"), let wrapper = try? JSONDecoder().decode(Wrapper.self, from: Data(body.utf8)) {
            let questions = wrapper.questions
                .filter { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(maxQuestions)
                .map { Question(question: $0.question, options: $0.options.map { Array($0.prefix(12)) },
                                multiSelect: $0.multiSelect, confirm: $0.confirm.map { String($0.prefix(30)) }) }
            if !questions.isEmpty { return .questions(Array(questions)) }
        }
        return .text(trimmed)
    }
}

/// 마켓플레이스에 올린 확장의 한 버전: 필요한 Kongi 버전과, 그 버전을 받을 커밋(없으면 최신)
public struct CatalogVersion: Codable, Equatable, Sendable {
    public var version: String
    public var minKongi: String?
    public var ref: String?
    /// 이 버전에서 바뀐 것 (언어별 가능, 버전 기록에 보임)
    public var notes: ExtensionManifest.LocalizedText?

    public init(version: String, minKongi: String? = nil, ref: String? = nil, notes: ExtensionManifest.LocalizedText? = nil) {
        self.version = version
        self.minKongi = minKongi
        self.ref = ref
        self.notes = notes
    }
}

/// Kongi 버전에 맞는 확장 버전 고르기
public enum ExtensionCompatibility {
    /// 이 Kongi에서 돌아가는지 (개발 빌드처럼 버전을 모르면 돌아간다고 봄)
    public static func runs(minKongi: String?, on app: String) -> Bool {
        guard let minKongi, !minKongi.isEmpty else { return true }
        return !AppUpdate.isNewer(minKongi, than: app)
    }

    /// 버전 기록 화면 순서: 새 것부터
    public static func newestFirst(_ versions: [CatalogVersion]) -> [CatalogVersion] {
        versions.sorted { AppUpdate.isNewer($0.version, than: $1.version) }
    }

    /// 이 Kongi에서 돌아가는 가장 새 버전
    public static func best(_ versions: [CatalogVersion], on app: String) -> CatalogVersion? {
        versions.filter { runs(minKongi: $0.minKongi, on: app) }
            .max { AppUpdate.isNewer($1.version, than: $0.version) }
    }
}
