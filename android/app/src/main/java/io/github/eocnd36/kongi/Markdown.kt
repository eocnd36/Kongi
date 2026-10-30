package io.github.eocnd36.kongi

/**
 * Claude의 대답을 문단·제목·목록·표·코드 블록으로 나눕니다. Mac의 Markdown.swift와 같은 규칙입니다.
 * 줄 안의 꾸밈(굵게, 기울임, `코드`, 취소선, 링크)은 [Inline]이 나눕니다.
 */
sealed interface MdBlock {
    data class Heading(val level: Int, val text: String) : MdBlock
    data class Paragraph(val text: String) : MdBlock
    data class ListBlock(val items: List<MdItem>) : MdBlock
    data class Code(val language: String, val text: String) : MdBlock
    data class Quote(val text: String) : MdBlock
    data class Table(val header: List<String>, val alignments: List<Align>, val rows: List<List<String>>) : MdBlock
    data object Rule : MdBlock
}

data class MdItem(val depth: Int, val number: Int?, val checked: Boolean?, val text: String)

enum class Align { Start, Center, End }

object Markdown {
    fun parse(text: String): List<MdBlock> {
        val lines = text.replace("\r\n", "\n").split("\n")
        val blocks = mutableListOf<MdBlock>()
        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            val trimmed = line.trim()
            if (trimmed.isEmpty()) { i++; continue }

            val fence = fence(trimmed)
            if (fence != null) {
                val language = trimmed.removePrefix(fence).trim()
                val body = mutableListOf<String>()
                i++
                while (i < lines.size && !lines[i].trim().startsWith(fence)) body += lines[i++]
                i++
                blocks += MdBlock.Code(language, body.joinToString("\n"))
                continue
            }
            run {
                val heading = heading(trimmed)
                when {
                    heading != null -> { blocks += heading; i++ }
                    isRule(trimmed) -> { blocks += MdBlock.Rule; i++ }
                    i + 1 < lines.size && '|' in trimmed && separator(lines[i + 1])?.size == cells(trimmed).size -> {
                        val header = cells(trimmed)
                        val alignments = separator(lines[i + 1])!!
                        val rows = mutableListOf<List<String>>()
                        i += 2
                        while (i < lines.size) {
                            val row = lines[i].trim()
                            if (row.isEmpty() || '|' !in row) break
                            val cells = cells(row)
                            rows += (cells + List(maxOf(0, header.size - cells.size)) { "" }).take(header.size)
                            i++
                        }
                        blocks += MdBlock.Table(header, alignments, rows)
                    }
                    trimmed.startsWith(">") -> {
                        val quoted = mutableListOf<String>()
                        while (i < lines.size && lines[i].trim().startsWith(">")) {
                            quoted += lines[i].trim().removePrefix(">").removePrefix(" ")
                            i++
                        }
                        blocks += MdBlock.Quote(quoted.joinToString("\n"))
                    }
                    listItem(line) != null -> {
                        val items = mutableListOf<MdItem>()
                        while (i < lines.size) {
                            val current = lines[i]
                            val item = listItem(current)
                            when {
                                item != null -> { items += item; i++ }
                                current.isBlank() -> {
                                    if (i + 1 < lines.size && listItem(lines[i + 1]) != null) i++ else break
                                }
                                (current.startsWith("  ") || current.startsWith("\t")) && items.isNotEmpty() -> {
                                    val last = items.removeAt(items.lastIndex)
                                    items += last.copy(text = last.text + "\n" + current.trim())
                                    i++
                                }
                                else -> break
                            }
                        }
                        blocks += MdBlock.ListBlock(items)
                    }
                    else -> {
                        val paragraph = mutableListOf<String>()
                        while (i < lines.size) {
                            val current = lines[i]
                            if (current.isBlank()) break
                            if (paragraph.isNotEmpty() && startsBlock(current, lines.getOrNull(i + 1))) break
                            paragraph += current.trim()
                            i++
                        }
                        blocks += MdBlock.Paragraph(paragraph.joinToString("\n"))
                    }
                }
            }
        }
        return blocks
    }

    private fun fence(trimmed: String) = when {
        trimmed.startsWith("```") -> "```"
        trimmed.startsWith("~~~") -> "~~~"
        else -> null
    }

    private fun heading(trimmed: String): MdBlock.Heading? {
        val hashes = trimmed.takeWhile { it == '#' }.length
        if (hashes !in 1..6) return null
        val rest = trimmed.substring(hashes)
        if (rest.isNotEmpty() && !rest.startsWith(" ")) return null
        return MdBlock.Heading(hashes, rest.trim().trimEnd('#').trim())
    }

    private fun isRule(trimmed: String): Boolean {
        val compact = trimmed.filter { it != ' ' }
        if (compact.length < 3 || compact[0] !in "-*_") return false
        return compact.all { it == compact[0] }
    }

    private fun separator(line: String): List<Align>? {
        val trimmed = line.trim()
        if ('-' !in trimmed) return null
        val parts = cells(trimmed)
        if (parts.isEmpty()) return null
        val result = parts.map { part ->
            val cell = part.trim()
            val core = cell.trim(':')
            if (core.isEmpty() || core.any { it != '-' }) return null
            when {
                cell.startsWith(":") && cell.endsWith(":") -> Align.Center
                cell.endsWith(":") -> Align.End
                else -> Align.Start
            }
        }
        if (result.size == 1 && !(trimmed.startsWith("|") || trimmed.endsWith("|"))) return null
        return result
    }

    /** 표 한 줄을 칸으로 나눕니다. `\|`와 `코드` 안의 |는 칸 구분이 아닙니다. */
    fun cells(row: String): List<String> {
        var text = row.trim()
        if (text.startsWith("|")) text = text.substring(1)
        if (text.endsWith("|") && !text.endsWith("\\|")) text = text.dropLast(1)
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var inCode = false
        var escaped = false
        for (c in text) {
            when {
                escaped -> { if (c == '|') current.append('|') else current.append('\\').append(c); escaped = false }
                c == '\\' -> escaped = true
                c == '`' -> { inCode = !inCode; current.append(c) }
                c == '|' && !inCode -> { result += current.toString().trim(); current.clear() }
                else -> current.append(c)
            }
        }
        if (escaped) current.append('\\')
        result += current.toString().trim()
        return result
    }

    private val ordered = Regex("^(\\d{1,9})[.)] (.*)$")

    private fun listItem(line: String): MdItem? {
        var spaces = 0
        for (c in line) { if (c == ' ') spaces++ else if (c == '\t') spaces += 4 else break }
        val rest = line.trimStart(' ', '\t')
        var number: Int? = null
        var body: String
        if (rest.length >= 2 && rest[0] in "-*+" && rest[1] == ' ') {
            body = rest.substring(2)
        } else {
            val match = ordered.find(rest) ?: return null
            number = match.groupValues[1].toInt()
            body = match.groupValues[2]
        }
        var checked: Boolean? = null
        when {
            body.startsWith("[ ] ") -> { checked = false; body = body.substring(4) }
            body.startsWith("[x] ") || body.startsWith("[X] ") -> { checked = true; body = body.substring(4) }
        }
        return MdItem(minOf(spaces / 2, 4), number, checked, body.trim())
    }

    private fun startsBlock(line: String, next: String?): Boolean {
        val trimmed = line.trim()
        if (fence(trimmed) != null || heading(trimmed) != null || trimmed.startsWith(">") || listItem(line) != null) return true
        if (isRule(trimmed)) return true
        return '|' in trimmed && next != null && separator(next) != null
    }
}

