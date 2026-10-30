package io.github.eocnd36.kongi

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mac의 MarkdownTests와 같은 경우들 */
class MarkdownTest {
    @Test fun splitsHeadingsParagraphsAndRules() {
        assertEquals(
            listOf(MdBlock.Heading(2, "요약"), MdBlock.Paragraph("첫 줄\n둘째 줄"), MdBlock.Rule, MdBlock.Paragraph("끝")),
            Markdown.parse("## 요약 ##\n첫 줄\n둘째 줄\n\n---\n끝"),
        )
    }

    @Test fun readsTables() {
        val blocks = Markdown.parse("결과:\n| 파일 | 줄 | 상태 |\n|:--|:-:|--:|\n| `a|b.swift` | 12 | ✅ |\n| c.kt | 3 |")
        assertEquals(
            listOf(
                MdBlock.Paragraph("결과:"),
                MdBlock.Table(
                    listOf("파일", "줄", "상태"),
                    listOf(Align.Start, Align.Center, Align.End),
                    listOf(listOf("`a|b.swift`", "12", "✅"), listOf("c.kt", "3", "")),
                ),
            ),
            blocks,
        )
    }

    @Test fun pipesWithoutSeparatorStayText() {
        assertEquals(listOf(MdBlock.Paragraph("a | b\nc | d")), Markdown.parse("a | b\nc | d"))
    }

    @Test fun readsListsWithDepthNumbersAndTasks() {
        assertEquals(
            listOf(
                MdBlock.ListBlock(
                    listOf(
                        MdItem(0, 1, null, "첫째"),
                        MdItem(0, 2, null, "둘째\n이어짐"),
                        MdItem(1, null, true, "끝남"),
                        MdItem(0, null, false, "남음"),
                    ),
                ),
                MdBlock.Paragraph("다음 문단"),
            ),
            Markdown.parse("1. 첫째\n2) 둘째\n   이어짐\n  - [x] 끝남\n\n- [ ] 남음\n다음 문단"),
        )
    }

    @Test fun keepsCodeBlocksVerbatim() {
        assertEquals(
            listOf(MdBlock.Paragraph("보세요:"), MdBlock.Code("swift", "let a = 1\n\n| 표 아님 |"), MdBlock.Quote("인용\n둘째")),
            Markdown.parse("보세요:\n```swift\nlet a = 1\n\n| 표 아님 |\n```\n> 인용\n> 둘째"),
        )
        assertEquals(listOf(MdBlock.Code("", "쓰는 중")), Markdown.parse("```\n쓰는 중"))
    }

    @Test fun boldLineIsNotARule() {
        assertEquals(listOf(MdBlock.Paragraph("**굵게**")), Markdown.parse("**굵게**"))
        assertEquals(listOf(MdBlock.Paragraph("#태그")), Markdown.parse("#태그"))
    }

    @Test fun inlineStyles() {
        assertEquals(
            listOf(
                Span("이건 "), Span("굵게", bold = true), Span(", "), Span("기울임", italic = true), Span(", "),
                Span("a*b", code = true), Span(", "), Span("지움", strike = true), Span(" snake_case_name"),
            ),
            Inline.parse("이건 **굵게**, *기울임*, `a*b`, ~~지움~~ snake_case_name"),
        )
    }

    @Test fun linksShowTheirAddress() {
        assertEquals(
            listOf(Span("여기", link = "https://x.y"), Span(" (https://x.y)", dim = true)),
            Inline.parse("[여기](https://x.y)"),
        )
        assertEquals(listOf(Span("2 * 3 = 6")), Inline.parse("2 * 3 = 6"))
    }
}
