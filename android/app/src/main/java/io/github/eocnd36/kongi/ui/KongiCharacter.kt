package io.github.eocnd36.kongi.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin

/** 콩이의 기분: Mac의 Kongi.Mood와 같은 이름입니다. */
enum class Mood {
    Sleeping, Idle, Working, Alert, Happy, Reading, Editing, Running, Searching, Thinking, Sad;

    val busy get() = this in setOf(Working, Reading, Editing, Running, Searching, Thinking)

    companion object {
        fun named(name: String): Mood = entries.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: Idle
    }
}

private val bodyTop = Color(0xFFB5EDC0)
private val bodyBottom = Color(0xFF80C78F)
private val leaf = Color(0xFF54B866)
private val ink = Color(0xFF1F2B24)
private val cheek = Color(0xFFFF9EA8)
private val yellow = Color(0xFFFFD60A)
private val green = Color(0xFF34D399)

/**
 * 새싹이 난 강낭콩 "콩이". Mac 앱(Kongi.swift)과 같은 수식으로 도형만 써서 그립니다.
 * 누르면 찌그러졌다 튕기고 하트가 떠오릅니다. growth(0…1)만큼 잎이 크고, 많이 쓴 날엔 꽃이 핍니다.
 */
@Composable
fun Kongi(mood: Mood, modifier: Modifier = Modifier, size: Dp = 32.dp, growth: Float = 0.3f, tappable: Boolean = true) {
    val clock = rememberClock()
    // 기분이 바뀌면 0.45초 동안 이전 움직임에서 새 움직임으로 섞습니다.
    var previous by remember { mutableStateOf(mood) }
    var shown by remember { mutableStateOf(mood) }
    val changedAt = remember { mutableFloatStateOf(-10f) }
    val tappedAt = remember { mutableFloatStateOf(-10f) }
    LaunchedEffect(mood) {
        if (mood != shown) {
            previous = shown
            shown = mood
            changedAt.floatValue = clock.value
        }
    }
    val tap = if (tappable) Modifier.clickable(remember { MutableInteractionSource() }, indication = null) { tappedAt.floatValue = clock.value } else Modifier
    Canvas(modifier.size(size * 1.5f).then(tap)) {
        val t = clock.value
        val x = ((t - changedAt.floatValue) / 0.45f).coerceIn(0f, 1f)
        val blend = x * x * (3 - 2 * x)
        var pose = Pose.make(shown, t, growth)
        if (blend < 1 && previous != shown) pose = Pose.make(previous, t, growth).mixed(pose, blend)
        pose.tapAge = t - tappedAt.floatValue
        drawKongi(pose, t, this.size.minDimension / 1.5f)
    }
}

private enum class Eye { Open, Closed, Happy, Sad, Wide }
private enum class Mouth { Dash, Small, Smile, Frown, Yawn }

private class Pose {
    var lift = 0f; var squash = 0f; var sway = 0f; var tilt = 0f
    var lookX = 0f; var lookY = 0f; var droop = 0f
    var eye = Eye.Open; var eyeHeight = 0.12f
    var mouth = Mouth.Dash; var yawn = 0f
    var growth = 0.3f
    var sparkles = 0f; var bubble = 0f; var snore = 0f; var steam = 0f; var plus = 0f; var thought = 0f; var sweat = 0f
    var tapAge = 99f

    fun mixed(other: Pose, amount: Float): Pose {
        fun mix(a: Float, b: Float) = a + (b - a) * amount
        val face = if (amount < 0.5f) this else other
        return Pose().also {
            it.lift = mix(lift, other.lift); it.squash = mix(squash, other.squash); it.sway = mix(sway, other.sway)
            it.tilt = mix(tilt, other.tilt); it.lookX = mix(lookX, other.lookX); it.lookY = mix(lookY, other.lookY)
            it.droop = mix(droop, other.droop)
            it.eye = face.eye; it.eyeHeight = face.eyeHeight; it.mouth = face.mouth; it.yawn = face.yawn; it.growth = other.growth
            it.sparkles = mix(sparkles, other.sparkles); it.bubble = mix(bubble, other.bubble); it.snore = mix(snore, other.snore)
            it.steam = mix(steam, other.steam); it.plus = mix(plus, other.plus); it.thought = mix(thought, other.thought)
            it.sweat = mix(sweat, other.sweat)
        }
    }

