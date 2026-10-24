package com.manonloki.lokimetrisdisplay.presentation

import com.manonloki.lokimetrisdisplay.domain.AgentIdentity

/** 行只引用原始数组位置；原生宿主不必复制或改写用于编码的 Token 与额度对象。 */
data class UsageRowReference(val tokenIndex: Int, val quotaIndex: Int)

/** Android、iOS、Widget 与 Watch 共用的展示规则，不拥有平台视图或持久化格式。 */
object UsageDisplayPolicy {
    /** 未同步且没有明确名单时不补零；只有 Cursor 缺数字才有默认零展示。 */
    const val ZERO_DEFAULT_PROVIDER = "cursor"
    const val ZERO_DEFAULT_TOKEN_TEXT = "0"

    fun agentDisplayName(raw: String): String = when (AgentIdentity.canonicalAgentKey(raw)) {
        "codex" -> "Codex"
        "claude" -> "Claude Code"
        "grok" -> "Grok"
        "workbuddy" -> "WorkBuddy"
        "cursor" -> "Cursor"
        "opencode" -> "OpenCode"
        "hermes" -> "Hermes"
        "openclaw" -> "OpenClaw"
        "codebuddy" -> "CodeBuddy"
        "qwencode" -> "Qwen Code"
        "kimicode" -> "Kimi Code"
        "qoder" -> "Qoder"
        "gemini" -> "Gemini CLI"
        "githubcopilot" -> "GitHub Copilot"
        else -> raw
    }

    /** 未知 Agent 保持原始相对顺序，WorkBuddy 留到最后。 */
    fun displayRank(agent: String): Int = when (AgentIdentity.canonicalAgentKey(agent)) {
        "codex" -> 0
        "claude" -> 1
        "cursor" -> 2
        "grok" -> 3
        "workbuddy" -> 5
        else -> 4
    }

    /** 过滤仅返回引用位置，不改总量、统计质量、日期或序列化顺序。 */
    fun visibleIndices(names: List<String>, enabledAgents: List<String>?): List<Int> =
        names.indices.filter { AgentIdentity.isEnabled(names[it], enabledAgents) }

    /** Token 与额度各自筛选，再按共享身份合并；引用始终指向输入的原始数组。 */
    fun projectRows(tokensPresent: Boolean, tokenNames: List<String>, quotaProviders: List<String>,
                    enabledAgents: List<String>?): List<UsageRowReference> {
        val tokens = visibleIndices(tokenNames, enabledAgents)
        val quotas = visibleIndices(quotaProviders, enabledAgents)
        val matchedKeys = tokens.mapNotNull { AgentIdentity.providerQuotaKey(tokenNames[it]) }.toSet()
        val rows = tokens.map { index -> UsageRowReference(index,
            quotas.firstOrNull { quotaProviders[it] == AgentIdentity.providerQuotaKey(tokenNames[index]) } ?: -1)
        } + quotas.filterNot { quotaProviders[it] in matchedKeys }.map { UsageRowReference(-1, it) }
        fun source(row: UsageRowReference): String = when {
            row.tokenIndex >= 0 -> tokenNames[row.tokenIndex]
            row.quotaIndex >= 0 -> quotaProviders[row.quotaIndex]
            else -> ZERO_DEFAULT_PROVIDER
        }
        val showCursor = (tokensPresent || enabledAgents != null) && AgentIdentity.isEnabled(ZERO_DEFAULT_PROVIDER, enabledAgents)
        val default = if (showCursor && rows.none { AgentIdentity.providerQuotaKey(source(it)) == ZERO_DEFAULT_PROVIDER })
            listOf(UsageRowReference(-1, -1)) else emptyList()
        return (rows + default).sortedBy { displayRank(source(it)) }
    }

    /** 默认零仅用于展示，不能写回 Token 数字或制造额度窗口。 */
    fun tokenText(sourceName: String, amountText: String?, hasNumericValue: Boolean): String? =
        if (AgentIdentity.providerQuotaKey(sourceName) == ZERO_DEFAULT_PROVIDER && !hasNumericValue) ZERO_DEFAULT_TOKEN_TEXT else amountText

    /** 各平台可保留现有质量文字间距，文字含义只维护一份。 */
    fun amountQuality(completeness: String, confidence: String, separator: String): String = listOfNotNull(
        when (completeness) { "partial" -> "部分"; "unknown" -> "范围未知"; else -> null },
        when (confidence) { "derived" -> "估算"; "suspected" -> "待核对"; else -> null },
    ).joinToString(separator)

    fun hookLabel(behavior: String): String = when (behavior) {
        "idle" -> "空闲"; "running" -> "运行"; "asking" -> "询问"; else -> "出错"
    }
}
