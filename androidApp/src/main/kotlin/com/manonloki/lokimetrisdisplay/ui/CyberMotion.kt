package com.manonloki.lokimetrisdisplay

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Shape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

internal val CyberCyan = Color(0xFF67E8F9)
internal val CyberViolet = Color(0xFFAE8CFF)
internal val LocalCyberMotion = staticCompositionLocalOf { false }
internal val LocalCyberWide = staticCompositionLocalOf { false }

/** 仅在可见、前台且系统允许动画时运行；取消协程即停止帧请求。 */
@Composable
private fun rememberCyberPhase(enabled: Boolean, durationMillis: Int): State<Float> {
    val phase = remember { Animatable(0f) }
    LaunchedEffect(enabled, durationMillis) {
        phase.snapTo(0f)
        // 无限重复由同一动画驱动，循环衔接不再额外停顿一帧；取消协程即停止。
        if (enabled) phase.animateTo(1f, infiniteRepeatable(tween(durationMillis, easing = LinearEasing), RepeatMode.Restart))
    }
    return phase.asState()
}

/** 装饰画布没有语义节点，不接收手势。 */
@Composable
internal fun CyberBackdrop(modifier: Modifier = Modifier) {
    Canvas(modifier.clearAndSetSemantics {}) {
        drawRect(Color(0xFF080D17))
        drawRect(Brush.radialGradient(listOf(CyberCyan.copy(alpha = 0.11f), Color.Transparent),
            center = Offset(size.width * 0.02f, size.height * 0.06f), radius = size.width * 0.85f))
        drawRect(Brush.radialGradient(listOf(CyberViolet.copy(alpha = 0.09f), Color.Transparent),
            center = Offset(size.width, size.height * 0.62f), radius = size.width * 0.82f))
        val step = 24.dp.toPx()
        var x = 0f
        while (x < size.width) {
            drawLine(CyberCyan.copy(alpha = 0.035f), Offset(x, 0f), Offset(x, size.height), 0.5.dp.toPx())
            x += step
        }
        var y = 0f
        while (y < size.height) {
            drawLine(CyberCyan.copy(alpha = 0.035f), Offset(0f, y), Offset(size.width, y), 0.5.dp.toPx())
            y += step
        }
    }
}

@Composable
internal fun Modifier.cyberArrival(order: Int = 0): Modifier {
    val enabled = LocalCyberMotion.current
    val progress = remember { Animatable(0f) }
    var completed by remember { mutableStateOf(false) }
    LaunchedEffect(enabled) {
        if (!enabled || completed) progress.snapTo(1f)
        else {
            progress.snapTo(0f)
            delay(order.coerceIn(0, 6) * 65L)
            progress.animateTo(1f, tween(420))
            completed = true
        }
    }
    return this.graphicsLayer {
        alpha = progress.value
        translationY = (1f - progress.value) * 18.dp.toPx()
        scaleX = 0.98f + progress.value * 0.02f
        scaleY = scaleX
    }
}

@Composable
internal fun UsageEdgeScan(modifier: Modifier = Modifier) {
    var visible by remember { mutableStateOf(false) }
    val phase = rememberCyberPhase(LocalCyberMotion.current && visible, 7_000)
    Canvas(modifier.onGloballyPositioned { visible = !it.boundsInWindow().isEmpty }.clearAndSetSemantics {}) {
        val x = phase.value * size.width * 3f - size.width
        val brush = Brush.linearGradient(listOf(CyberCyan.copy(alpha = 0.04f), CyberCyan.copy(alpha = 0.8f),
            CyberViolet.copy(alpha = 0.45f), CyberCyan.copy(alpha = 0.04f)),
            start = Offset(x - size.width * 0.5f, 0f), end = Offset(x + size.width * 0.5f, size.height))
        drawRoundRect(brush, cornerRadius = CornerRadius(18.dp.toPx()), style = Stroke(1.dp.toPx()))
        drawLine(CyberCyan.copy(alpha = 0.045f), Offset(x, 0f), Offset(x - size.height * 0.35f, size.height), 22.dp.toPx())
    }
}

@Composable
internal fun CyberConnectionDot(connected: Boolean) {
    var visible by remember { mutableStateOf(false) }
    val phase = rememberCyberPhase(LocalCyberMotion.current && connected && visible, 1_800)
    Canvas(Modifier.size(9.dp).onGloballyPositioned { visible = !it.boundsInWindow().isEmpty }.clearAndSetSemantics {}) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val color = if (connected) CyberCyan else Color(0xFF8FA4BC)
        if (connected) drawCircle(color.copy(alpha = (1f - phase.value) * 0.4f),
            radius = (3f + 1.4f * phase.value).dp.toPx(), center = center)
        drawCircle(color, radius = 2.5.dp.toPx(), center = center)
    }
}

@Composable
internal fun CyberNumber(value: String, content: @Composable (String) -> Unit) {
    if (LocalCyberMotion.current) AnimatedContent(targetState = value,
        transitionSpec = {
            (fadeIn(tween(240)) + slideInVertically(tween(300)) { it / 3 })
                .togetherWith(fadeOut(tween(150)) + slideOutVertically(tween(220)) { -it / 3 })
        }, label = "token-value") { content(it) }
    else content(value)
}

@Composable
internal fun Modifier.cyberPressScale(interactionSource: MutableInteractionSource): Modifier {
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed && LocalCyberMotion.current) 0.96f else 1f,
        tween(if (LocalCyberMotion.current) 120 else 0), label = "control-press")
    return this.graphicsLayer { scaleX = scale; scaleY = scale }
}

@Composable
internal fun CyberTextButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true,
    contentPadding: PaddingValues = ButtonDefaults.TextButtonContentPadding, content: @Composable RowScope.() -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    TextButton(onClick, modifier.cyberPressScale(interaction), enabled, contentPadding = contentPadding,
        interactionSource = interaction, content = content)
}

@Composable
internal fun CyberButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true,
    shape: Shape = RoundedCornerShape(12.dp), content: @Composable RowScope.() -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    Button(onClick, modifier.cyberPressScale(interaction), enabled, shape = shape,
        interactionSource = interaction, content = content)
}

@Composable
internal fun CyberOutlinedButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    OutlinedButton(onClick, modifier.cyberPressScale(interaction), enabled,
        interactionSource = interaction, content = content)
}
