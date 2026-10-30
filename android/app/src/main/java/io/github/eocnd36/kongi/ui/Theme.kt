package io.github.eocnd36.kongi.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/** 상태 색 (Material 색 체계 밖): 진행, 완료, 주의, 실패 */
@Immutable
data class StatusColors(
    val green: Color,
    val orange: Color,
    val red: Color,
    val yellow: Color,
    val blue: Color,
    val added: Color,
    val addedBackground: Color,
    val removed: Color,
    val removedBackground: Color,
    val code: Color,
)

private val darkStatus = StatusColors(
    green = Color(0xFF4ADE80),
    orange = Color(0xFFFF9F0A),
    red = Color(0xFFFF6B60),
    yellow = Color(0xFFFFD60A),
    blue = Color(0xFF64A8FF),
    added = Color(0xFF7EE29A),
    addedBackground = Color(0x2434C759),
    removed = Color(0xFFFF8B82),
    removedBackground = Color(0x24FF453A),
    code = Color(0xFF0C0E0D),
)

private val lightStatus = StatusColors(
    green = Color(0xFF1E9E52),
    orange = Color(0xFFD9770B),
    red = Color(0xFFD93025),
    yellow = Color(0xFFB98900),
    blue = Color(0xFF1F6FD1),
    added = Color(0xFF16733A),
    addedBackground = Color(0x2234C759),
    removed = Color(0xFFB3261E),
    removedBackground = Color(0x1FFF453A),
    code = Color(0xFFF0F3F1),
)

val LocalStatus = staticCompositionLocalOf { darkStatus }

private val dark = darkColorScheme(
    primary = Color(0xFFA8E6B5),
    onPrimary = Color(0xFF053219),
    primaryContainer = Color(0xFF1E3B28),
    onPrimaryContainer = Color(0xFFC6F3D0),
    secondary = Color(0xFFB4CCBB),
    onSecondary = Color(0xFF203527),
    secondaryContainer = Color(0xFF2A3A2F),
    onSecondaryContainer = Color(0xFFD0E8D6),
    tertiary = Color(0xFFFFD60A),
    background = Color(0xFF050605),
    onBackground = Color(0xFFE6EAE7),
    surface = Color(0xFF050605),
    onSurface = Color(0xFFE6EAE7),
    surfaceVariant = Color(0xFF1C211E),
    onSurfaceVariant = Color(0xFF9AA59E),
    surfaceContainerLowest = Color(0xFF000000),
    surfaceContainerLow = Color(0xFF0E110F),
    surfaceContainer = Color(0xFF131715),
    surfaceContainerHigh = Color(0xFF1A1F1C),
    surfaceContainerHighest = Color(0xFF232925),
    outline = Color(0xFF3A433D),
    outlineVariant = Color(0xFF262D29),
    error = Color(0xFFFF8A80),
    onError = Color(0xFF3B0A06),
    errorContainer = Color(0xFF5C1712),
    onErrorContainer = Color(0xFFFFDAD5),
)

private val light = lightColorScheme(
    primary = Color(0xFF2B7A45),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFC8EFD2),
    onPrimaryContainer = Color(0xFF062A14),
    secondary = Color(0xFF4F6355),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFD2E8D7),
    onSecondaryContainer = Color(0xFF0D1F13),
    tertiary = Color(0xFF8A6A00),
    background = Color(0xFFF7FAF7),
    onBackground = Color(0xFF181D1A),
    surface = Color(0xFFF7FAF7),
    onSurface = Color(0xFF181D1A),
    surfaceVariant = Color(0xFFDDE5DF),
    onSurfaceVariant = Color(0xFF424A45),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color(0xFFF1F5F2),
    surfaceContainer = Color(0xFFEBF0EC),
    surfaceContainerHigh = Color(0xFFE5EBE7),
    surfaceContainerHighest = Color(0xFFDFE6E1),
    outline = Color(0xFF727B75),
    outlineVariant = Color(0xFFC2CBC5),
    error = Color(0xFFB3261E),
)

@Composable
fun KongiTheme(content: @Composable () -> Unit) {
    val darkTheme = isSystemInDarkTheme()
    CompositionLocalProvider(LocalStatus provides if (darkTheme) darkStatus else lightStatus) {
        MaterialTheme(colorScheme = if (darkTheme) dark else light, content = content)
    }
}
