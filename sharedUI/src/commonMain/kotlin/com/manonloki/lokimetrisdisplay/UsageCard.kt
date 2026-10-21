package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val UsageBackground = Color(0xFF101E33)
private val UsageForeground = Color(0xFFE9F2FF)
private val UsageMuted = Color(0xFF9BB0C9)

/** 卡片实际宽高决定字号；精简款居中，明细超出时从顶部独立滚动。 */
@Composable
internal fun UsageCard(snapshot: TerminalSnapshot?, panel: PanelConfiguration, canRefresh: Boolean = false, onRefresh: () -> Unit = {}) {
    Surface(modifier = Modifier.fillMaxSize().testTag("usage-card").cyberArrival(0),
        shape = RoundedCornerShape(18.dp), color = UsageBackground, contentColor = UsageForeground,
        border = BorderStroke(1.dp, CyberCyan.copy(alpha = 0.3f))) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            UsageEdgeScan(Modifier.matchParentSize())
            val density = LocalDensity.current
            val scale = minOf(maxWidth.value / 360f, maxHeight.value / 320f).coerceIn(0.85f, 1.4f)
            val padding = ((if (panel.usageDetail == UsageDetail.COMPACT) 16f else 12f) * scale).dp
            val spacing = ((if (panel.usageDetail == UsageDetail.COMPACT) 8f else 5f) * scale).dp
            val detailSize = (12f * scale).sp
            val contentWidth = (maxWidth - padding * 2).coerceAtLeast(1.dp)
            val contentHeight = (maxHeight - padding * 2).coerceAtLeast(0.dp)
            val tokens = snapshot?.tokens
            val compact = panel.usageDetail == UsageDetail.COMPACT || tokens == null
            var headerHeight by remember { mutableIntStateOf(0) }
            var detailsHeight by remember(tokens?.all?.total != null) { mutableIntStateOf(0) }
            val quotas = snapshot?.providerQuota?.providers.orEmpty()
            val summaryHeight = (contentHeight - with(density) { headerHeight.toDp() } - spacing).coerceAtLeast(0.dp)
            val numberHeight = if (compact) {
                // 额度不会反向压缩主数字；卡片变窄时向下滚动查看其余内容。
                val summaryBudget = if (quotas.isEmpty()) summaryHeight else minOf(summaryHeight, (contentHeight * 0.45f).coerceAtLeast(96.dp))
                (summaryBudget - with(density) { detailsHeight.toDp() } - spacing).coerceAtLeast(56.dp)
            } else (contentHeight * 0.22f).coerceAtLeast(40.dp)
            val numberSize = rememberUsageNumberSize(compactTokenAmount(tokens?.all?.text.orEmpty()),
                contentWidth, numberHeight, if (compact) 20.sp else 18.sp, if (compact) 160.sp else 48.sp)
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding),
                verticalArrangement = Arrangement.spacedBy(spacing)) {
                FlowRow(Modifier.fillMaxWidth().onSizeChanged { headerHeight = it.height },
                    horizontalArrangement = Arrangement.SpaceBetween, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Token 用量", fontSize = (13f * scale).sp, lineHeight = (18f * scale).sp,
                        fontWeight = FontWeight.Medium, color = UsageMuted)
                    tokens?.let { Text(it.day.date, fontSize = detailSize, lineHeight = detailSize * 1.4f, color = UsageMuted) }
                    if (canRefresh) TextButton(onClick = onRefresh, modifier = Modifier.testTag("quota-refresh")) { Text("刷新") }
                }
                if (compact) {
                    // 最小高度只补足空白；内容变高后自然撑开，避免居中溢出到滚动起点上方。
                    Column(Modifier.fillMaxWidth().heightIn(min = if (quotas.isEmpty()) summaryHeight else 0.dp).testTag("usage-summary"),
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
                    snapshot?.providerQuota?.takeIf { it.providers.isNotEmpty() }?.let {
                        ProviderQuotaRows(it, detailed = panel.usageDetail != UsageDetail.COMPACT)
                    }
                } else {
                    UsageTotal(tokens.all, numberSize)
                    UsageAmountDetails(tokens.all, detailSize, alignment = Alignment.CenterHorizontally)
                    HorizontalDivider(color = UsageMuted.copy(alpha = 0.2f))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(spacing),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text("设备时区", fontSize = detailSize, color = UsageMuted)
                        Text(tokens.day.zone, modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()).testTag("usage-timezone"),
                            fontSize = detailSize, lineHeight = detailSize * 1.4f, color = UsageMuted,
                            textAlign = TextAlign.End, maxLines = 1, softWrap = false)
                    }
                    val rows = snapshot.displayUsageRows
                    if (rows.isEmpty()) Text("暂无明细", fontSize = (13f * scale).sp,
                        lineHeight = (18f * scale).sp, color = UsageMuted)
                    val agentValueWidth = (contentWidth * 0.55f).coerceAtLeast(1.dp)
                    rows.forEach { row ->
                        val agent = row.tokenAgent
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp * scale)) {
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(spacing),
                                verticalAlignment = Alignment.CenterVertically) {
                                UsageAgentName(row.displayName, scale, Modifier.weight(1f))
                                row.tokenText?.let { UsageAgentTotal(it, (18f * scale).sp, Modifier.widthIn(max = agentValueWidth)) }
                            }
                            if (agent != null) {
                                UsageAgentDetails(agent, row.quota, detailSize)
                            } else {
                                row.quota?.let { provider ->
                                    provider.plan?.let { Text(it, color = UsageMuted, style = MaterialTheme.typography.labelSmall) }
                                    ProviderQuotaWindows(provider, detailed = true)
                                }
                            }
                        }
                    }
                    snapshot.providerQuota?.takeIf { it.providers.isNotEmpty() }?.let {
                        QuotaObservedAt(it)
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

/** 主数字等宽字体样式，测量与绘制共用以保证尺寸一致。 */
private fun usageNumberStyle(size: TextUnit) = TextStyle(fontFamily = FontFamily.Monospace,
    fontSize = size, lineHeight = size * 1.12f, letterSpacing = 0.sp, fontWeight = FontWeight.SemiBold)

/** 总量主数字，数值变化时播放更新过渡。 */
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

/** Agent 名称单行加粗，过长时横向滚动而不截断。 */
@Composable
private fun UsageAgentName(name: String, scale: Float, modifier: Modifier) {
    Text(name, modifier = modifier.horizontalScroll(rememberScrollState()),
        fontSize = (18f * scale).sp, lineHeight = (25f * scale).sp,
        fontWeight = FontWeight.Bold, color = UsageForeground, maxLines = 1, softWrap = false)
}

/** 每月、每周、5h 额度与精确整数共用一行；先给完整数字留宽，极窄时整行横向查看。 */
@Composable
private fun UsageAgentDetails(agent: TerminalAgent, provider: ProviderQuotaEntry?, size: TextUnit) {
    val windows = provider?.windows.orEmpty()
    if (windows.isEmpty()) {
        UsageAmountDetails(agent.amount, size, alignment = Alignment.End)
        return
    }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val density = LocalDensity.current
        val measurer = rememberTextMeasurer()
        val labelStyle = MaterialTheme.typography.labelSmall.copy(fontSize = size, lineHeight = size * 1.4f,
            fontWeight = FontWeight.Medium)
        val exactStyle = labelStyle.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal)
        val exact = if (agent.amount.total != null) exactTokenAmount(agent.amount.text) else null
        val labels = windows.map { "${it.kindLabel} ${it.percentText}" }
        val fixedTextWidth = labels.sumOf { measurer.measure(it, style = labelStyle, softWrap = false).size.width } +
            (exact?.let { measurer.measure(it, style = exactStyle, softWrap = false).size.width } ?: 0)
        val exactCount = if (exact == null) 0 else 1
        val gaps = with(density) { (windows.size * 3 + (windows.size + exactCount) * 6).dp.roundToPx() }
        val barWidth = with(density) { ((maxWidth.roundToPx() - fixedTextWidth - gaps) / windows.size).toDp() }
            .coerceIn(18.dp, 44.dp)
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).widthIn(min = maxWidth)
            .testTag("usage-agent-detail-${agent.agent}"), horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            windows.forEachIndexed { index, window ->
                val color = when (window.level) { 0 -> Color(0xFFFA5252); 1 -> Color(0xFFF5C542); else -> Color(0xFF40C057) }
                val label = window.kindLabel
                val reset = window.resetAtUnix?.let { "，重置 ${formatQuotaTimestamp(it)}" }.orEmpty()
                Row(Modifier.clearAndSetSemantics {
                    contentDescription = "${agent.displayName}，$label 额度剩余 ${window.percentText}$reset"
                }, horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(labels[index], style = labelStyle, color = color, maxLines = 1, softWrap = false)
                    LinearProgressIndicator(progress = { window.remainingTenths / 1000f },
                        modifier = Modifier.width(barWidth).height(3.dp).testTag("quota-inline-${provider?.provider}-${window.kind}"),
                        color = color, trackColor = UsageMuted.copy(alpha = 0.15f))
                }
            }
            Spacer(Modifier.weight(1f))
            exact?.let {
                SelectionContainer {
                    Text(it, modifier = Modifier.semantics { contentDescription = tokenAccessibilityText(agent.amount) },
                        style = exactStyle, color = UsageMuted, maxLines = 1, softWrap = false)
                }
            }
        }
    }
}