    companion object {
        fun make(mood: Mood, t: Float, growth: Float): Pose = Pose().apply {
            this.growth = growth
            val blink = t % 4.2f < 0.13f
            fun open(h: Float) { eye = if (blink) Eye.Closed else Eye.Open; eyeHeight = h }
            when (mood) {
                Mood.Sleeping -> { squash = sin(t * 1.2f) * 0.02f; eye = Eye.Closed; snore = 1f }
                Mood.Idle -> {
                    squash = sin(t * 2f) * 0.025f; sway = sin(t * 1.3f) * 4f; open(0.12f)
                    // 7초마다 두리번, 23초마다 하품
                    val look = t % 7f
                    if (look > 4f && look < 5.6f) lookX = sin((look - 4f) / 1.6f * 2 * PI.toFloat()) * 0.08f
                    val y = t % 23f
                    if (y < 1.4f) {
                        yawn = sin(y / 1.4f * PI.toFloat()); mouth = Mouth.Yawn
                        if (yawn > 0.3f) eye = Eye.Closed
                        squash += yawn * 0.04f
                    }
                }
                Mood.Working -> {
                    lift = -abs(sin(t * 9f)) * 0.06f; squash = sin(t * 18f) * 0.03f; sway = sin(t * 6f) * 14f
                    lookX = sin(t * 1.7f) * 0.07f; open(0.12f)
                }
                Mood.Reading -> {
                    // 줄을 따라 왼쪽 → 오른쪽, 끝에서 다음 줄로 빠르게 돌아가며 살짝 끄덕
                    val line = (t / 1.6f) % 1f
                    lookX = if (line < 0.8f) -0.07f + 0.14f * (line / 0.8f) else 0.07f - 0.14f * ((line - 0.8f) / 0.2f)
                    lookY = 0.02f
                    lift = if (line > 0.8f) -0.03f * sin((line - 0.8f) / 0.2f * PI.toFloat()) else 0f
                    squash = sin(t * 2f) * 0.02f; sway = sin(t * 1.6f) * 5f; open(0.1f)
                }
                Mood.Editing -> {
                    lift = -abs(sin(t * 10f)) * 0.05f; squash = sin(t * 20f) * 0.025f; sway = sin(t * 14f) * 9f
                    lookY = 0.035f; eye = Eye.Open; eyeHeight = 0.11f; plus = 1f
                }
                Mood.Running -> {
                    val stride = abs(sin(t * 8f))
                    lift = -stride * 0.12f; squash = (1 - stride).pow(4) * -0.08f; sway = sin(t * 8f) * 10f
                    eye = Eye.Open; mouth = Mouth.Small; steam = 1f
                }
                Mood.Searching -> {
                    tilt = sin(t * 2.2f) * 7f; lookX = sin(t * 2.2f) * 0.1f; sway = sin(t * 2.2f) * 8f
                    eye = if (blink) Eye.Closed else Eye.Wide; mouth = Mouth.Small
                }
                Mood.Thinking -> {
                    lookX = 0.05f; lookY = -0.045f; sway = sin(t * 1.5f) * 5f; squash = sin(t * 1.8f) * 0.02f
                    open(0.12f); thought = 1f
                }
                Mood.Alert -> {
                    lift = -abs(sin(t * 7f)) * 0.16f; sway = sin(t * 14f) * 10f; eye = Eye.Wide; mouth = Mouth.Small; bubble = 1f
                }
                Mood.Happy -> {
                    lift = -abs(sin(t * 6f)) * 0.22f; squash = -sin(t * 12f) * 0.04f; sway = sin(t * 6f) * 18f
                    eye = Eye.Happy; mouth = Mouth.Smile; sparkles = 1f
                }
                Mood.Sad -> {
                    squash = -0.04f + sin(t * 1.5f) * 0.01f; droop = 35f; sway = sin(t * 1.1f) * 2f; lookY = 0.03f
                    eye = Eye.Sad; mouth = Mouth.Frown; sweat = 1f
                }
            }
        }
    }
}

