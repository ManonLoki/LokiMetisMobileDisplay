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
private val UsageAccent = CyberViolet

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
                                UsageAgentName(agent.agent, scale, Modifier)
                                UsageAgentTotal(agent.amount, (18f * scale).sp, Modifier.align(Alignment.End))
                            } else {
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(spacing),
                                    verticalAlignment = Alignment.CenterVertically) {
                                    UsageAgentName(agent.agent, scale, Modifier.weight(1f))
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

/** Agent 用量的 K/M/B 近似值，可选中复制。 */
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
private fun UsageAmountDetails(amount: TerminalAmount, size: TextUnit, alignment: Alignment.Horizontal = Alignment.Start,
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
