package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private enum class DisplayMenu(val title: String) { PANEL("展示台"), SETTINGS("设置") }

/** 页面编辑本机布局，应用 owner 保持连接与缓存的生命周期。 */
@Composable
fun App(state: TerminalLinkView, onSelect: (String) -> Unit, onForget: (String) -> Unit,
        onSaveName: (String) -> Boolean, onRetry: () -> Unit,
        panelConfiguration: PanelConfiguration = PanelConfiguration(),
        onSavePanel: (PanelConfiguration) -> Boolean = { false },
        imageHashes: Set<String> = emptySet(),
        applicationName: String = "LokiMetris",
        motionEnabled: Boolean = false,
        quotaTimestamp: (Long) -> String = { it.toString() },
        platformSettings: @Composable () -> Unit = {},
        image: @Composable (String, String, Int) -> Unit = { _, _, _ -> }) {
    var selected by rememberSaveable { mutableStateOf(DisplayMenu.PANEL.name) }
    var name by rememberSaveable(state.deviceId, state.deviceName) { mutableStateOf(state.deviceName) }
    var nameFeedback by rememberSaveable { mutableStateOf<String?>(null) }
    var panelError by rememberSaveable { mutableStateOf<String?>(null) }
    val menu = DisplayMenu.entries.find { it.name == selected } ?: DisplayMenu.PANEL
    val pages = rememberSaveableStateHolder()
    val colors = darkColorScheme(
        primary = CyberCyan, onPrimary = Color(0xFF06252E),
        secondary = CyberViolet, onSecondary = Color(0xFF21103B),
        primaryContainer = Color(0xFF123D50), onPrimaryContainer = CyberCyan,
        secondaryContainer = Color(0xFF2C244A), onSecondaryContainer = Color(0xFFDCCEFF),
        background = Color(0xFF080D17), surface = Color(0xFF111D2D),
        surfaceContainer = Color(0xFF17243A), surfaceContainerLow = Color(0xFF111D2D),
        onBackground = Color(0xFFE9F2FF), onSurface = Color(0xFFE9F2FF), onSurfaceVariant = Color(0xFF96ABC5),
        outline = Color(0xFF60849C), outlineVariant = Color(0xFF244052),
        error = Color(0xFFFF8B9C), onError = Color(0xFF420E1C),
    )
    MaterialTheme(colorScheme = colors) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= 700.dp
            CompositionLocalProvider(LocalCyberMotion provides motionEnabled, LocalCyberWide provides wide,
                LocalQuotaTimestamp provides quotaTimestamp) {
                CyberBackdrop(Modifier.fillMaxSize())
                Scaffold(containerColor = Color.Transparent, contentColor = colors.onBackground, bottomBar = {
                    if (!wide) NavigationBar(containerColor = colors.surface.copy(alpha = 0.97f), tonalElevation = 0.dp,
                        windowInsets = WindowInsets(0, 0, 0, 0), modifier = Modifier.navigationBarsPadding().height(68.dp)) {
                        DisplayMenu.entries.forEach { destination ->
                            val interaction = remember { MutableInteractionSource() }
                            NavigationBarItem(interactionSource = interaction, modifier = Modifier.menuItem(destination, interaction),
                                selected = menu == destination, onClick = { selected = destination.name },
                                icon = { MenuIcon(destination) }, label = { Text(destination.title, fontSize = 11.sp) },
                                colors = NavigationBarItemDefaults.colors(indicatorColor = colors.primaryContainer))
                        }
                    }
                }) { insets ->
                    Row(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).safeDrawingPadding()) {
                        if (wide) NavigationRail(containerColor = Color.Transparent, modifier = Modifier.width(104.dp).fillMaxHeight(),
                            header = { BrandMark(Modifier.padding(top = 16.dp, bottom = 30.dp)) }) {
                            DisplayMenu.entries.forEach { destination ->
                                val interaction = remember { MutableInteractionSource() }
                                NavigationRailItem(interactionSource = interaction, modifier = Modifier.menuItem(destination, interaction).padding(bottom = 12.dp),
                                    selected = menu == destination, onClick = { selected = destination.name },
                                    icon = { MenuIcon(destination) }, label = { Text(destination.title) },
                                    colors = NavigationRailItemDefaults.colors(indicatorColor = colors.primaryContainer))
                            }
                        }
                        Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
                            pages.SaveableStateProvider(menu.name) {
                                key(menu.name) {
                                    when (menu) {
                                        DisplayMenu.PANEL -> PanelPage(state, panelConfiguration, imageHashes, image,
                                            onSettings = { selected = DisplayMenu.SETTINGS.name })
                                        DisplayMenu.SETTINGS -> SettingsPage(state, panelConfiguration, name, nameFeedback, panelError,
                                            onNameChange = { name = it; nameFeedback = null }, onSaveName = {
                                                nameFeedback = if (onSaveName(name)) "已保存，下次连接生效" else "保存失败，请重试"
                                            }, onPanelChange = { value ->
                                                panelError = if (onSavePanel(value)) null else "面板设置保存失败，请重试"
                                            }, onRetry, onSelect, onForget, platformSettings, applicationName)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 底栏与侧栏导航项共用的按压反馈与测试标签。 */
@Composable
private fun Modifier.menuItem(destination: DisplayMenu, interaction: MutableInteractionSource): Modifier =
    cyberPressScale(interaction).testTag("menu-${destination.name.lowercase()}")

/** 侧栏顶部的品牌标识，纯描画且不进入读屏焦点。 */
@Composable
private fun BrandMark(modifier: Modifier = Modifier) {
    Surface(modifier.size(38.dp), shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.primary) {
        Canvas(Modifier.padding(10.dp).clearAndSetSemantics {}) {
            drawLine(Color(0xFF06252E), Offset(0f, 0f), Offset(0f, size.height), 3.dp.toPx(), StrokeCap.Round)
            drawLine(Color(0xFF06252E), Offset(0f, size.height), Offset(size.width, size.height), 3.dp.toPx(), StrokeCap.Round)
            drawCircle(Color(0xFF06252E), 2.5.dp.toPx(), Offset(size.width, 2.5.dp.toPx()))
        }
    }
}

/** 使用同一套原生描画图标，无额外字体或资源依赖。 */
@Composable
private fun MenuIcon(menu: DisplayMenu) {
    val color = LocalContentColor.current
    Canvas(Modifier.size(21.dp).clearAndSetSemantics {}) {
        val stroke = 1.8.dp.toPx()
        if (menu == DisplayMenu.PANEL) {
            val gap = 3.5.dp.toPx()
            val cell = (size.width - gap) / 2
            for (x in 0..1) for (y in 0..1) drawRoundRect(color, Offset(x * (cell + gap), y * (cell + gap)),
                Size(cell, cell), CornerRadius(2.dp.toPx()))
        } else {
            for (row in 0..2) {
                val y = size.height * (0.2f + row * 0.3f)
                val x = size.width * if (row == 1) 0.68f else 0.32f
                drawLine(color, Offset(0f, y), Offset(size.width, y), stroke, StrokeCap.Round)
                drawCircle(color, 3.dp.toPx(), Offset(x, y))
            }
        }
    }
}

/** 页面大标题，统一字号与字距。 */
@Composable
internal fun PageHeading(title: String) {
    Text(title, modifier = Modifier.fillMaxWidth(), fontSize = 30.sp, lineHeight = 38.sp,
        letterSpacing = (-0.8).sp, fontWeight = FontWeight.Bold)
}
