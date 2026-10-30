import Testing
@testable import ClaudeUsageCore

@Suite struct MarkdownTests {
    @Test func splitsHeadingsParagraphsAndRules() {
        let blocks = Markdown.parse("## 요약 ##\n첫 줄\n둘째 줄\n\n---\n끝")
        #expect(blocks == [
            .heading(level: 2, text: "요약"),
            .paragraph("첫 줄\n둘째 줄"),
            .rule,
            .paragraph("끝"),
        ])
    }

    @Test func readsTables() {
        let text = """
        결과:
        | 파일 | 줄 | 상태 |
        |:--|:-:|--:|
        | `a|b.swift` | 12 | ✅ |
        | c.kt | 3 |
        """
        let blocks = Markdown.parse(text)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .paragraph("결과:"))
        guard case let .table(table) = blocks[1] else {
            Issue.record("표가 아님: \(blocks[1])")
            return
        }
        #expect(table.header == ["파일", "줄", "상태"])
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.rows == [["`a|b.swift`", "12", "✅"], ["c.kt", "3", ""]])
    }

    @Test func pipesWithoutSeparatorStayText() {
        #expect(Markdown.parse("a | b\nc | d") == [.paragraph("a | b\nc | d")])
    }

    @Test func readsListsWithDepthNumbersAndTasks() {
        let blocks = Markdown.parse("1. 첫째\n2) 둘째\n   이어짐\n  - [x] 끝남\n\n- [ ] 남음\n다음 문단")
        #expect(blocks == [
            .list([
                MarkdownListItem(depth: 0, number: 1, checked: nil, text: "첫째"),
                MarkdownListItem(depth: 0, number: 2, checked: nil, text: "둘째\n이어짐"),
                MarkdownListItem(depth: 1, number: nil, checked: true, text: "끝남"),
                MarkdownListItem(depth: 0, number: nil, checked: false, text: "남음"),
            ]),
            .paragraph("다음 문단"),
        ])
    }

    @Test func keepsCodeBlocksVerbatim() {
        let blocks = Markdown.parse("보세요:\n```swift\nlet a = 1\n\n| 표 아님 |\n```\n> 인용\n> 둘째")
        #expect(blocks == [
            .paragraph("보세요:"),
            .code(language: "swift", text: "let a = 1\n\n| 표 아님 |"),
            .quote("인용\n둘째"),
        ])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        #expect(Markdown.parse("```\n쓰는 중") == [.code(language: "", text: "쓰는 중")])
    }

    @Test func boldLineIsNotARule() {
        #expect(Markdown.parse("**굵게**") == [.paragraph("**굵게**")])
        #expect(Markdown.parse("#태그") == [.paragraph("#태그")])
    }
}