private fun DrawScope.drawKongi(p: Pose, t: Float, s: Float) {
    val cx = size.width / 2
    val cy = size.height / 2 + s * 0.12f
    val bottom = Offset(cx, cy + s * 0.41f)
    // 눌리면 납작해졌다가 튕겨 돌아옵니다.
    val tap = if (p.tapAge < 0.6f) -0.14f * exp(-p.tapAge * 7f) * cos(p.tapAge * 22f) else 0f

    translate(top = p.lift * s) {
        rotate(p.tilt, pivot = bottom) {
            scale(scaleX = 1 - (p.squash + tap) / 2, scaleY = 1 + p.squash + tap, pivot = bottom) {
                // 새싹
                val stemBase = Offset(cx, cy - s * 0.36f)
                rotate(p.sway, pivot = stemBase) {
                    val leafSize = 0.85f + p.growth * 0.5f
                    val stemTop = Offset(cx, stemBase.y - s * (0.18f + p.growth * 0.1f))
                    drawLine(leaf, stemBase, stemTop, strokeWidth = s * 0.07f, cap = StrokeCap.Round)
                    for (side in listOf(-1f, 1f)) {
                        val base = Offset(stemTop.x, stemTop.y + if (side > 0) s * 0.02f else 0f)
                        rotate(side * p.droop, pivot = base) {
                            val w = s * (if (side < 0) 0.27f else 0.23f) * leafSize
                            val h = s * (if (side < 0) 0.15f else 0.13f) * leafSize
                            drawPath(leafPath(base, side, w, h), if (side < 0) leaf else leaf.copy(alpha = 0.9f))
                        }
                    }
                    if (p.growth >= 0.8f) {
                        val center = Offset(stemTop.x, stemTop.y - s * 0.05f)
                        drawCircle(cheek, s * 0.06f, center)
                        drawCircle(yellow, s * 0.025f, center)
                    }
                }
                // 몸통과 하이라이트
                drawOval(
                    Brush.verticalGradient(listOf(bodyTop, bodyBottom), startY = cy - s * 0.41f, endY = cy + s * 0.41f),
                    topLeft = Offset(cx - s / 2, cy - s * 0.41f), size = Size(s, s * 0.82f),
                )
                rotate(-25f, pivot = Offset(cx - s * 0.23f, cy - s * 0.22f)) {
                    drawOval(Color.White.copy(alpha = 0.55f), topLeft = Offset(cx - s * 0.34f, cy - s * 0.28f), size = Size(s * 0.22f, s * 0.12f))
                }
                // 얼굴
                val lookX = p.lookX * s
                val eyeY = cy - s * 0.02f + p.lookY * s
                for (side in listOf(-1f, 1f)) {
                    drawEye(p, Offset(cx + side * s * 0.17f + lookX, eyeY), side, s)
                    drawOval(cheek.copy(alpha = 0.75f), topLeft = Offset(cx + side * s * 0.305f - s * 0.075f, cy + s * 0.075f), size = Size(s * 0.15f, s * 0.09f))
                }
                drawMouth(p, Offset(cx + lookX, cy + s * 0.13f + p.lookY * s * 0.5f), s)
            }
        }
    }
    // 장식
    if (p.sparkles > 0) for (i in 0..2) {
        val angle = t * 2 + i * 2.1f
        val center = Offset(cx + cos(angle) * s * 0.68f, cy + sin(angle) * s * 0.42f - s * 0.1f)
        val r = s * 0.11f * (0.7f + 0.3f * sin(t * 6 + i))
        drawPath(star(center, r), yellow.copy(alpha = p.sparkles * (0.5f + 0.5f * sin(t * 6 + i)).coerceIn(0f, 1f)))
    }
    if (p.bubble > 0) {
        val center = Offset(cx + s * 0.52f, cy - s * 0.5f)
        val r = s * 0.21f * (1 + sin(t * 8f) * 0.08f)
        drawCircle(yellow.copy(alpha = p.bubble), r, center)
        drawLine(Color.Black.copy(alpha = p.bubble), Offset(center.x, center.y - r * 0.5f), Offset(center.x, center.y + r * 0.12f), s * 0.06f, StrokeCap.Round)
        drawCircle(Color.Black.copy(alpha = p.bubble), s * 0.03f, Offset(center.x, center.y + r * 0.48f))
    }
    if (p.snore > 0) for (i in 0..1) {
        val phase = (t / 2.4f + i * 0.5f) % 1f
        val z = s * (0.12f + 0.08f * phase)
        val o = Offset(cx + s * (0.42f + phase * 0.18f), cy - s * (0.32f + phase * 0.36f))
        val path = Path().apply { moveTo(o.x, o.y); lineTo(o.x + z, o.y); lineTo(o.x, o.y + z); lineTo(o.x + z, o.y + z) }
        drawPath(path, Color.White.copy(alpha = p.snore * 0.8f * (1 - phase)), style = Stroke(s * 0.035f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
    // 뛰는 동안 머리 위로 김
    if (p.steam > 0) for (i in 0..2) {
        val phase = (t / 1.2f + i / 3f) % 1f
        val center = Offset(cx - s * 0.45f - phase * s * 0.15f + sin(phase * 9) * s * 0.03f, cy - s * 0.1f - phase * s * 0.4f)
        drawCircle(Color.White.copy(alpha = p.steam * 0.5f * (1 - phase)), s * (0.05f + phase * 0.06f), center)
    }
    // 고치는 동안 초록 +
    if (p.plus > 0) for (i in 0..1) {
        val phase = (t / 1.4f + i * 0.5f) % 1f
        val center = Offset(cx + s * (0.5f + i * 0.08f), cy + s * 0.1f - phase * s * 0.55f)
        val arm = s * 0.06f
        val fade = if (phase < 0.2f) phase / 0.2f else 1 - (phase - 0.2f) / 0.8f
        val color = green.copy(alpha = p.plus * fade)
        drawLine(color, Offset(center.x - arm, center.y), Offset(center.x + arm, center.y), s * 0.035f, StrokeCap.Round)
        drawLine(color, Offset(center.x, center.y - arm), Offset(center.x, center.y + arm), s * 0.035f, StrokeCap.Round)
    }
    // 생각 방울
    if (p.thought > 0) {
        val cycle = (t / 1.8f) % 1f
        for (i in 0..2) {
            val appear = ((cycle - i * 0.2f) / 0.15f).coerceIn(0f, 1f)
            val center = Offset(cx + s * (0.4f + i * 0.13f), cy - s * (0.32f + i * 0.15f))
            drawCircle(Color.White.copy(alpha = p.thought * 0.85f), s * (0.03f + i * 0.025f) * appear, center)
        }
    }
    // 식은땀
    if (p.sweat > 0) {
        val phase = (t / 2f) % 1f
        val x = cx + s * 0.4f
        val y = cy - s * 0.2f + phase * s * 0.25f
        val drop = Path().apply {
            moveTo(x, y - s * 0.07f)
            quadraticTo(x + s * 0.07f, y + s * 0.03f, x, y + s * 0.04f)
            quadraticTo(x - s * 0.07f, y + s * 0.03f, x, y - s * 0.07f)
        }
        drawPath(drop, Color(0xFF8CC7FF).copy(alpha = p.sweat * (1 - phase * 0.6f)))
    }
    // 누르면 하트
    if (p.tapAge in 0f..1.1f) {
        val rise = p.tapAge / 1.1f
        val c = Offset(cx + s * 0.38f, cy - s * 0.35f - rise * s * 0.35f)
        val r = s * 0.1f * (0.6f + (p.tapAge * 4).coerceAtMost(1f) * 0.4f)
        val heart = Path().apply {
            moveTo(c.x, c.y + r)
            cubicTo(c.x - r * 0.3f, c.y + r * 0.7f, c.x - r, c.y + r * 0.3f, c.x - r, c.y - r * 0.2f)
            cubicTo(c.x - r, c.y - r * 0.85f, c.x, c.y - r * 0.85f, c.x, c.y - r * 0.25f)
            cubicTo(c.x, c.y - r * 0.85f, c.x + r, c.y - r * 0.85f, c.x + r, c.y - r * 0.2f)
            cubicTo(c.x + r, c.y + r * 0.3f, c.x + r * 0.3f, c.y + r * 0.7f, c.x, c.y + r)
        }
        drawPath(heart, cheek.copy(alpha = 1 - rise * 0.9f))
    }
}

private fun DrawScope.drawEye(p: Pose, at: Offset, side: Float, s: Float) {
    when (p.eye) {
        Eye.Open -> drawOval(ink, topLeft = Offset(at.x - s * 0.05f, at.y - s * p.eyeHeight / 2), size = Size(s * 0.1f, s * p.eyeHeight))
        Eye.Closed -> drawLine(ink, Offset(at.x - s * 0.055f, at.y), Offset(at.x + s * 0.055f, at.y), s * 0.035f, StrokeCap.Round)
        Eye.Happy -> drawPath(
            Path().apply { moveTo(at.x - s * 0.07f, at.y + s * 0.03f); quadraticTo(at.x, at.y - s * 0.07f, at.x + s * 0.07f, at.y + s * 0.03f) },
            ink, style = Stroke(s * 0.045f, cap = StrokeCap.Round),
        )
        Eye.Sad -> {
            drawOval(ink, topLeft = Offset(at.x - s * 0.045f, at.y - s * 0.04f), size = Size(s * 0.09f, s * 0.09f))
            // 안쪽 끝이 올라간 눈썹
            drawLine(ink.copy(alpha = 0.8f), Offset(at.x + side * s * 0.07f, at.y - s * 0.08f), Offset(at.x - side * s * 0.04f, at.y - s * 0.12f), s * 0.03f, StrokeCap.Round)
        }
        Eye.Wide -> {
            drawOval(ink, topLeft = Offset(at.x - s * 0.06f, at.y - s * 0.075f), size = Size(s * 0.12f, s * 0.15f))
            drawCircle(Color.White.copy(alpha = 0.9f), s * 0.02f, Offset(at.x + s * 0.01f, at.y - s * 0.03f))
        }
    }
}

private fun DrawScope.drawMouth(p: Pose, at: Offset, s: Float) {
    when (p.mouth) {
        Mouth.Dash -> drawLine(ink.copy(alpha = 0.8f), Offset(at.x - s * 0.02f, at.y), Offset(at.x + s * 0.02f, at.y), s * 0.025f, StrokeCap.Round)
        Mouth.Small -> drawOval(ink, topLeft = Offset(at.x - s * 0.03f, at.y - s * 0.035f), size = Size(s * 0.06f, s * 0.07f))
        Mouth.Smile, Mouth.Frown -> {
            val up = if (p.mouth == Mouth.Smile) 1f else -1f
            drawPath(
                Path().apply { moveTo(at.x - s * 0.06f, at.y - up * s * 0.02f); quadraticTo(at.x, at.y + up * s * 0.06f, at.x + s * 0.06f, at.y - up * s * 0.02f) },
                ink, style = Stroke(s * 0.04f, cap = StrokeCap.Round),
            )
        }
        Mouth.Yawn -> {
            val h = s * (0.04f + 0.08f * p.yawn)
            drawOval(ink, topLeft = Offset(at.x - s * 0.04f, at.y - h / 2), size = Size(s * 0.08f, h))
        }
    }
}

/** 네 갈래 반짝이 */
private fun star(c: Offset, r: Float) = Path().apply {
    moveTo(c.x, c.y - r)
    quadraticTo(c.x, c.y, c.x + r, c.y)
    quadraticTo(c.x, c.y, c.x, c.y + r)
    quadraticTo(c.x, c.y, c.x - r, c.y)
    quadraticTo(c.x, c.y, c.x, c.y - r)
}

/** 끝이 뾰족한 잎. side가 -1이면 왼쪽 위, 1이면 오른쪽 위로 뻗습니다. */
private fun leafPath(base: Offset, side: Float, width: Float, height: Float): Path = Path().apply {
    val tip = Offset(base.x + side * width, base.y - height)
    moveTo(base.x, base.y)
    quadraticTo(base.x + side * width * 0.1f, tip.y, tip.x, tip.y)
    quadraticTo(tip.x, base.y, base.x, base.y)
}
