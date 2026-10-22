package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/** 两个模块同时启用时等分展示台；用量纵向滚动，Hooks 独立横向分页。 */
@Composable
internal fun PanelPage(state: TerminalLinkView, panel: PanelConfiguration, imageHashes: Set<String>,
                      image: @Composable (String, String, Int) -> Unit, onSettings: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val horizontal = maxWidth > maxHeight
        val padding = if (maxWidth >= 650.dp) 28.dp else 20.dp
        val usage: @Composable () -> Unit = { UsageCard(state.snapshot, panel) }
        val hooks: @Composable () -> Unit = { HooksPane(state, panel.hookLayout, imageHashes, image) }
        Box(Modifier.fillMaxSize().padding(horizontal = padding, vertical = 22.dp).testTag("panel-split")) {
            when {
                panel.showUsage && panel.showHooks -> if (horizontal) {
                    Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.weight(1f).fillMaxHeight()) { usage() }
                        Box(Modifier.weight(1f).fillMaxHeight()) { hooks() }
                    }
                } else {
                    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.weight(1f).fillMaxWidth()) { usage() }
                        Box(Modifier.weight(1f).fillMaxWidth()) { hooks() }
                    }
                }
                panel.showUsage -> usage()
                panel.showHooks -> hooks()
                else -> EmptyPanelCard {
                    Text("暂无卡片", style = MaterialTheme.typography.titleMedium)
                    CyberTextButton(onClick = onSettings) { Text("前往设置") }
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

/** 空槽位占位，按快照状态区分等待同步、不可用与暂无活动。 */
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
                onClickLabel = "查看 ${UsageDisplayPolicy.agentDisplayName(hook.agent)} 的详情", onClick = onClick),
            shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(1.dp, CyberCyan.copy(alpha = 0.2f))) {
            Column(Modifier.fillMaxSize().padding(padding), verticalArrangement = Arrangement.spacedBy(spacing)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom,
                    horizontalArrangement = Arrangement.spacedBy(if (small) 5.dp else 10.dp)) {
                    Text(UsageDisplayPolicy.agentDisplayName(hook.agent), modifier = Modifier.weight(1f), fontSize = if (small) 13.sp else 18.sp,
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

/** 图片区域；未缓存或无图时显示说明文字，命中缓存才交给平台渲染。 */
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
                else -> image(hash, "${UsageDisplayPolicy.agentDisplayName(hook.agent)} 的 Hook 图片", hook.slot)
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
                        Text(UsageDisplayPolicy.agentDisplayName(hook.agent), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
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

/** Hook 行为状态标签，颜色区分运行、询问与错误。 */
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

/** 两个模块都关闭时占满展示台的提示卡；宽屏悬停时提亮边框。 */
@Composable
private fun EmptyPanelCard(content: @Composable ColumnScope.() -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val elevated = hovered && LocalCyberWide.current
    Surface(Modifier.fillMaxSize().cyberArrival(2).hoverable(interaction), shape = RoundedCornerShape(18.dp),
        border = BorderStroke(1.dp, CyberCyan.copy(alpha = if (elevated) 0.4f else 0.14f)),
        shadowElevation = if (elevated) 7.dp else 0.dp, color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp), content = content)
    }
}
