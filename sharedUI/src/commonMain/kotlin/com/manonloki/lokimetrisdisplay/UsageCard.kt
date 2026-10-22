package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
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
internal fun UsageCard(snapshot: TerminalSnapshot?, panel: PanelConfiguration) {
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
            val detailBarWidth = when {
                contentWidth.value / density.fontScale >= 440f -> 44.dp
                contentWidth.value / density.fontScale >= 280f -> 28.dp
                else -> 18.dp
            }
            val tokens = snapshot?.displayTokens
            val compact = panel.usageDetail == UsageDetail.COMPACT
            var headerHeight by remember { mutableIntStateOf(0) }
            var detailsHeight by remember(tokens?.all?.total != null) { mutableIntStateOf(0) }
            val quotas = snapshot?.displayProviderQuota?.providers.orEmpty()
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
                    snapshot?.displayProviderQuota?.takeIf { it.providers.isNotEmpty() }?.let {
                        ProviderQuotaRows(it)
                    }
                } else {
                    if (tokens != null) {
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
                    } else {
                        Text(if (snapshot?.tokenError != null) "暂不可用" else "等待同步",
                            style = MaterialTheme.typography.bodyMedium, color = UsageMuted)
                    }
                    val rows = snapshot?.displayUsageRows.orEmpty()
                    if (rows.isEmpty()) Text("暂无明细", fontSize = (13f * scale).sp,
                        lineHeight = (18f * scale).sp, color = UsageMuted)
                    val agentValueWidth = (contentWidth * 0.55f).coerceAtLeast(1.dp)
                    rows.forEach { row ->
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp * scale)) {
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(spacing),
                                verticalAlignment = Alignment.CenterVertically) {
                                ProviderTitle(row.displayName, row.quota?.planLabel,
                                    TextStyle(fontSize = (18f * scale).sp, lineHeight = (25f * scale).sp,
                                        fontWeight = FontWeight.Bold), Modifier.weight(1f))
                                row.tokenText?.let { UsageAgentTotal(it, (18f * scale).sp, Modifier.widthIn(max = agentValueWidth)) }
                            }
                            UsageRowDetails(row, detailSize, detailBarWidth)
                        }
                    }
                    snapshot?.displayProviderQuota?.takeIf { it.providers.isNotEmpty() }?.let {
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

/** 名称与套餐标识底部对齐并整体横向滚动，不占用数字或额度的宽度。 */
@Composable
private fun ProviderTitle(name: String, planLabel: String?, nameStyle: TextStyle, modifier: Modifier = Modifier) {
    Row(modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Bottom) {
        Text(name, style = nameStyle, color = UsageForeground, maxLines = 1, softWrap = false)
        planLabel?.let { label ->
            Surface(shape = RoundedCornerShape(4.dp), color = CyberCyan.copy(alpha = 0.08f),
                contentColor = CyberCyan, border = BorderStroke(0.5.dp, CyberCyan.copy(alpha = 0.3f))) {
                Text(label, modifier = Modifier.padding(horizontal = 5.dp, vertical = 1.dp),
                    style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp, lineHeight = 14.sp,
                        fontWeight = FontWeight.Medium), maxLines = 1, softWrap = false)
            }
        }
    }
}

