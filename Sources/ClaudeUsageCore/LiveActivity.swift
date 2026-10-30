import Foundation

// MARK: - 고치는 중인 내용 미리 보기

/// Claude가 파일을 고치기 직전(PreToolUse), 도구 입력을 원래 내용에 적용해 이번 단계의 변경을 미리 계산합니다.
/// 승인 요청에서도 "무엇이 바뀌는지"를 바로 보여 줄 수 있습니다.
public enum EditPreview {
    /// 고친 뒤의 내용. 적용할 수 없으면(찾는 글자가 없음, 지원하지 않는 도구) nil.
    public static func predictedContent(toolName: String?, input: JSONValue?, original: String?) -> String? {
        switch toolName {
        case "Write":
            return input?["content"]?.stringValue
        case "Edit":
            guard let original, let input else { return nil }
            return apply(input, to: original)
        case "MultiEdit":
            guard var text = original, case let .array(edits)? = input?["edits"] else { return nil }
            for edit in edits {
                guard let next = apply(edit, to: text) else { return nil }
                text = next
            }
            return text
        default:
            return nil
        }
    }

    private static func apply(_ edit: JSONValue, to text: String) -> String? {
        guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue else { return nil }
        if old.isEmpty { return text.isEmpty ? new : nil }
        guard let range = text.range(of: old) else { return nil }
        if edit["replace_all"]?.boolValue == true {
            return text.replacingOccurrences(of: old, with: new)
        }
        return text.replacingCharacters(in: range, with: new)
    }

    /// 이번 단계의 diff (아일랜드에 바로 띄울 만큼만)
    public static func diff(toolName: String?, input: JSONValue?, original: String?, context: Int = 2, maxLines: Int = 80) -> LineDiff? {
        guard let new = predictedContent(toolName: toolName, input: input, original: original) else { return nil }
        let diff = LineDiff.compute(old: original, new: new, context: context)
        guard diff.added + diff.removed > 0 else { return nil }
        return diff.limited(maxLines: maxLines)
    }
}

extension LineDiff {
    /// 앞에서부터 줄 수를 제한합니다 (기록이 너무 커지지 않도록). 잘렸으면 truncated.
    public func limited(maxLines: Int) -> LineDiff {
        var remaining = maxLines
        var kept: [Hunk] = []
        var cut = false
        for hunk in hunks {
            if remaining == 0 {
                cut = true
                break
            }
            if hunk.lines.count <= remaining {
                kept.append(hunk)
                remaining -= hunk.lines.count
            } else {
                kept.append(Hunk(lines: Array(hunk.lines.prefix(remaining))))
                remaining = 0
                cut = true
            }
        }
        return LineDiff(added: added, removed: removed, hunks: kept, truncated: truncated || cut)
    }
}

// MARK: - 대화 기록(transcript)에서 Claude의 말 읽기

/// Claude Code가 남기는 대화 기록(JSONL)에서 사용자가 쓴 말과 Claude가 쓴 글만 이어서 읽습니다.
/// 훅에는 중간 설명이 오지 않아서, 실시간으로 "무슨 생각으로 무엇을 하는지"를 보여 주려면 이 파일을 읽어야 합니다.
public enum TranscriptReader {
    public struct Message: Equatable, Sendable {
        public enum Role: String, Sendable { case user, assistant }

        public var id: String
        public var date: Date
        public var role: Role
        public var text: String
    }

    /// 처음 읽을 때는 파일 끝부분만 봅니다 (긴 대화는 수십 MB). 도구 결과가 커서 넉넉히 읽습니다.
    public static let initialTail = 3 * 1024 * 1024
    public static let maxText = 20000

    /// 읽은 부분의 마지막 상태: 차례가 끝났는지, 사용자가 멈췄는지 (훅 이벤트를 놓쳤을 때 상태를 바로잡는 데 씀)
    public enum TurnState: Equatable, Sendable {
        case ended(Date)
        case interrupted(Date)
        case continuing
    }

    /// offset부터 새로 추가된 줄을 읽습니다. 돌려준 offset은 마지막 완전한 줄 다음 위치입니다.
    public static func read(_ url: URL, from offset: UInt64?) -> (offset: UInt64, messages: [Message]) {
        let result = readWithTurn(url, from: offset)
        return (result.offset, result.messages)
    }

