package io.github.eocnd36.kongi.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import kotlin.math.PI
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.withFrameMillis
import kotlin.math.max
import kotlin.math.sin

/** 화면이 보이는 동안 흐르는 시간 (초). 그리기 단계에서만 읽으면 다시 구성하지 않고 다시 그리기만 합니다. */
@Composable
fun rememberClock(): State<Float> {
    val time = remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) {
        val start = withFrameMillis { it }
        while (true) withFrameMillis { time.floatValue = (it - start) / 1000f }
    }
    return time
}

/** 부드럽게 시작하고 끝나는 0 → 1 */
fun smooth(x: Float): Float {
    val v = x.coerceIn(0f, 1f)
    return v * v * (3 - 2 * v)
}

/**
 * 지금 하는 일: 콩이 색 빛이 글자를 천천히 훑고 지나간 뒤 잠깐 쉽니다 (2초에 한 번).
 * 빛은 글자 위에만 덧칠하고(SrcAtop) 그리기 단계에서만 움직여서, 글자를 다시 배치하지 않습니다.
 */
@Composable
fun GlowText(
    text: String,
    modifier: Modifier = Modifier,
    active: Boolean = true,
    style: TextStyle = LocalTextStyle.current,
    base: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    glow: Color = MaterialTheme.colorScheme.primary,
    maxLines: Int = 1,
) {
    if (!active) {
        Text(text, modifier, color = base, style = style, maxLines = maxLines, overflow = TextOverflow.Ellipsis)
        return
    }
    val clock = rememberClock()
    val peak = if (MaterialTheme.colorScheme.background.luminance() < 0.5f) Color.White else MaterialTheme.colorScheme.onSurface
    Text(
        text,
        modifier
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                // 1.4초 동안 훑고 0.6초 쉼. 빛 띠는 글자 밖에서 들어와 밖으로 나갑니다.
                val center = (-0.25f + 1.5f * smooth((clock.value % 2f) / 1.4f)) * size.width
                val half = size.width.coerceAtLeast(1f) * 0.22f
                drawRect(
                    Brush.horizontalGradient(
                        0f to Color.Transparent, 0.35f to glow, 0.5f to peak, 0.65f to glow, 1f to Color.Transparent,
                        startX = center - half, endX = center + half,
                    ),
                    blendMode = BlendMode.SrcAtop,
                )
            },
        color = base, style = style, maxLines = maxLines, overflow = TextOverflow.Ellipsis,
    )
}

/** 콩 세 알이 차례로 통통 튀어 오르고, 내려앉을 때 살짝 납작해집니다 (생각하거나 쓰는 중). */
@Composable
fun BeanDots(modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.primary, dot: Dp = 6.dp) {
    val clock = rememberClock()
    Canvas(modifier.size(width = dot * 6.2f, height = dot * 2.6f)) {
        val t = clock.value
        val d = dot.toPx()
        for (index in 0..2) {
            var p = (t * 1.5f - index * 0.17f) % 1f
            if (p < 0) p += 1f
            // 앞 절반은 뛰어오르고, 바로 뒤에 납작하게 내려앉습니다.
            val hop = if (p < 0.5f) sin(p / 0.5f * PI.toFloat()) else 0f
            val land = if (p >= 0.5f && p < 0.62f) sin((p - 0.5f) / 0.12f * PI.toFloat()) else 0f
            val w = d * 1.25f * (1 + land * 0.2f)
            val h = d * (1 - land * 0.25f)
            val x = d * 0.9f + index * d * 2.1f
            val y = size.height - 1 - h - hop * d * 1.3f
            drawOval(color.copy(alpha = color.alpha * (0.45f + 0.55f * hop)), topLeft = Offset(x - w / 2, y), size = Size(w, h))
        }
    }
}

/** 진행 중 표시: 점 주위로 물결이 퍼집니다. */
@Composable
fun PulsingDot(color: Color, modifier: Modifier = Modifier, size: Dp = 10.dp, pulsing: Boolean = true) {
    val clock = if (pulsing) rememberClock() else null
    Canvas(modifier.size(size * 2.4f)) {
        val r = size.toPx() / 2
        clock?.let {
            val phase = (it.value / 1.3f) % 1f
            drawCircle(color.copy(alpha = 0.7f * (1 - phase)), radius = r * (1 + phase * 1.4f), style = Stroke(1.5.dp.toPx()))
        }
        drawCircle(color, radius = r)
    }
}

/** 끝을 모르는 진행 막대: 짧은 빛줄기가 계속 지나갑니다. */
@Composable
fun SweepBar(color: Color, modifier: Modifier = Modifier, height: Dp = 2.dp) {
    val clock = rememberClock()
    Canvas(modifier.fillMaxWidth().height(height)) {
        val t = (clock.value / 1.4f) % 1f
        val width = size.width * 0.35f
        val x = t * (size.width + width) - width
        drawRoundRect(
            Brush.horizontalGradient(listOf(color.copy(alpha = 0f), color, color.copy(alpha = 0f)), startX = x, endX = x + width),
            topLeft = Offset(x, 0f), size = Size(width, size.height), cornerRadius = CornerRadius(size.height),
        )
    }
}

/** 가는 호가 도는 진행 표시 */
@Composable
fun Spinner(color: Color, modifier: Modifier = Modifier, size: Dp = 14.dp) {
    val transition = rememberInfiniteTransition(label = "spin")
    val angle by transition.animateFloat(0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Restart), label = "angle")
    Canvas(modifier.size(size)) {
        val stroke = this.size.minDimension * 0.15f
        drawArc(
            color, startAngle = angle, sweepAngle = 250f, useCenter = false,
            topLeft = Offset(stroke / 2, stroke / 2), size = Size(this.size.width - stroke, this.size.height - stroke),
            style = Stroke(stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
    }
}
