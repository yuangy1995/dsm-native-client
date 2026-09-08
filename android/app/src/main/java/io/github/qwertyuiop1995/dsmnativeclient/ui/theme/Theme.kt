package io.github.qwertyuiop1995.dsmnativeclient.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val LightColors = lightColorScheme(
    primary = Color(0xFF2455ED), onPrimary = Color.White,
    primaryContainer = Color(0xFFE9EFFF), onPrimaryContainer = Color(0xFF173788),
    secondary = Color(0xFF4D5D7B), onSecondary = Color.White,
    secondaryContainer = Color(0xFFEDF1F8), onSecondaryContainer = Color(0xFF22314B),
    tertiary = Color(0xFF715315), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFEBC0), onTertiaryContainer = Color(0xFF382700),
    background = Color(0xFFFAFAF8), onBackground = Color(0xFF17201F),
    surface = Color(0xFFFFFFFF), onSurface = Color(0xFF17201F),
    surfaceVariant = Color(0xFFF0F1F3), onSurfaceVariant = Color(0xFF59616C),
    outline = Color(0xFF737C88), outlineVariant = Color(0xFFE0E3E9),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF8F9FB),
    surfaceContainer = Color(0xFFF3F5F8), surfaceContainerHigh = Color(0xFFEBEEF3),
    surfaceContainerHighest = Color(0xFFE3E7ED),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFA5BBFF), onPrimary = Color(0xFF002879),
    primaryContainer = Color(0xFF253963), onPrimaryContainer = Color(0xFFDDE6FF),
    secondary = Color(0xFFBAC6E0), onSecondary = Color(0xFF243249),
    secondaryContainer = Color(0xFF293345), onSecondaryContainer = Color(0xFFDFE6F5),
    tertiary = Color(0xFFE6C275), onTertiary = Color(0xFF3C2B00),
    tertiaryContainer = Color(0xFF54431E), onTertiaryContainer = Color(0xFFFFE8B4),
    background = Color(0xFF11151B), onBackground = Color(0xFFE5E9F1),
    surface = Color(0xFF171C25), onSurface = Color(0xFFE5E9F1),
    surfaceVariant = Color(0xFF2A313E), onSurfaceVariant = Color(0xFFB7C0CF),
    outline = Color(0xFF8D97A8), outlineVariant = Color(0xFF333C4B),
    surfaceContainerLowest = Color(0xFF0D1117), surfaceContainerLow = Color(0xFF171C25),
    surfaceContainer = Color(0xFF1C2330), surfaceContainerHigh = Color(0xFF262F3F),
    surfaceContainerHighest = Color(0xFF303B4E),
)

val AppShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp), small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(16.dp), large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(24.dp),
)

private val AppTypography = Typography(
    titleLarge = TextStyle(fontSize = 20.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = TextStyle(fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold),
    titleSmall = TextStyle(fontSize = 14.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 22.sp),
    bodySmall = TextStyle(fontSize = 12.sp, lineHeight = 18.sp),
    labelLarge = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium),
    labelMedium = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium),
)

@Composable
fun LanStashTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colors = if (dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        if (darkTheme) dynamicDarkColorScheme(LocalContext.current) else dynamicLightColorScheme(LocalContext.current)
    } else if (darkTheme) DarkColors else LightColors
    MaterialTheme(colorScheme = colors, shapes = AppShapes, typography = AppTypography, content = content)
}
