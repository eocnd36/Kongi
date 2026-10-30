package io.github.eocnd36.kongi.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.withStyle
import io.github.eocnd36.kongi.Align
import io.github.eocnd36.kongi.Inline
import io.github.eocnd36.kongi.Markdown
import io.github.eocnd36.kongi.MdBlock
import io.github.eocnd36.kongi.MdItem
import kotlinx.coroutines.delay

/** Claude의 대답을 문단·제목·목록·표·코드 블록 모양 그대로 */
@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier, style: TextStyle = MaterialTheme.typography.bodyMedium) {
    val blocks = remember(text) { Markdown.parse(text) }
    val inlineCode = inlineCodeStyle()
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (block in blocks) {
            when (block) {
                is MdBlock.Heading -> Text(
                    remember(block.text, inlineCode) { inline(block.text, inlineCode) },
                    style = when (block.level) {
                        1 -> MaterialTheme.typography.titleLarge
                        2 -> MaterialTheme.typography.titleMedium
                        else -> MaterialTheme.typography.titleSmall
                    }.copy(fontWeight = FontWeight.Bold),
                    modifier = Modifier.padding(top = if (block.level <= 2) 4.dp else 0.dp),
                )
                is MdBlock.Paragraph -> Text(remember(block.text, inlineCode) { inline(block.text, inlineCode) }, style = style)
                is MdBlock.ListBlock -> ListView(block.items, style, inlineCode)
                is MdBlock.Code -> CodeBlock(block.language, block.text)
                is MdBlock.Quote -> Row(Modifier.height(IntrinsicSize.Min)) {
                    Box(Modifier.width(3.dp).fillMaxHeight().clip(RoundedCornerShape(2.dp)).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)))
                    Text(
                        remember(block.text, inlineCode) { inline(block.text, inlineCode) },
                        style = style, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 10.dp),
                    )
                }
                is MdBlock.Table -> TableView(block, style, inlineCode)
                MdBlock.Rule -> HorizontalDivider(Modifier.padding(vertical = 2.dp), color = MaterialTheme.colorScheme.outlineVariant)
            }
        }
    }
}

/**
 * 방금 들어온 대답은 단어가 하나씩 흐릿하게 피어나며 써지고, 끝에서 콩이 색 점이 숨 쉽니다.
 * 다 쓰면 마크다운 모양으로 바뀝니다. 단어당 45ms, 전체는 0.8 ~ 5초.
 */
@Composable
fun BloomingMarkdown(id: String, text: String, fresh: Boolean, modifier: Modifier = Modifier, style: TextStyle = MaterialTheme.typography.bodyMedium) {
    var blooming by remember(id) { mutableStateOf(fresh && id !in played) }
    // 단어마다 뒤의 빈칸·줄바꿈까지 붙여 둡니다.
    val words = remember(text) { Regex("[^ \\n]*[ \\n]?").findAll(text).map { it.value }.filter { it.isNotEmpty() }.toList() }
    val duration = (words.size * 0.045f).coerceIn(0.8f, 5f)
    val fade = 0.25f
    LaunchedEffect(id) {
        if (!blooming) return@LaunchedEffect
        played += id
        delay(((duration + fade) * 1000).toLong() + 150)
        blooming = false
    }
    if (!blooming) {
        MarkdownText(text, modifier, style)
        return
    }
    val clock = rememberClock()
    val start = remember(id) { clock.value }
    val color = LocalContentColor.current
    val accent = MaterialTheme.colorScheme.primary
    val elapsed = clock.value - start
    val step = duration / words.size.coerceAtLeast(1)
    Text(
        buildAnnotatedString {
            for ((index, word) in words.withIndex()) {
                val age = elapsed - index * step
                if (age <= 0) break
                val alpha = if (age >= fade) 1f else smooth(age / fade)
                withStyle(SpanStyle(color = color.copy(alpha = color.alpha * alpha))) { append(word) }
            }
            // 끝에서 숨 쉬는 콩이 색 점
            val breath = 0.35f + 0.65f * (0.5f + 0.5f * kotlin.math.sin(clock.value * 5f))
            withStyle(SpanStyle(color = accent.copy(alpha = breath))) { append(" ●") }
        },
        modifier, style = style,
    )
}

private val played = mutableSetOf<String>()

@Composable
private fun inlineCodeStyle() = SpanStyle(
    fontFamily = FontFamily.Monospace,
    fontSize = 0.92.em(),
    background = MaterialTheme.colorScheme.surfaceContainerHighest,
)

private fun Double.em() = androidx.compose.ui.unit.TextUnit(this.toFloat(), androidx.compose.ui.unit.TextUnitType.Em)