/** Agent 用量的 K/M/B 近似值，可选中复制。 */
@Composable
private fun UsageAgentTotal(tokenText: String, size: TextUnit, modifier: Modifier = Modifier) {
    SelectionContainer(modifier) {
        Text(compactTokenAmount(tokenText), modifier = Modifier.horizontalScroll(rememberScrollState()),
            fontFamily = FontFamily.Monospace, fontSize = size, lineHeight = size * 1.35f,
            color = UsageForeground, maxLines = 1, softWrap = false)
    }
}

/** 完整整数按面板对齐，超长时独立横向滚动；质量元信息只保留给辅助功能。 */
@Composable
private fun UsageAmountDetails(amount: TerminalAmount, size: TextUnit, alignment: Alignment.Horizontal = Alignment.Start,
                               modifier: Modifier = Modifier) {
    if (amount.total != null) {
        Box(modifier.fillMaxWidth(), contentAlignment = when (alignment) {
            Alignment.End -> Alignment.CenterEnd
            Alignment.CenterHorizontally -> Alignment.Center
            else -> Alignment.CenterStart
        }) {
            SelectionContainer {
                Text(exactTokenAmount(amount.text), modifier = Modifier.horizontalScroll(rememberScrollState())
                    .semantics { contentDescription = tokenAccessibilityText(amount) },
                    fontFamily = FontFamily.Monospace, fontSize = size, lineHeight = size * 1.4f,
                    color = UsageMuted, maxLines = 1, softWrap = false)
            }
        }
    }
}

