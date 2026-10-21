package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

private enum class DisplayMenu(val title: String) { PANEL("展示台"), SETTINGS("设置") }
private val UsageBackground = Color(0xFF101E33)
private val UsageForeground = Color(0xFFE9F2FF)
private val UsageMuted = Color(0xFF9BB0C9)
private val UsageAccent = CyberViolet

/** 页面编辑本机布局，应用 owner 保持连接与缓存的生命周期。 */
@Composable
fun App(state: TerminalLinkView, onSelect: (String) -> Unit, onForget: (String) -> Unit,
        onSaveName: (String) -> Boolean, onRetry: () -> Unit,
        panelConfiguration: PanelConfiguration = PanelConfiguration(),
        onSavePanel: (PanelConfiguration) -> Boolean = { false },
        imageHashes: Set<String> = emptySet(),
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
        val motionEnabled = rememberCyberMotionEnabled()
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= 700.dp
            CompositionLocalProvider(LocalCyberMotion provides motionEnabled, LocalCyberWide provides wide) {
                CyberBackdrop(Modifier.fillMaxSize())
                Scaffold(containerColor = Color.Transparent, contentColor = colors.onBackground, bottomBar = {
                    if (!wide) NavigationBar(containerColor = colors.surface.copy(alpha = 0.97f), tonalElevation = 0.dp,
                        windowInsets = WindowInsets(0, 0, 0, 0), modifier = Modifier.navigationBarsPadding().height(68.dp)) {
                        DisplayMenu.entries.forEach { destination ->
                            val interaction = remember { MutableInteractionSource() }
                            NavigationBarItem(interactionSource = interaction, modifier = Modifier.cyberPressScale(interaction).testTag("menu-${destination.name.lowercase()}"),
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
                                NavigationRailItem(interactionSource = interaction, modifier = Modifier.cyberPressScale(interaction).padding(bottom = 12.dp).testTag("menu-${destination.name.lowercase()}"),
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
                                            }, onRetry, onSelect, onForget)
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

@Composable
private fun PageHeading(title: String, trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, modifier = Modifier.weight(1f), fontSize = 30.sp, lineHeight = 38.sp,
            letterSpacing = (-0.8).sp, fontWeight = FontWeight.Bold)
        trailing?.invoke()
    }
}

/** 展示台内容由两个模块等分，各自独立滚动。 */
@Composable
private fun PanelPage(state: TerminalLinkView, panel: PanelConfiguration, imageHashes: Set<String>,
                      image: @Composable (String, String, Int) -> Unit, onSettings: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val horizontal = maxWidth > maxHeight
        val padding = if (maxWidth >= 650.dp) 28.dp else 20.dp
        Column(Modifier.fillMaxSize().padding(horizontal = padding, vertical = 22.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().testTag("panel-split")) {
                when {
                    panel.showUsage && panel.showHooks -> {
                        if (horizontal) {
                            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Box(Modifier.weight(1f).fillMaxHeight()) { UsageCard(state.snapshot, panel) }
                                Box(Modifier.weight(1f).fillMaxHeight()) { HooksPane(state, panel.hookLayout, imageHashes, image) }
                            }
                        } else {
                            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Box(Modifier.weight(1f).fillMaxWidth()) { UsageCard(state.snapshot, panel) }
                                Box(Modifier.weight(1f).fillMaxWidth()) { HooksPane(state, panel.hookLayout, imageHashes, image) }
                            }
                        }
                    }
                    panel.showUsage -> UsageCard(state.snapshot, panel)
                    panel.showHooks -> HooksPane(state, panel.hookLayout, imageHashes, image)
                    else -> ContentCard(fill = true) {
                        Text("暂无卡片", style = MaterialTheme.typography.titleMedium)
                        CyberTextButton(onClick = onSettings) { Text("前往设置") }
                    }
                }
            }
        }
    }
}

/** Hooks 独立分页；每页固定一格或四格，最后一页保留空格以维持等分。 */
@Composable
private fun HooksPane(state: TerminalLinkView, layout: HookLayout, imageHashes: Set<String>,
                      image: @Composable (String, String, Int) -> Unit) {
    val snapshot = state.snapshot
    val hooks = snapshot?.takeIf { it.hooksAvailable }?.hooks.orEmpty()
    val pages = layout.pages(hooks)
    var selectedSlot by rememberSaveable { mutableStateOf<Int?>(null) }
    val selectedHook = hooks.find { it.slot == selectedSlot }
    val motion = LocalCyberMotion.current
    LaunchedEffect(selectedSlot, hooks.map { it.slot }) {
        if (selectedSlot != null && selectedHook == null) selectedSlot = null
    }
    Column(Modifier.fillMaxSize().testTag("hooks-pane"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        key(layout) {
            val pager = rememberPagerState(pageCount = { pages.size })
            Box(Modifier.weight(1f).fillMaxWidth()) {
                HorizontalPager(state = pager, modifier = Modifier.fillMaxSize()) { page ->
                    CompositionLocalProvider(LocalCyberMotion provides (motion && pager.currentPage == page && selectedHook == null)) {
                        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            (pages.getOrNull(page) ?: List(layout.pageSize) { null }).chunked(layout.columns).forEachIndexed { row, cells ->
                                Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    cells.forEachIndexed { column, hook ->
                                        Box(Modifier.weight(1f).fillMaxHeight()) {
                                            if (hook == null) HooksEmpty(snapshot, page * layout.pageSize + row * layout.columns + column)
                                            else key(hook.slot) {
                                                HookCard(hook, state.connected, imageHashes, image, showImage = selectedSlot != hook.slot,
                                                    onClick = { selectedSlot = hook.slot })
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (pages.size > 1) Surface(Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp),
                    shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)) {
                    Text("${pager.currentPage + 1} / ${pages.size} · 左右滑动", Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        state.assetWarning?.let { Text(it, modifier = Modifier.heightIn(max = 72.dp).verticalScroll(rememberScrollState()),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
    }
    if (selectedHook != null) HookDetail(selectedHook, state.connected, imageHashes, image, onDismiss = { selectedSlot = null })
}

@Composable
private fun HooksEmpty(snapshot: TerminalSnapshot?, position: Int) {
    Surface(Modifier.fillMaxSize().testTag("hook-placeholder-$position"), shape = RoundedCornerShape(18.dp),
        border = BorderStroke(1.dp, CyberCyan.copy(alpha = 0.12f)), color = MaterialTheme.colorScheme.surface.copy(alpha = 0.7f)) {
        Box(Modifier.fillMaxSize().padding(8.dp), contentAlignment = Alignment.Center) {
            Text(when {
                snapshot == null -> "等待同步"
                !snapshot.hooksAvailable -> "Hooks 暂不可用"
                else -> "暂无活动"
            }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 卡片只显示标题、状态和图片；图片取得扣除实际标题后的全部剩余空间。 */
@Composable
private fun HookCard(hook: TerminalHook, connected: Boolean, imageHashes: Set<String>, image: @Composable (String, String, Int) -> Unit,
                     showImage: Boolean, onClick: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val small = maxWidth < 260.dp || maxHeight < 220.dp
        val padding = minOf(if (small) 10.dp else 18.dp, maxWidth * 0.06f, maxHeight * 0.08f)
        val spacing = minOf(if (small) 6.dp else 10.dp, maxHeight * 0.04f)
        val interaction = remember { MutableInteractionSource() }
        Surface(Modifier.fillMaxSize().testTag("hook-card-${hook.slot}").cyberArrival(2 + hook.slot.coerceAtMost(4))
            .cyberPressScale(interaction).clickable(interactionSource = interaction, indication = null, role = Role.Button,
                onClickLabel = "查看 ${hook.agent} 的详情", onClick = onClick),
            shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(1.dp, CyberCyan.copy(alpha = 0.2f))) {
            Column(Modifier.fillMaxSize().padding(padding), verticalArrangement = Arrangement.spacedBy(spacing)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(if (small) 5.dp else 10.dp)) {
                    Text(hook.agent, modifier = Modifier.weight(1f), fontSize = if (small) 13.sp else 18.sp,
                        lineHeight = if (small) 18.sp else 24.sp, fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    HookStatus(hook, small)
                }
                HookImageViewport(hook, connected, imageHashes, image,
                    modifier = Modifier.weight(1f).fillMaxWidth(), showImage = showImage)
            }
        }
    }
}

@Composable
private fun HookImageViewport(hook: TerminalHook, connected: Boolean, imageHashes: Set<String>,
                              image: @Composable (String, String, Int) -> Unit,
                              modifier: Modifier = Modifier, showImage: Boolean = true) {
    Surface(modifier, shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            val hash = hook.image
            when {
                !showImage -> Unit // 详情接管同一 Drawable 前先移除卡片中的图片视图。
                hash == null -> Text("暂无图片", Modifier.padding(6.dp), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                hash !in imageHashes -> Text(if (connected) "图片尚未缓存" else "图片不在本地缓存中",
                    Modifier.padding(6.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                else -> image(hash, "${hook.agent} 的 Hook 图片", hook.slot)
            }
        }
    }
}

/** 正文与大图保留在详情中；背景同槽图片已移除，避免两个 ImageView 共用动画 Drawable。 */
@Composable
private fun HookDetail(hook: TerminalHook, connected: Boolean, imageHashes: Set<String>,
                       image: @Composable (String, String, Int) -> Unit, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BoxWithConstraints(Modifier.fillMaxWidth().fillMaxHeight(0.92f).padding(16.dp), contentAlignment = Alignment.Center) {
            val imageHeight = maxHeight * 0.7f
            Surface(Modifier.widthIn(max = 900.dp).fillMaxSize().testTag("hook-detail"),
                shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface,
                border = BorderStroke(1.dp, CyberCyan.copy(alpha = 0.3f))) {
                Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("Hook 详情", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        CyberTextButton(onClick = onDismiss, modifier = Modifier.testTag("hook-detail-close")) { Text("关闭") }
                    }
                    Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(hook.agent, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                        HookStatus(hook)
                        if (hook.content.isNotEmpty()) SelectionContainer {
                            Text(hook.content, style = MaterialTheme.typography.bodyLarge, lineHeight = 25.sp)
                        } else Text("暂无正文", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (hook.contentTruncated) Text("正文已截断", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        HookImageViewport(hook, connected, imageHashes, image, Modifier.fillMaxWidth().height(imageHeight))
                    }
                }
            }
        }
    }
}

@Composable
private fun HookStatus(hook: TerminalHook, compact: Boolean = false) {
    val color = when (hook.behavior) {
        "running" -> CyberCyan
        "asking" -> Color(0xFFF4C675)
        "error" -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(color = color.copy(alpha = 0.12f), shape = RoundedCornerShape(8.dp)) {
        Row(Modifier.padding(horizontal = if (compact) 6.dp else 9.dp, vertical = if (compact) 3.dp else 5.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            Canvas(Modifier.size(4.dp)) { drawCircle(color) }
            Text(hook.label, fontSize = if (compact) 10.sp else 11.sp, lineHeight = if (compact) 14.sp else 16.sp,
                color = color, fontWeight = FontWeight.Medium)
        }
    }
}

/** 卡片实际宽高决定字号；精简款居中，明细超出时从顶部独立滚动。 */
@Composable
private fun UsageCard(snapshot: TerminalSnapshot?, panel: PanelConfiguration) {
    Surface(modifier = Modifier.fillMaxSize().testTag("usage-card").cyberArrival(0),
        shape = RoundedCornerShape(18.dp), color = UsageBackground, contentColor = UsageForeground,
        border = BorderStroke(1.dp, CyberCyan.copy(alpha = 0.3f))) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            UsageEdgeScan(Modifier.matchParentSize())
            val density = LocalDensity.current
            val scale = minOf(maxWidth.value / 360f, maxHeight.value / 320f).coerceIn(0.85f, 1.4f)
            val padding = (16f * scale).dp
            val spacing = (8f * scale).dp
            val detailSize = (12f * scale).sp
            val contentWidth = (maxWidth - padding * 2).coerceAtLeast(1.dp)
            val contentHeight = (maxHeight - padding * 2).coerceAtLeast(0.dp)
            val tokens = snapshot?.tokens
            val compact = panel.usageDetail == UsageDetail.COMPACT || tokens == null
            var headerHeight by remember { mutableIntStateOf(0) }
            var detailsHeight by remember { mutableIntStateOf(0) }
            val summaryHeight = (contentHeight - with(density) { headerHeight.toDp() } - spacing).coerceAtLeast(0.dp)
            val numberHeight = if (compact) {
                (summaryHeight - with(density) { detailsHeight.toDp() } - spacing).coerceAtLeast(0.dp)
            } else (contentHeight * 0.32f).coerceAtLeast(40.dp)
            val numberSize = rememberUsageNumberSize(compactTokenAmount(tokens?.all?.text.orEmpty()),
                contentWidth, numberHeight, if (compact) 20.sp else 18.sp, if (compact) 160.sp else 88.sp)
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding),
                verticalArrangement = Arrangement.spacedBy(spacing)) {
                FlowRow(Modifier.fillMaxWidth().onSizeChanged { headerHeight = it.height },
                    horizontalArrangement = Arrangement.SpaceBetween, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Token 用量", fontSize = (13f * scale).sp, lineHeight = (18f * scale).sp,
                        fontWeight = FontWeight.Medium, color = UsageMuted)
                    tokens?.let { Text(it.day.date, fontSize = detailSize, lineHeight = detailSize * 1.4f, color = UsageMuted) }
                }
                if (compact) {
                    // 最小高度只补足空白；内容变高后自然撑开，避免居中溢出到滚动起点上方。
                    Column(Modifier.fillMaxWidth().heightIn(min = summaryHeight).testTag("usage-summary"),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(spacing, Alignment.CenterVertically)) {
                        if (tokens == null) {
                            Text(if (snapshot?.tokenError != null) "暂不可用" else "等待同步",
                                style = MaterialTheme.typography.bodyMedium, color = UsageMuted)
                        } else {
                            UsageTotal(tokens.all, numberSize)
                            UsageAmountDetails(tokens.all, detailSize, alignment = Alignment.CenterHorizontally,
                                modifier = Modifier.onSizeChanged { detailsHeight = it.height })
                        }
                    }
                } else {
                    UsageTotal(tokens.all, numberSize)
                    UsageAmountDetails(tokens.all, detailSize, alignment = Alignment.CenterHorizontally)
                    HorizontalDivider(color = UsageMuted.copy(alpha = 0.2f))
                    Text(tokens.day.zone, modifier = Modifier.horizontalScroll(rememberScrollState()).testTag("usage-timezone"),
                        fontSize = detailSize, lineHeight = detailSize * 1.4f, color = UsageMuted, maxLines = 1, softWrap = false)
                    if (tokens.agents.isEmpty()) Text("暂无明细", fontSize = (13f * scale).sp,
                        lineHeight = (18f * scale).sp, color = UsageMuted)
                    val stackedAgents = contentWidth < 280.dp || density.fontScale >= 1.3f
                    val agentValueWidth = (contentWidth * 0.55f).coerceAtLeast(1.dp)
                    tokens.agents.forEach { agent ->
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(3.dp * scale)) {
                            if (stackedAgents) {
                                Text(agent.agent, modifier = Modifier.horizontalScroll(rememberScrollState()),
                                    fontSize = (18f * scale).sp, lineHeight = (25f * scale).sp,
                                    fontWeight = FontWeight.Bold, color = UsageForeground, maxLines = 1, softWrap = false)
                                UsageAgentTotal(agent.amount, (18f * scale).sp, Modifier.align(Alignment.End))
                            } else {
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(spacing),
                                    verticalAlignment = Alignment.CenterVertically) {
                                    Text(agent.agent, modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                                        fontSize = (18f * scale).sp, lineHeight = (25f * scale).sp,
                                        fontWeight = FontWeight.Bold, color = UsageForeground, maxLines = 1, softWrap = false)
                                    UsageAgentTotal(agent.amount, (18f * scale).sp, Modifier.widthIn(max = agentValueWidth))
                                }
                            }
                            UsageAmountDetails(agent.amount, detailSize, alignment = Alignment.End)
                        }
                    }
                }
            }
        }
    }
}

/** 按真实字形测量宽高，保留最小字号；极窄或大字体时仍可滚动读取完整值。 */
@Composable
private fun rememberUsageNumberSize(value: String, width: Dp, height: Dp, minimum: TextUnit, maximum: TextUnit): TextUnit {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val widthPx = with(density) { width.roundToPx() }.coerceAtLeast(1)
    val heightPx = with(density) { height.roundToPx() }.coerceAtLeast(1)
    return remember(value, widthPx, heightPx, minimum, maximum, density, measurer) {
        var low = minimum.value
        var high = maximum.value
        repeat(10) {
            val candidate = (low + high) / 2f
            val measured = measurer.measure(value, style = usageNumberStyle(candidate.sp), softWrap = false, maxLines = 1)
            if (measured.size.width <= widthPx && measured.size.height <= heightPx) low = candidate else high = candidate
        }
        low.sp
    }
}

private fun usageNumberStyle(size: TextUnit) = TextStyle(fontFamily = FontFamily.Monospace,
    fontSize = size, lineHeight = size * 1.12f, letterSpacing = 0.sp, fontWeight = FontWeight.SemiBold)

@Composable
private fun UsageTotal(amount: TerminalAmount, size: TextUnit) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        SelectionContainer {
            CyberNumber(compactTokenAmount(amount.text)) { value ->
                Text(value, modifier = Modifier.horizontalScroll(rememberScrollState()).testTag("usage-total"),
                    style = usageNumberStyle(size), color = CyberCyan, maxLines = 1, softWrap = false)
            }
        }
    }
}

@Composable
private fun UsageAgentTotal(amount: TerminalAmount, size: TextUnit, modifier: Modifier = Modifier) {
    SelectionContainer(modifier) {
        Text(compactTokenAmount(amount.text), modifier = Modifier.horizontalScroll(rememberScrollState()),
            fontFamily = FontFamily.Monospace, fontSize = size, lineHeight = size * 1.35f,
            color = UsageForeground, maxLines = 1, softWrap = false)
    }
}

/** 常见整数与质量同排；空间不足时质量换行，完整整数独立横向滚动。 */
@Composable
private fun UsageAmountDetails(amount: TerminalAmount, size: TextUnit = 11.sp, alignment: Alignment.Horizontal = Alignment.Start,
                               modifier: Modifier = Modifier) {
    if (amount.total != null || amount.quality.isNotEmpty()) {
        FlowRow(modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp, alignment),
            verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (amount.total != null) SelectionContainer {
                Text(exactTokenAmount(amount.text), modifier = Modifier.horizontalScroll(rememberScrollState()),
                    fontFamily = FontFamily.Monospace, fontSize = size, lineHeight = size * 1.4f,
                    color = UsageMuted, maxLines = 1, softWrap = false)
            }
            if (amount.quality.isNotEmpty()) Text(amount.quality, fontSize = size, lineHeight = size * 1.4f, color = UsageAccent,
                textAlign = when (alignment) {
                    Alignment.End -> TextAlign.End
                    Alignment.CenterHorizontally -> TextAlign.Center
                    else -> TextAlign.Start
                })
        }
    }
}

@Composable
private fun ContentCard(order: Int = 2, fill: Boolean = false, padding: Dp = 18.dp,
                        spacing: Dp = 14.dp, modifier: Modifier = Modifier,
                        content: @Composable ColumnScope.() -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val elevated = hovered && LocalCyberWide.current
    val shapeModifier = if (fill) modifier.fillMaxSize() else modifier.fillMaxWidth()
    Surface(shapeModifier.cyberArrival(order).hoverable(interaction), shape = RoundedCornerShape(18.dp),
        border = BorderStroke(1.dp, CyberCyan.copy(alpha = if (elevated) 0.4f else 0.14f)),
        shadowElevation = if (elevated) 7.dp else 0.dp, color = MaterialTheme.colorScheme.surface) {
        val contentModifier = if (fill) Modifier.fillMaxSize().verticalScroll(rememberScrollState()) else Modifier
        Column(contentModifier.padding(padding), verticalArrangement = Arrangement.spacedBy(spacing), content = content)
    }
}

/** 设置使用更安静的表面；主题、交互反馈与主面板保持一致。 */
@Composable
private fun SettingsCard(order: Int = 0, content: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxWidth().cyberArrival(order), shape = RoundedCornerShape(22.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.065f))) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}

@Composable
private fun SettingsSection(title: String, note: String? = null, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), fontSize = 13.sp, lineHeight = 19.sp, fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            note?.let { Text(it, fontSize = 11.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        content()
    }
}

@Composable
private fun SettingsDivider() {
    HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f))
}

private enum class SettingsSymbol { USAGE, HOOKS, DESKTOP, DEVICE }

/** 小图标只提供视觉定位，不额外占用辅助功能焦点。 */
@Composable
private fun SettingsIcon(symbol: SettingsSymbol) {
    Surface(shape = RoundedCornerShape(11.dp), color = CyberCyan.copy(alpha = 0.09f)) {
        Canvas(Modifier.size(38.dp).padding(10.dp).clearAndSetSemantics {}) {
            val stroke = 1.6.dp.toPx()
            when (symbol) {
                SettingsSymbol.USAGE -> {
                    for (i in 0..2) {
                        val x = size.width * (0.16f + i * 0.34f)
                        drawLine(CyberCyan, Offset(x, size.height * (0.58f - i * 0.22f)),
                            Offset(x, size.height * 0.9f), stroke * 1.8f, StrokeCap.Round)
                    }
                }
                SettingsSymbol.HOOKS -> {
                    val gap = 3.dp.toPx()
                    val cell = (size.width - gap) / 2
                    for (x in 0..1) for (y in 0..1) drawRoundRect(CyberCyan,
                        Offset(x * (cell + gap), y * (cell + gap)), Size(cell, cell), CornerRadius(1.5.dp.toPx()), style = Stroke(stroke))
                }
                SettingsSymbol.DESKTOP -> {
                    drawRoundRect(CyberCyan, size = Size(size.width, size.height * 0.7f),
                        cornerRadius = CornerRadius(2.dp.toPx()), style = Stroke(stroke))
                    drawLine(CyberCyan, Offset(size.width * 0.5f, size.height * 0.7f), Offset(size.width * 0.5f, size.height), stroke)
                    drawLine(CyberCyan, Offset(size.width * 0.25f, size.height), Offset(size.width * 0.75f, size.height), stroke, StrokeCap.Round)
                }
                SettingsSymbol.DEVICE -> {
                    drawRoundRect(CyberCyan, Offset(size.width * 0.18f, 0f), Size(size.width * 0.64f, size.height),
                        CornerRadius(2.5.dp.toPx()), style = Stroke(stroke))
                    drawLine(CyberCyan, Offset(size.width * 0.4f, size.height * 0.82f), Offset(size.width * 0.6f, size.height * 0.82f), stroke, StrokeCap.Round)
                }
            }
        }
    }
}

@Composable
private fun SettingsPage(state: TerminalLinkView, panel: PanelConfiguration, name: String, nameFeedback: String?, panelError: String?,
                         onNameChange: (String) -> Unit, onSaveName: () -> Unit, onPanelChange: (PanelConfiguration) -> Unit,
                         onRetry: () -> Unit, onSelect: (String) -> Unit, onForget: (String) -> Unit) {
    BoxWithConstraints(Modifier.widthIn(max = 1100.dp).fillMaxSize()) {
        val wide = maxWidth >= 720.dp
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(horizontal = if (wide) 28.dp else 20.dp, vertical = 22.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                PageHeading("设置")
                Text("面板显示与设备连接", fontSize = 13.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (wide) Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp)) {
                    SettingsSection("面板显示", "自动保存") { PanelSettings(panel, panelError, onPanelChange) }
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp)) {
                    SettingsSection("桌面连接") { ConnectionSettings(state, onRetry, onSelect, onForget) }
                    SettingsSection("本机") { DeviceSettings(state, name, nameFeedback, onNameChange, onSaveName) }
                }
            } else {
                SettingsSection("面板显示", "自动保存") { PanelSettings(panel, panelError, onPanelChange) }
                SettingsSection("桌面连接") { ConnectionSettings(state, onRetry, onSelect, onForget) }
                SettingsSection("本机") { DeviceSettings(state, name, nameFeedback, onNameChange, onSaveName) }
            }
        }
    }
}

@Composable
private fun PanelSettings(panel: PanelConfiguration, panelError: String?, onPanelChange: (PanelConfiguration) -> Unit) {
    SettingsCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SettingsToggle("Token 用量", "总量与 Agent 消耗", SettingsSymbol.USAGE, panel.showUsage,
                { onPanelChange(panel.copy(showUsage = it)) }, "settings-show-usage")
            if (panel.showUsage) {
                Row(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    UsageDetail.entries.forEach { detail ->
                        SettingsChoice(if (detail == UsageDetail.COMPACT) "精简" else "详细", panel.usageDetail == detail,
                            preview = if (detail == UsageDetail.COMPACT) 0 else 1,
                            onClick = { onPanelChange(panel.copy(usageDetail = detail)) },
                            modifier = Modifier.weight(1f).testTag("settings-usage-${detail.key}"))
                    }
                }
                Text(if (panel.usageDetail == UsageDetail.COMPACT) "突出总 Token 用量" else "显示总量与各 Agent 明细",
                    fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        SettingsDivider()
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SettingsToggle("Hooks", "图文与实时状态", SettingsSymbol.HOOKS, panel.showHooks,
                { onPanelChange(panel.copy(showHooks = it)) }, "settings-show-hooks")
            if (panel.showHooks) {
                Row(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    HookLayout.entries.forEach { layout ->
                        SettingsChoice(if (layout == HookLayout.SINGLE) "1 × 1" else "2 × 2", panel.hookLayout == layout,
                            preview = if (layout == HookLayout.SINGLE) 2 else 3,
                            onClick = { onPanelChange(panel.copy(hookLayout = layout)) },
                            modifier = Modifier.weight(1f).testTag("settings-hooks-${layout.key}"))
                    }
                }
                Text(if (panel.hookLayout == HookLayout.SINGLE) "每页一张，完整展示图片" else "每页四张，左右翻页查看更多",
                    fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (!panel.showUsage && !panel.showHooks) Text("开启一项内容，即可在展示台中显示。",
            fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        panelError?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
    }
}

@Composable
private fun SettingsToggle(title: String, subtitle: String, symbol: SettingsSymbol, checked: Boolean, onChange: (Boolean) -> Unit, tag: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp)
        .toggleable(checked, role = Role.Switch, onValueChange = onChange).testTag(tag),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        SettingsIcon(symbol)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
            Text(subtitle, fontSize = 11.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = null, colors = SwitchDefaults.colors(
            checkedTrackColor = CyberCyan, checkedThumbColor = Color(0xFF0A2530),
            uncheckedTrackColor = Color(0xFF233247), uncheckedBorderColor = Color.Transparent,
            uncheckedThumbColor = MaterialTheme.colorScheme.onSurfaceVariant))
    }
}

@Composable
private fun SettingsChoice(title: String, selected: Boolean, preview: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val interaction = remember { MutableInteractionSource() }
    Surface(modifier.cyberPressScale(interaction).selectable(selected, interactionSource = interaction,
        indication = ripple(), role = Role.RadioButton, onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        color = if (selected) CyberCyan.copy(alpha = 0.08f) else MaterialTheme.colorScheme.background.copy(alpha = 0.4f),
        border = BorderStroke(1.dp, if (selected) CyberCyan.copy(alpha = 0.65f) else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.09f))) {
        Column(Modifier.padding(horizontal = 10.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            SettingsMiniature(preview, selected)
            Text(title, fontSize = 13.sp, lineHeight = 19.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                color = if (selected) CyberCyan else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 布局示意不填充伪造的用量或状态数据。 */
@Composable
private fun SettingsMiniature(kind: Int, selected: Boolean) {
    val color = if (selected) CyberCyan else MaterialTheme.colorScheme.onSurfaceVariant
    Canvas(Modifier.size(44.dp, 26.dp).clearAndSetSemantics {}) {
        val stroke = 1.dp.toPx()
        val corner = CornerRadius(2.dp.toPx())
        if (kind < 2) {
            drawRoundRect(color.copy(alpha = 0.35f), size = size, cornerRadius = corner, style = Stroke(stroke))
            drawLine(color, Offset(size.width * 0.24f, size.height * 0.38f),
                Offset(size.width * 0.76f, size.height * 0.38f), 3.dp.toPx(), StrokeCap.Round)
            if (kind == 0) drawLine(color.copy(alpha = 0.45f), Offset(size.width * 0.34f, size.height * 0.68f),
                Offset(size.width * 0.66f, size.height * 0.68f), stroke, StrokeCap.Round)
            else for (i in 0..2) drawRoundRect(color.copy(alpha = 0.35f),
                Offset(size.width * (0.15f + i * 0.25f), size.height * 0.62f),
                Size(size.width * 0.2f, size.height * 0.17f), CornerRadius(1.dp.toPx()))
        } else {
            val columns = if (kind == 2) 1 else 2
            val gap = 3.dp.toPx()
            val width = (size.width - gap * (columns - 1)) / columns
            val height = (size.height - gap * (columns - 1)) / columns
            for (x in 0 until columns) for (y in 0 until columns) {
                drawRoundRect(color.copy(alpha = 0.15f), Offset(x * (width + gap), y * (height + gap)), Size(width, height), corner)
                drawRoundRect(color.copy(alpha = 0.8f), Offset(x * (width + gap), y * (height + gap)), Size(width, height), corner, style = Stroke(stroke))
            }
        }
    }
}

@Composable
private fun DeviceSettings(state: TerminalLinkView, name: String, feedback: String?, onNameChange: (String) -> Unit, onSaveName: () -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    SettingsCard(order = 2) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SettingsIcon(SettingsSymbol.DEVICE)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("设备名称", fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
                Text("在桌面端识别这台设备", fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        val error = MdnsProtocol.nameError(name)
        OutlinedTextField(value = name, onValueChange = onNameChange,
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = "设备名称" }.testTag("settings-device-name"),
            singleLine = true, isError = error != null, textStyle = MaterialTheme.typography.bodyMedium,
            supportingText = if (error == null) null else ({ Text(error) }), shape = RoundedCornerShape(12.dp))
        if (name != state.deviceName) CyberButton(onClick = onSaveName,
            enabled = error == null && MdnsProtocol.isCanonicalDeviceId(state.deviceId),
            modifier = Modifier.fillMaxWidth().testTag("settings-save-name")) { Text("保存名称") }
        feedback?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        SettingsDivider()
        CyberTextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp),
            modifier = Modifier.fillMaxWidth().testTag("settings-device-info")) {
            Text("设备信息", Modifier.weight(1f), fontSize = 13.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(if (expanded) "收起 −" else "展开 +", fontSize = 12.sp)
        }
        if (expanded) {
            Text("设备 ID", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            SelectionContainer { Text(state.deviceId.ifEmpty { "身份暂不可用" }, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace) }
            Text("LokiMetris Display", fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 用户选择候选才开启配对窗口，忘记操作保留明确确认。 */
@Composable
private fun ConnectionSettings(state: TerminalLinkView, onRetry: () -> Unit, onSelect: (String) -> Unit, onForget: (String) -> Unit) {
    var forgetting by rememberSaveable { mutableStateOf<String?>(null) }
    SettingsCard(order = 1) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SettingsIcon(SettingsSymbol.DESKTOP)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    CyberConnectionDot(state.connected)
                    Text(if (state.connected) "已连接桌面" else if (state.pairingCode != null) "等待完成配对" else "自动发现桌面",
                        fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
                }
                Text(state.status, fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("devices-status"))
            }
        }
        state.error?.let {
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            CyberOutlinedButton(onClick = onRetry, enabled = MdnsProtocol.isCanonicalDeviceId(state.deviceId), modifier = Modifier.testTag("devices-retry")) { Text("重试连接") }
        }
        state.pairingCode?.let { code ->
            Surface(color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.55f), shape = RoundedCornerShape(14.dp)) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("在桌面输入配对码", fontSize = 12.sp, lineHeight = 18.sp, color = CyberCyan)
                    SelectionContainer { Text(code, fontSize = 38.sp, letterSpacing = 8.sp, fontWeight = FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace, modifier = Modifier.testTag("devices-pair-code")) }
                    Text("60 秒内有效 · 保持应用在前台", fontSize = 11.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        if (state.hosts.isEmpty()) {
            SettingsDivider()
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("还未发现桌面", fontSize = 13.sp, lineHeight = 19.sp, fontWeight = FontWeight.Medium)
                Text("在同一 Wi-Fi 下打开桌面端，并允许本地网络访问。", fontSize = 12.sp,
                    lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        state.hosts.forEach { host ->
            SettingsDivider()
            val connected = state.connected && state.selectedId == host.id
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Text(host.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        Text(when {
                            connected -> "已连接 · 正在同步"
                            host.paired && host.available -> "已配对 · 可连接"
                            host.paired -> "已配对 · 暂未发现"
                            else -> "可配对"
                        }, fontSize = 12.sp, lineHeight = 18.sp, color = if (connected) CyberCyan else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (!connected) CyberOutlinedButton(onClick = { onSelect(host.id) }, enabled = host.available,
                        modifier = Modifier.testTag("host-connect-${host.id}")) { Text(if (host.paired) "连接" else "配对", fontSize = 13.sp) }
                }
                if (host.paired) CyberTextButton(onClick = { forgetting = host.id }, contentPadding = PaddingValues(0.dp),
                    modifier = Modifier.testTag("host-forget-${host.id}")) {
                    Text("忘记此桌面", fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    forgetting?.let { id ->
        AlertDialog(onDismissRequest = { forgetting = null }, title = { Text("忘记此桌面？") },
            text = { Text("将删除本机配对凭据。再次连接需要重新配对；桌面端的记录需在桌面设备管理中移除。") },
            confirmButton = { CyberTextButton(onClick = { onForget(id); forgetting = null }) { Text("忘记") } },
            dismissButton = { CyberTextButton(onClick = { forgetting = null }) { Text("取消") } })
    }
}

/** 预览不创建原生桥，也不伪造已同步的数据。 */
@Preview
@Composable
private fun DisplayPreview() {
    App(TerminalLinkView("12345678-1234-4abc-8def-123456789abc", MdnsProtocol.DEFAULT_NAME), {}, {}, { false }, {})
}
