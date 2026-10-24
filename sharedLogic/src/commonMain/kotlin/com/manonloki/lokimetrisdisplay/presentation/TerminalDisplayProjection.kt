package com.manonloki.lokimetrisdisplay.presentation

import com.manonloki.lokimetrisdisplay.domain.ProviderQuotaEntry
import com.manonloki.lokimetrisdisplay.domain.TerminalAgent
import com.manonloki.lokimetrisdisplay.domain.TerminalAmount
import com.manonloki.lokimetrisdisplay.domain.TerminalHook
import com.manonloki.lokimetrisdisplay.domain.TerminalSnapshot

/** 非序列化UI投影；两者皆空即缺失Cursor的默认零行，不参与统计或额度。 */
data class TerminalUsageRow(val tokenAgent: TerminalAgent?, val quota: ProviderQuotaEntry?) {
    internal val sourceName: String get() = tokenAgent?.agent ?: quota?.provider ?: UsageDisplayPolicy.ZERO_DEFAULT_PROVIDER
    val displayName: String get() = tokenAgent?.displayName ?: quota?.label ?: UsageDisplayPolicy.agentDisplayName(sourceName)
    /** 与Swift `WidgetUsageRow.presentation` 同一规则：默认零提供方缺数字时显示0。 */
    val tokenText: String? get() = UsageDisplayPolicy.tokenText(sourceName,
        tokenAgent?.amount?.text, tokenAgent?.amount?.hasNumericValue == true)
}

/** 行位置由跨平台展示策略计算，宿主只映射回原始领域对象。 */
val TerminalSnapshot.displayUsageRows: List<TerminalUsageRow> get() {
    val agents = tokens?.agents.orEmpty()
    val quotas = providerQuota?.providers.orEmpty()
    return UsageDisplayPolicy.projectRows(tokens != null, agents.map { it.agent },
        quotas.map { it.provider }, enabledAgents).map {
        TerminalUsageRow(agents.getOrNull(it.tokenIndex), quotas.getOrNull(it.quotaIndex))
    }
}

/** 保留部分或推算质量供宿主展示；界面可通过辅助功能描述提供这些信息。 */
val TerminalAmount.quality: String get() = UsageDisplayPolicy.amountQuality(completeness, confidence, " · ")

val TerminalAgent.displayName: String get() = UsageDisplayPolicy.agentDisplayName(agent)

/** 只表达已接收的桌面状态，离线时由展示页整体标记缓存。 */
val TerminalHook.label: String get() = UsageDisplayPolicy.hookLabel(behavior)