/** 줄 안의 꾸밈: 겹칠 수 있는 굵게·기울임·취소선과, 안을 해석하지 않는 `코드` */
data class Span(
    val text: String,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val strike: Boolean = false,
    val code: Boolean = false,
    /** 링크 주소. 대화 내용은 믿을 수 없어 누를 수 없게 하고, 보이는 글자와 다르면 주소를 함께 적습니다. */
    val link: String? = null,
    /** 링크 뒤에 덧붙인 실제 주소 (흐리게) */
    val dim: Boolean = false,
)

object Inline {
    fun parse(text: String): List<Span> {
        val out = mutableListOf<Span>()
        parse(text, Span(""), out)
        // 같은 꾸밈이 이어진 조각은 합칩니다.
        val merged = mutableListOf<Span>()
        for (span in out) {
            val last = merged.lastOrNull()
            if (last != null && last.copy(text = "") == span.copy(text = "")) merged[merged.lastIndex] = last.copy(text = last.text + span.text)
            else if (span.text.isNotEmpty()) merged += span
        }
        return merged
    }

    private fun parse(text: String, style: Span, out: MutableList<Span>) {
        val plain = StringBuilder()
        fun flush() { if (plain.isNotEmpty()) { out += style.copy(text = plain.toString()); plain.clear() } }
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c == '\\' && i + 1 < text.length && text[i + 1] in "\\`*_~[]()#|>-+.!") {
                plain.append(text[i + 1]); i += 2; continue
            }
            if (c == '`') {
                val ticks = text.substring(i).takeWhile { it == '`' }.length
                val end = text.indexOf("`".repeat(ticks), i + ticks)
                if (end > 0) {
                    flush()
                    out += style.copy(text = text.substring(i + ticks, end).trim(), code = true)
                    i = end + ticks
                    continue
                }
            }
            if (c == '[') {
                val close = closing(text, i, '[', ']')
                if (close > 0 && close + 1 < text.length && text[close + 1] == '(') {
                    val end = text.indexOf(')', close + 2)
                    if (end > 0) {
                        flush()
                        val label = text.substring(i + 1, close)
                        val url = text.substring(close + 2, end).trim()
                        parse(label, style.copy(link = url), out)
                        if (label != url) out += style.copy(text = " ($url)", dim = true)
                        i = end + 1
                        continue
                    }
                }
            }
            val marker = when {
                text.startsWith("***", i) -> "***"
                text.startsWith("**", i) -> "**"
                text.startsWith("__", i) && boundary(text, i - 1) -> "__"
                text.startsWith("~~", i) -> "~~"
                c == '*' -> "*"
                c == '_' && boundary(text, i - 1) -> "_"
                else -> null
            }
            if (marker != null && i + marker.length < text.length && !text[i + marker.length].isWhitespace()) {
                val end = findClose(text, marker, i + marker.length)
                if (end > 0) {
                    flush()
                    val inner = text.substring(i + marker.length, end)
                    val next = when (marker) {
                        "***" -> style.copy(bold = true, italic = true)
                        "**", "__" -> style.copy(bold = true)
                        "~~" -> style.copy(strike = true)
                        else -> style.copy(italic = true)
                    }
                    parse(inner, next, out)
                    i = end + marker.length
                    continue
                }
            }
            plain.append(c)
            i++
        }
        flush()
    }

    /** _ 강조는 단어 안(snake_case)에서는 시작하지 않습니다. */
    private fun boundary(text: String, index: Int) = index < 0 || !text[index].isLetterOrDigit()

    private fun findClose(text: String, marker: String, from: Int): Int {
        var index = text.indexOf(marker, from)
        while (index > 0) {
            val before = text[index - 1]
            val after = text.getOrNull(index + marker.length)
            val wordInside = marker.startsWith("_") && after != null && after.isLetterOrDigit()
            // 한 글자짜리 *는 **의 일부가 아닐 때만 닫습니다.
            val partOfLonger = marker == "*" && after == '*'
            if (!before.isWhitespace() && !wordInside && !partOfLonger) return index
            index = text.indexOf(marker, index + marker.length)
        }
        return -1
    }

    private fun closing(text: String, open: Int, start: Char, end: Char): Int {
        var depth = 0
        for (index in open until text.length) {
            if (text[index] == start) depth++
            if (text[index] == end) { depth--; if (depth == 0) return index }
        }
        return -1
    }
}
