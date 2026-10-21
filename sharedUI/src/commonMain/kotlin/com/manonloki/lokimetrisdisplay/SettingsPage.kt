package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 设置使用更安静的表面；主题、交互反馈与主面板保持一致。 */
@Composable
private fun SettingsCard(order: Int = 0, content: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxWidth().cyberArrival(order), shape = RoundedCornerShape(22.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.065f))) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}

/** 分组标题与可选右侧说明，内容由调用方提供。 */
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

/** 卡片内的低对比分隔线。 */
@Composable
private fun SettingsDivider() {
    HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f))
}

/** 设置项左侧图标种类。 */
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

/** 设置页：面板显示、桌面连接与本机信息；宽屏分两栏。 */
@Composable
internal fun SettingsPage(state: TerminalLinkView, panel: PanelConfiguration, name: String, nameFeedback: String?, panelError: String?,
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
            val panelSection: @Composable () -> Unit = {
                SettingsSection("面板显示", "自动保存") { PanelSettings(panel, panelError, onPanelChange) }
            }
            val deviceSections: @Composable () -> Unit = {
                SettingsSection("桌面连接") { ConnectionSettings(state, onRetry, onSelect, onForget) }
                SettingsSection("本机") { DeviceSettings(state, name, nameFeedback, onNameChange, onSaveName) }
            }
            // 宽屏左右两栏，窄屏按同一顺序纵向排列。
            if (wide) Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp)) { panelSection() }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp)) { deviceSections() }
            } else {
                panelSection()
                deviceSections()
            }
        }
    }
}

/** Token 与 Hooks 的开关及显示选项，修改即时保存。 */
@Composable
private fun PanelSettings(panel: PanelConfiguration, panelError: String?, onPanelChange: (PanelConfiguration) -> Unit) {
    SettingsCard {
        PanelOptionGroup("Token 用量", "总量与 Agent 消耗", SettingsSymbol.USAGE, panel.showUsage,
            { onPanelChange(panel.copy(showUsage = it)) }, "settings-show-usage",
            UsageOptions, panel.usageDetail) { onPanelChange(panel.copy(usageDetail = it)) }
        SettingsDivider()
        PanelOptionGroup("Hooks", "图文与实时状态", SettingsSymbol.HOOKS, panel.showHooks,
            { onPanelChange(panel.copy(showHooks = it)) }, "settings-show-hooks",
            HookOptions, panel.hookLayout) { onPanelChange(panel.copy(hookLayout = it)) }
        if (!panel.showUsage && !panel.showHooks) Text("开启一项内容，即可在展示台中显示。",
            fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        panelError?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
    }
}

/** 单个显示选项的文案、布局示意、测试标签与选中后的说明。 */
private class PanelOption<T>(val value: T, val title: String, val miniature: Miniature, val tag: String, val caption: String)

private val UsageOptions = listOf(
    PanelOption(UsageDetail.COMPACT, "精简", Miniature.USAGE_COMPACT, "settings-usage-${UsageDetail.COMPACT.key}", "突出总 Token 用量"),
    PanelOption(UsageDetail.DETAILED, "详细", Miniature.USAGE_DETAILED, "settings-usage-${UsageDetail.DETAILED.key}", "显示总量与各 Agent 明细"),
)

private val HookOptions = listOf(
    PanelOption(HookLayout.SINGLE, "1 × 1", Miniature.HOOKS_SINGLE, "settings-hooks-${HookLayout.SINGLE.key}", "每页一张，完整展示图片"),
    PanelOption(HookLayout.GRID, "2 × 2", Miniature.HOOKS_GRID, "settings-hooks-${HookLayout.GRID.key}", "每页四张，左右翻页查看更多"),
)

/** 模块开关；开启后展开单选行与当前选项说明。 */
@Composable
private fun <T> PanelOptionGroup(title: String, subtitle: String, symbol: SettingsSymbol, enabled: Boolean,
                                 onEnabledChange: (Boolean) -> Unit, toggleTag: String,
                                 options: List<PanelOption<T>>, selected: T, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SettingsToggle(title, subtitle, symbol, enabled, onEnabledChange, toggleTag)
        if (enabled) {
            Row(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                options.forEach { option ->
                    SettingsChoice(option.title, option.value == selected, preview = option.miniature,
                        onClick = { onSelect(option.value) }, modifier = Modifier.weight(1f).testTag(option.tag))
                }
            }
            options.firstOrNull { it.value == selected }?.let {
                Text(it.caption, fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** 整行可点击的开关项，读屏按 Switch 角色朗读。 */
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

/** 带布局示意的单选项，读屏按 RadioButton 角色朗读。 */
@Composable
private fun SettingsChoice(title: String, selected: Boolean, preview: Miniature, onClick: () -> Unit, modifier: Modifier = Modifier) {
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

/** 设置选项旁的布局示意种类。 */
private enum class Miniature { USAGE_COMPACT, USAGE_DETAILED, HOOKS_SINGLE, HOOKS_GRID }

/** 布局示意不填充伪造的用量或状态数据。 */
@Composable
private fun SettingsMiniature(kind: Miniature, selected: Boolean) {
    val color = if (selected) CyberCyan else MaterialTheme.colorScheme.onSurfaceVariant
    Canvas(Modifier.size(44.dp, 26.dp).clearAndSetSemantics {}) {
        val stroke = 1.dp.toPx()
        val corner = CornerRadius(2.dp.toPx())
        if (kind == Miniature.USAGE_COMPACT || kind == Miniature.USAGE_DETAILED) {
            drawRoundRect(color.copy(alpha = 0.35f), size = size, cornerRadius = corner, style = Stroke(stroke))
            drawLine(color, Offset(size.width * 0.24f, size.height * 0.38f),
                Offset(size.width * 0.76f, size.height * 0.38f), 3.dp.toPx(), StrokeCap.Round)
            if (kind == Miniature.USAGE_COMPACT) drawLine(color.copy(alpha = 0.45f), Offset(size.width * 0.34f, size.height * 0.68f),
                Offset(size.width * 0.66f, size.height * 0.68f), stroke, StrokeCap.Round)
            else for (i in 0..2) drawRoundRect(color.copy(alpha = 0.35f),
                Offset(size.width * (0.15f + i * 0.25f), size.height * 0.62f),
                Size(size.width * 0.2f, size.height * 0.17f), CornerRadius(1.dp.toPx()))
        } else {
            val columns = if (kind == Miniature.HOOKS_SINGLE) 1 else 2
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

/** 本机名称编辑与折叠的设备信息；名称改动后才显示保存按钮。 */
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