/** 所有明细共用卡片确定的短条宽度；完整整数不缩小，极窄时整行横向查看。 */
@Composable
private fun UsageRowDetails(row: TerminalUsageRow, size: TextUnit, barWidth: Dp) {
    val windows = row.quota?.windows.orEmpty()
    val exact = row.tokenText?.takeIf { row.tokenAgent?.amount?.hasNumericValue == true || it == "0" }?.let(::exactTokenAmount)
    if (windows.isEmpty() && exact == null) return
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val labelStyle = quotaCaptionStyle(size)
        val percentStyle = labelStyle.copy(fontFamily = FontFamily.Monospace)
        val exactStyle = labelStyle.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal)
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).widthIn(min = maxWidth)
            .testTag("usage-agent-detail-${row.tokenAgent?.agent ?: row.quota?.provider ?: "cursor"}"), horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            windows.forEach { window ->
                val color = quotaRemainingColor(window)
                Row(Modifier.clearAndSetSemantics {
                    contentDescription = quotaAccessibilityText(row.displayName, window)
                }, horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(window.kindLabel, style = labelStyle, color = UsageMuted, maxLines = 1, softWrap = false)
                    Text(window.percentText, style = percentStyle, color = color, maxLines = 1, softWrap = false)
                    QuotaBalanceBar(window, Modifier.width(barWidth).testTag("quota-inline-${row.quota?.provider}-${window.kind}"))
                }
            }
            Spacer(Modifier.weight(1f))
            exact?.let {
                SelectionContainer {
                    Text(it, modifier = Modifier.semantics { contentDescription = usageRowTokenAccessibilityText(row) },
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

private fun usageRowTokenAccessibilityText(row: TerminalUsageRow): String {
    val amount = row.tokenAgent?.amount
    return "Token ${row.tokenText}" + amount?.takeIf { !it.hasNumericValue }?.let { "，${it.text}" }.orEmpty() +
        amount?.quality?.takeIf { it.isNotEmpty() }?.let { "，$it" }.orEmpty()
}

@Composable
private fun quotaCaptionStyle(size: TextUnit = MaterialTheme.typography.labelSmall.fontSize): TextStyle =
    MaterialTheme.typography.labelSmall.copy(fontSize = size, lineHeight = size * 1.4f, fontWeight = FontWeight.Medium)

private fun quotaRemainingColor(window: ProviderQuotaWindow): Color = when (window.level) {
    0 -> Color(0xFFFA5252); 1 -> Color(0xFFF5C542); else -> Color(0xFF40C057)
}

/** 所有额度使用连续余额条，不添加末端圆点或活动轨间隙。 */
@Composable
private fun QuotaBalanceBar(window: ProviderQuotaWindow, modifier: Modifier = Modifier) {
    val color = quotaRemainingColor(window)
    Canvas(modifier.height(3.dp)) {
        val radius = CornerRadius(size.height / 2f)
        drawRoundRect(UsageMuted.copy(alpha = 0.15f), cornerRadius = radius)
        if (window.remainingTenths > 0) {
            drawRoundRect(color, size = Size(size.width * window.remainingTenths / 1000f, size.height), cornerRadius = radius)
        }
    }
}

private fun quotaAccessibilityText(name: String, window: ProviderQuotaWindow): String =
    "$name，${window.kindLabel} 额度剩余 ${window.percentText}" +
        window.resetAtUnix?.let { "，重置 ${formatQuotaTimestamp(it)}" }.orEmpty()


/** 额度紧随主数字；缺失窗口不造零，明细时间使用上游观察时间。 */
@Composable
private fun ProviderQuotaRows(quota: ProviderQuotaSnapshot, modifier: Modifier = Modifier, showObservedAt: Boolean = true) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        HorizontalDivider(color = UsageMuted.copy(alpha = 0.2f))
        Text("额度剩余", style = MaterialTheme.typography.labelMedium, color = UsageMuted)
        quota.providers.forEach { provider ->
            BoxWithConstraints(Modifier.fillMaxWidth().testTag("quota-${provider.provider}")) {
                val inlineTitle = maxWidth >= 260.dp && LocalDensity.current.fontScale < 1.3f
                if (inlineTitle) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                        ProviderQuotaTitle(provider, Modifier.weight(0.8f))
                        ProviderQuotaWindows(provider, Modifier.weight(2f))
                    }
                } else {
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        ProviderQuotaTitle(provider)
                        ProviderQuotaWindows(provider)
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
    ProviderTitle(provider.label, provider.planLabel, MaterialTheme.typography.labelLarge, modifier)
}

@Composable
private fun ProviderQuotaWindows(provider: ProviderQuotaEntry, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val windows = provider.windows
        if (maxWidth < (240f * LocalDensity.current.fontScale).dp) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                windows.forEach { ProviderQuotaWindowRow(provider, it) }
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                windows.forEach { ProviderQuotaWindowRow(provider, it, Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun ProviderQuotaWindowRow(provider: ProviderQuotaEntry, window: ProviderQuotaWindow,
                                   modifier: Modifier = Modifier) {
    val color = quotaRemainingColor(window)
    val label = window.kindLabel
    val captionStyle = quotaCaptionStyle()
    Column(modifier.fillMaxWidth().clearAndSetSemantics {
        contentDescription = quotaAccessibilityText(provider.label, window)
    }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End)) {
            Text(label, style = captionStyle, color = UsageMuted, modifier = Modifier.weight(1f))
            Text(window.percentText, style = captionStyle.copy(fontFamily = FontFamily.Monospace), color = color)
        }
        QuotaBalanceBar(window, Modifier.fillMaxWidth().testTag("quota-${provider.provider}-${window.kind}"))
    }
}

/** 平台使用用户本地时区和日期格式，不把收到快照的时间冒充上游更新时间。 */
internal expect fun formatQuotaTimestamp(unixSeconds: Long): String
