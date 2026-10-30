package io.github.eocnd36.kongi.ui

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import io.github.eocnd36.kongi.SessionSummary

@Immutable
private data class StemStep(val id: String, val title: String, val state: State) {
    enum class State { Done, Running, Failed, Thinking, Finished }
}

private fun stemSteps(session: SessionSummary): List<StemStep> {
    val result = session.steps.map {
        StemStep(it.id, it.title, when (it.status) { "running" -> StemStep.State.Running; "failed" -> StemStep.State.Failed; else -> StemStep.State.Done })
    }.toMutableList()
    val last = session.steps.lastOrNull()?.id.orEmpty()
    if (session.thinking) result += StemStep("thinking-$last", session.state, StemStep.State.Thinking)
    else if (session.done) result += StemStep("done-$last", session.state, StemStep.State.Finished)
    return result.takeLast(3)
}

/**
 * 진행 단계: 왼쪽 줄기를 따라 단계가 자랍니다 (Mac 실시간 화면의 단계 줄기와 같은 모양).
 * 지금 하는 단계는 줄기 끝의 봉오리가 숨 쉬고 이름 위로 빛이 지나가며, 끝나면 잎이 돋고 이름이 작아집니다.
 * 새 단계는 아래에서 올라오고, 오래된 단계는 위로 밀려나며 사라집니다.
 */
@Composable
fun SproutSteps(session: SessionSummary, modifier: Modifier = Modifier, style: TextStyle = MaterialTheme.typography.bodyMedium) {
    val steps = stemSteps(session)
    if (steps.isEmpty()) {
        GlowText(session.step.ifEmpty { session.state }, modifier, style = style)
        return
    }
    val row = 22.dp
    val stem = LocalStatus.current.green.copy(alpha = 0.4f)
    LazyColumn(modifier.fillMaxWidth().height(row * steps.size), userScrollEnabled = false) {
        itemsIndexed(steps, key = { _, step -> step.id }) { index, step ->
            val first = index == 0
            val latest = index == steps.lastIndex
            Row(
                Modifier
                    .animateItem(
                        fadeInSpec = tween(320),
                        placementSpec = spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMediumLow, visibilityThreshold = IntOffset.VisibilityThreshold),
                        fadeOutSpec = tween(220),
                    )
                    .height(row)
                    .fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.width(16.dp).height(row).drawBehind {
                        // 줄기: 위아래 줄과 이어집니다.
                        val top = if (first) size.height / 2 else 0f
                        val bottom = if (latest) size.height / 2 else size.height
                        drawLine(stem, Offset(size.width / 2, top), Offset(size.width / 2, bottom), 1.5.dp.toPx())
                    },
                    contentAlignment = Alignment.Center,
                ) { Node(step.state) }
                Spacer(Modifier.width(6.dp))
                val current = step.state == StemStep.State.Running || step.state == StemStep.State.Thinking
                if (current) {
                    GlowText(step.title, style = style.copy(fontWeight = FontWeight.SemiBold))
                } else {
                    Text(
                        step.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = if (step.state == StemStep.State.Finished) style else style.copy(fontSize = style.fontSize * 0.92f),
                        color = when (step.state) {
                            StemStep.State.Failed -> LocalStatus.current.red
                            StemStep.State.Finished -> MaterialTheme.colorScheme.onSurface
                            else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun Node(state: StemStep.State) {
    val status = LocalStatus.current
    when (state) {
        StemStep.State.Running, StemStep.State.Thinking -> Bud(slow = state == StemStep.State.Thinking)
        StemStep.State.Done -> Canvas(Modifier.size(width = 10.dp, height = 7.dp)) {
            // 작은 잎
            val leaf = Path().apply {
                moveTo(0f, size.height)
                quadraticTo(0f, 0f, size.width, 0f)
                quadraticTo(size.width, size.height, 0f, size.height)
            }
            drawPath(leaf, status.green)
        }
        StemStep.State.Failed -> Icon(Icons.Filled.Close, null, Modifier.size(12.dp), tint = status.red)
        StemStep.State.Finished -> Box(
            Modifier.size(12.dp).drawBehind { drawCircle(status.green) },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Check, null, Modifier.size(9.dp), tint = Color.Black) }
    }
}

/** 줄기 끝의 봉오리: 숨 쉬듯 커졌다 작아지고, 둘레로 고리가 퍼집니다. 생각 중이면 더 느리게. */
@Composable
private fun Bud(slow: Boolean) {
    val clock = rememberClock()
    val color = MaterialTheme.colorScheme.primary
    Canvas(Modifier.size(16.dp)) {
        val t = clock.value * if (slow) 0.6f else 1f
        val r = 4.dp.toPx()
        val ring = (t / 1.2f) % 1f
        drawCircle(color.copy(alpha = 0.6f * (1 - ring)), r * (1 + ring * 1.2f), style = Stroke(1.dp.toPx()))
        drawCircle(color, r * (0.85f + 0.15f * kotlin.math.sin(t * 4f)))
    }
}
