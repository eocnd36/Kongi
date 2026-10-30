import Foundation

/// 두 텍스트의 줄 단위 차이 (+N / −N과 변경된 부분 주변만 보여 주는 hunk)
public struct LineDiff: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case context, added, removed }

        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
    }

    public struct Hunk: Codable, Equatable, Sendable {
        public var lines: [Line]
    }

    public var added: Int
    public var removed: Int
    public var hunks: [Hunk]
    /// 파일이 너무 커서 줄 비교를 생략했는지
    public var truncated: Bool

    public static let empty = LineDiff(added: 0, removed: 0, hunks: [], truncated: false)

    /// 이보다 줄이 많으면 차이 계산이 느려지므로 줄 수만 셉니다.
    public static let maxLines = 6000

    public static func lines(of text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        // 끝의 줄바꿈 때문에 생기는 빈 줄은 줄로 세지 않습니다.
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    public static func compute(old: String?, new: String?, context: Int = 3) -> LineDiff {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        if oldLines == newLines { return .empty }

        guard oldLines.count + newLines.count <= maxLines * 2 else {
            // 대략적인 값: 공통 줄을 빼고 셉니다.
            let common = Set(oldLines).intersection(newLines).count
            return LineDiff(
                added: max(newLines.count - common, 0),
                removed: max(oldLines.count - common, 0),
                hunks: [],
                truncated: true
            )
        }

        let difference = newLines.difference(from: oldLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removedOffsets.insert(offset)
            case let .insert(offset, _, _): insertedOffsets.insert(offset)
            }
        }

        // 두 문서를 나란히 걸으며 한 줄씩 합칩니다.
        var merged: [Line] = []
        var i = 0
        var j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removedOffsets.contains(i) {
                merged.append(Line(kind: .removed, text: oldLines[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            } else if j < newLines.count, insertedOffsets.contains(j) {
                merged.append(Line(kind: .added, text: newLines[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                merged.append(Line(kind: .context, text: oldLines[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1
                j += 1
            } else {
                break
            }
        }

        return LineDiff(
            added: insertedOffsets.count,
            removed: removedOffsets.count,
            hunks: hunks(from: merged, context: context),
            truncated: false
        )
    }

    private static func hunks(from lines: [Line], context: Int) -> [Hunk] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }

        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(index - context, 0)...min(index + context, lines.count - 1)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { Hunk(lines: Array(lines[$0])) }
    }
}