/** 줄 안의 꾸밈을 AnnotatedString으로 */
fun inline(text: String, code: SpanStyle): AnnotatedString = buildAnnotatedString {
    for (span in Inline.parse(text)) {
        var style = SpanStyle()
        if (span.bold) style = style.merge(SpanStyle(fontWeight = FontWeight.SemiBold))
        if (span.italic) style = style.merge(SpanStyle(fontStyle = FontStyle.Italic))
        if (span.strike) style = style.merge(SpanStyle(textDecoration = TextDecoration.LineThrough))
        if (span.code) style = style.merge(code)
        if (span.link != null) style = style.merge(SpanStyle(textDecoration = TextDecoration.Underline))
        if (span.dim) style = style.merge(SpanStyle(color = Color.Gray))
        withStyle(style) { append(span.text) }
    }
}

@Composable
private fun ListView(items: List<MdItem>, style: TextStyle, code: SpanStyle) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (item in items) {
            Row(Modifier.padding(start = (item.depth * 16).dp)) {
                Box(Modifier.width(22.dp).padding(top = 2.dp), contentAlignment = Alignment.TopStart) {
                    when {
                        item.checked != null -> Icon(
                            if (item.checked) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank, null,
                            tint = if (item.checked) LocalStatus.current.green else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(17.dp),
                        )
                        item.number != null -> Text("${item.number}.", style = style, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        else -> Box(
                            Modifier.padding(top = 7.dp, start = 4.dp).size(6.dp).clip(CircleShape)
                                .background(if (item.depth == 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant),
                        )
                    }
                }
                Text(
                    remember(item.text, code) { inline(item.text, code) }, style = style,
                    color = if (item.checked == true) LocalContentColor.current.copy(alpha = 0.6f) else LocalContentColor.current,
                    textDecoration = if (item.checked == true) TextDecoration.LineThrough else null,
                )
            }
        }
    }
}

@Composable
fun CodeBlock(language: String, text: String, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(LocalStatus.current.code)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(10.dp)),
    ) {
        if (language.isNotEmpty()) {
            Text(
                language, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 12.dp, top = 8.dp),
            )
        }
        Text(
            text, fontFamily = FontFamily.Monospace, fontSize = 12.5.sp, lineHeight = 18.sp, softWrap = false,
            modifier = Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 9.dp),
        )
    }
}

/** 표: 칸 너비를 열마다 맞추고, 화면보다 넓으면 옆으로 밉니다. */
@Composable
private fun TableView(table: MdBlock.Table, style: TextStyle, code: SpanStyle) {
    val shape = RoundedCornerShape(10.dp)
    val line = MaterialTheme.colorScheme.outlineVariant
    val headerBackground = MaterialTheme.colorScheme.surfaceContainerHighest
    val stripe = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.03f)
    val columns = table.header.size
    // 줄 사이 선을 그을 자리 (배치할 때 채우고 그릴 때 씀)
    val rowLines = remember { mutableListOf<Int>() }
    Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
        Layout(
            modifier = Modifier.clip(shape).border(1.dp, line, shape).drawWithContent {
                drawContent()
                for (y in rowLines) drawLine(line, Offset(0f, y.toFloat()), Offset(size.width, y.toFloat()), 1.dp.toPx())
            },
            content = {
                (listOf(table.header) + table.rows).forEachIndexed { row, cells ->
                    cells.forEachIndexed { column, cell ->
                        val align = table.alignments.getOrElse(column) { Align.Start }
                        Text(
                            remember(cell, code) { inline(cell, code) },
                            style = style.copy(fontSize = style.fontSize * 0.95f),
                            fontWeight = if (row == 0) FontWeight.SemiBold else null,
                            textAlign = when (align) { Align.Start -> TextAlign.Start; Align.Center -> TextAlign.Center; Align.End -> TextAlign.End },
                            modifier = Modifier
                                .background(if (row == 0) headerBackground else if (row % 2 == 0) stripe else Color.Transparent)
                                .padding(horizontal = 10.dp, vertical = 7.dp),
                        )
                    }
                }
            },
        ) { measurables, _ ->
            val rows = measurables.size / columns
            val cap = 240.dp.roundToPx()
            // 칸의 자연스러운 너비로 열 너비를, 그 너비에서의 높이로 줄 높이를 정한 뒤 한 번에 잽니다.
            val widths = IntArray(columns)
            measurables.forEachIndexed { index, m ->
                widths[index % columns] = maxOf(widths[index % columns], m.maxIntrinsicWidth(Constraints.Infinity).coerceAtMost(cap))
            }
            val heights = IntArray(rows) { r -> (0 until columns).maxOf { c -> measurables[r * columns + c].minIntrinsicHeight(widths[c]) } }
            val placeables = measurables.mapIndexed { index, m ->
                Constraints.fixed(widths[index % columns], heights[index / columns]).let(m::measure)
            }
            rowLines.clear()
            layout(widths.sum(), heights.sum()) {
                var y = 0
                for (r in 0 until rows) {
                    var x = 0
                    for (c in 0 until columns) {
                        placeables[r * columns + c].placeRelative(x, y)
                        x += widths[c]
                    }
                    y += heights[r]
                    if (r < rows - 1) rowLines += y
                }
            }
        }
    }
}
