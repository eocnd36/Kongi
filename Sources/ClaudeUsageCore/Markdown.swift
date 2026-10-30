import Foundation

/// Claude의 대답을 문단·제목·목록·표·코드 블록으로 나눕니다. 굵게·기울임·`코드` 같은 줄 안의 꾸밈은
/// 화면 쪽(AttributedString)이 맡고, 여기서는 줄 단위 구조만 봅니다. 안드로이드 앱의 Markdown.kt와 같은 규칙입니다.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String, text: String)
    case quote(String)
    case table(MarkdownTable)
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    /// 들여쓰기 깊이 (0부터)
    public var depth: Int
    /// 번호 목록이면 번호, 글머리표면 nil
    public var number: Int?
    /// 할 일 목록 ([ ] / [x])이면 체크 여부
    public var checked: Bool?
    public var text: String

    public init(depth: Int, number: Int?, checked: Bool?, text: String) {
        self.depth = depth
        self.number = number
        self.checked = checked
        self.text = text
    }
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Sendable { case leading, center, trailing }

    public var header: [String]
    public var alignments: [Alignment]
    /// 각 줄은 머리글과 칸 수가 같습니다 (모자라면 빈칸, 넘치면 버림).
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

public enum Markdown {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = Self.fence(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1 // 닫는 울타리 (없으면 끝까지)
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                continue
            }

            if let heading = Self.heading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if Self.isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count, trimmed.contains("|"), let alignments = Self.separator(lines[index + 1]) {
                let header = Self.cells(trimmed)
                if header.count == alignments.count {
                    var rows: [[String]] = []
                    index += 2
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|") else { break }
                        var cells = Self.cells(row)
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        index += 1
                    }
                    blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var rest = current.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if Self.listItem(line) != nil {
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = Self.listItem(current) {
                        items.append(item)
                        index += 1
                    } else if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        // 빈 줄 다음에도 목록이 이어지면 같은 목록
                        guard index + 1 < lines.count, Self.listItem(lines[index + 1]) != nil else { break }
                        index += 1
                    } else if current.hasPrefix("  ") || current.hasPrefix("\t"), !items.isEmpty {
                        // 들여 쓴 다음 줄은 앞 항목에 이어 붙입니다.
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let current = lines[index]
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                if currentTrimmed.isEmpty { break }
                if !paragraph.isEmpty, Self.startsBlock(current, next: index + 1 < lines.count ? lines[index + 1] : nil) { break }
                paragraph.append(currentTrimmed)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: Pieces

    private static func fence(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // 끝에 붙은 # 장식은 뗍니다.
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// 표의 구분 줄 (| --- | :---: |)이면 칸마다 정렬을 돌려줍니다.
    private static func separator(_ line: String) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespaces)
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        // 칸이 하나뿐이면 양쪽 |가 있어야 표로 봅니다 (그냥 "---" 줄과 구분).
        if result.count == 1, !(trimmed.hasPrefix("|") || trimmed.hasSuffix("|")) { return nil }
        return result
    }

    /// 표 한 줄을 칸으로 나눕니다. `\|`와 `코드` 안의 |는 칸 구분이 아닙니다.
    static func cells(_ row: String) -> [String] {
        var text = Substring(row.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text = text.dropLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 4 } else { break }
        }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        var number: Int?
        var body: Substring
        if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
            body = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count) else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
            number = Int(digits)
            body = after.dropFirst(2)
        }
        var checked: Bool?
        if body.hasPrefix("[ ] ") {
            checked = false
            body = body.dropFirst(4)
        } else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
            checked = true
            body = body.dropFirst(4)
        }
        return MarkdownListItem(depth: min(spaces / 2, 4), number: number, checked: checked, text: body.trimmingCharacters(in: .whitespaces))
    }

    /// 문단을 끊고 새 덩어리가 시작되는 줄인지
    private static func startsBlock(_ line: String, next: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if fence(trimmed) != nil || heading(trimmed) != nil || trimmed.hasPrefix(">") || listItem(line) != nil { return true }
        if isRule(trimmed) { return true }
        if trimmed.contains("|"), let next, separator(next) != nil { return true }
        return false
    }
}