    /// 새 줄이 없으면 turn은 nil (모름)
    public static func readWithTurn(_ url: URL, from offset: UInt64?) -> (offset: UInt64, messages: [Message], turn: TurnState?, branch: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (offset ?? 0, [], nil, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offset ?? (size > UInt64(initialTail) ? size - UInt64(initialTail) : 0)
        if start > size { start = 0 } // 파일이 새로 만들어졌으면 처음부터
        guard size > start else { return (start, [], nil, nil) }
        try? handle.seek(toOffset: start)
        // 한 번에 너무 많이 읽지 않도록 (대화 기록이 갑자기 크게 늘어난 경우)
        let data = handle.readData(ofLength: Int(min(size - start, 8 * 1024 * 1024)))
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return (start, [], nil, nil) }
        var body = data[data.startIndex...lastNewline]
        // 중간부터 읽기 시작했으면 잘린 첫 줄은 버립니다.
        if offset == nil, start > 0, let firstNewline = body.firstIndex(of: 0x0A) {
            body = body[body.index(after: firstNewline)...]
        }
        let lines = body.split(separator: 0x0A).map { Data($0) }
        let messages = lines.compactMap(parse)
        var turn: TurnState?
        for line in lines { if let state = turnState(line) { turn = state } }
        // 대화 기록 줄마다 그때의 git 브랜치가 적혀 있습니다 (마지막 것).
        let branch = lines.reversed().lazy.compactMap { line -> String? in
            guard let range = line.range(of: Data(#""gitBranch":""#.utf8)) else { return nil }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: 0x22) else { return nil }
            let value = String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
            return value.isEmpty ? nil : value
        }.first
        return (start + UInt64(data.distance(from: data.startIndex, to: lastNewline)) + 1, messages, turn, branch)
    }

    /// 한 줄이 차례의 진행에 대해 알려 주는 것
    static func turnState(_ line: Data) -> TurnState? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: line),
              json["isSidechain"]?.boolValue != true else { return nil }
        let date = json["timestamp"]?.stringValue.flatMap { dateFormatter.date(from: $0) } ?? Date()
        switch json["type"]?.stringValue {
        case "assistant":
            switch json["message"]?["stop_reason"]?.stringValue {
            case "end_turn", "stop_sequence", "max_tokens": return .ended(date)
            case "tool_use": return .continuing
            default: return nil
            }
        case "user":
            let content = json["message"]?["content"]
            let texts: [String]
            if let text = content?.stringValue { texts = [text] }
            else if case let .array(blocks)? = content { texts = blocks.compactMap { $0["text"]?.stringValue } }
            else { texts = [] }
            if texts.contains(where: { $0.hasPrefix("[Request interrupted") }) { return .interrupted(date) }
            return json["isMeta"]?.boolValue == true ? nil : .continuing
        default:
            return nil
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ line: Data) -> Message? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: line),
              json["isSidechain"]?.boolValue != true, json["isMeta"]?.boolValue != true else { return nil }
        let role: Message.Role
        switch json["type"]?.stringValue {
        case "assistant": role = .assistant
        case "user": role = .user
        default: return nil
        }
        let content = json["message"]?["content"]
        var parts: [String] = []
        if let text = content?.stringValue {
            parts = [text]
        } else if case let .array(blocks)? = content {
            parts = blocks.compactMap { block in
                block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
            }
        }
        if role == .user {
            // IDE가 덧붙인 선택 영역, 시스템 안내, 명령 출력 같은 것은 사용자가 쓴 말이 아닙니다.
            parts = parts.map(stripTags).filter { part in
                !part.isEmpty && !part.hasPrefix("<") && !part.hasPrefix("[Request interrupted")
                    && !part.hasPrefix("Caveat:") && !part.hasPrefix("This session is being continued")
            }
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let date = json["timestamp"]?.stringValue.flatMap { dateFormatter.date(from: $0) } ?? Date()
        return Message(
            id: json["uuid"]?.stringValue ?? UUID().uuidString,
            date: date,
            role: role,
            text: text.count > maxText ? String(text.prefix(maxText)) + "…" : text
        )
    }

    /// <system-reminder>…</system-reminder> 같은 덧붙은 블록을 지웁니다.
    static func stripTags(_ text: String) -> String {
        var result = text
        while let open = result.range(of: #"<([a-z_-]+)[^>]*>"#, options: .regularExpression) {
            let tag = result[open].dropFirst().prefix { $0.isLetter || $0 == "_" || $0 == "-" }
            guard let close = result.range(of: "</\(tag)>", range: open.upperBound..<result.endIndex) else { break }
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