private fun tokenAccessibilityText(amount: TerminalAmount): String =
    "Token ${amount.text}" + amount.quality.takeIf { it.isNotEmpty() }?.let { "，$it" }.orEmpty()


/** 额度紧随主数字；缺失窗口不造零，明细时间使用上游观察时间。 */
@Composable
private fun ProviderQuotaRows(quota: ProviderQuotaSnapshot, detailed: Boolean, modifier: Modifier = Modifier, showObservedAt: Boolean = true) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        HorizontalDivider(color = UsageMuted.copy(alpha = 0.2f))
        Text("额度剩余", style = MaterialTheme.typography.labelMedium, color = UsageMuted)
        quota.providers.forEach { provider ->
            BoxWithConstraints(Modifier.fillMaxWidth().testTag("quota-${provider.provider}")) {
                val inlineTitle = maxWidth >= 260.dp && LocalDensity.current.fontScale < 1.3f
                if (inlineTitle) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                        ProviderQuotaTitle(provider, Modifier.weight(0.8f))
                        ProviderQuotaWindows(provider, detailed, Modifier.weight(2f))
                    }
                } else {
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        ProviderQuotaTitle(provider)
                        ProviderQuotaWindows(provider, detailed)
                    }
                }
            }
        }
        if (showObservedAt) QuotaObservedAt(quota)
    }
}

@Composable
private fun QuotaObservedAt(quota: ProviderQuotaSnapshot) {
    Text("额度更新 ${formatQuotaTimestamp(quota.observedAtUnix)}",
        modifier = Modifier.testTag("quota-observed-at"), style = MaterialTheme.typography.labelSmall, color = UsageMuted)
}

@Composable
private fun ProviderQuotaTitle(provider: ProviderQuotaEntry, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(provider.label, color = UsageForeground, style = MaterialTheme.typography.labelLarge)
        provider.plan?.let { Text(it, color = UsageMuted, style = MaterialTheme.typography.labelSmall) }
    }
}

@Composable
private fun ProviderQuotaWindows(provider: ProviderQuotaEntry, detailed: Boolean, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val windows = provider.windows
        if (maxWidth < (240f * LocalDensity.current.fontScale).dp) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                windows.forEach { ProviderQuotaWindowRow(provider, it, detailed) }
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                windows.forEach { ProviderQuotaWindowRow(provider, it, detailed, Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun ProviderQuotaWindowRow(provider: ProviderQuotaEntry, window: ProviderQuotaWindow, detailed: Boolean,
                                   modifier: Modifier = Modifier) {
    val color = when (window.level) { 0 -> Color(0xFFFA5252); 1 -> Color(0xFFF5C542); else -> Color(0xFF40C057) }
    val label = window.kindLabel
    val reset = if (detailed) window.resetAtUnix?.let { "重置 ${formatQuotaTimestamp(it)}" } else null
    Column(modifier.fillMaxWidth().clearAndSetSemantics {
        contentDescription = "${provider.label}，$label 额度剩余 ${window.percentText}" + (reset?.let { "，$it" } ?: "")
    }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End)) {
            Text(label, style = MaterialTheme.typography.labelSmall, color = UsageMuted, modifier = Modifier.weight(1f))
            Text(window.percentText, style = MaterialTheme.typography.labelSmall, color = color, fontWeight = FontWeight.SemiBold)
        }
        LinearProgressIndicator(progress = { window.remainingTenths / 1000f },
            modifier = Modifier.fillMaxWidth().height(4.dp).testTag("quota-${provider.provider}-${window.kind}"),
            color = color, trackColor = UsageMuted.copy(alpha = 0.15f))
        reset?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = UsageMuted) }
    }
}

/** 平台使用用户本地时区和日期格式，不把收到快照的时间冒充上游更新时间。 */
internal expect fun formatQuotaTimestamp(unixSeconds: Long): String
