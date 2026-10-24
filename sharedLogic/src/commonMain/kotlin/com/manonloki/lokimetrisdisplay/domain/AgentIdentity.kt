package com.manonloki.lokimetrisdisplay.domain

import com.manonloki.lokimetrisdisplay.rules.normalizeComparisonText

/** Agent 身份匹配与启用名单语义；快照校验和各端展示过滤共用，不含展示文字。 */
object AgentIdentity {
    /** 只改变匹配键，不改变认证标识、缓存键、自定义名称或原始快照。 */
    fun canonicalAgentKey(raw: String): String = when (val key = normalizeComparisonText(raw.lowercase().filterNot {
        it == '_' || it == '-' || it.isWhitespace()
    })) {
        "claude", "claudecode" -> "claude"
        "grok", "grokbuild" -> "grok"
        "gemini", "geminicli" -> "gemini"
        "githubcopilot", "githubcopilotcli" -> "githubcopilot"
        else -> key
    }

    /** 只关联有真实额度接口的提供商，未知名称不猜测。 */
    fun providerQuotaKey(agent: String): String? = canonicalAgentKey(agent).takeIf {
        it in listOf("codex", "claude", "cursor", "grok")
    }

    fun isEnabled(agent: String, enabledAgents: List<String>?): Boolean =
        enabledAgents?.any { canonicalAgentKey(it) == canonicalAgentKey(agent) } ?: true

    /** 可直接用于 Swift 的损坏输入边界，异常不会穿过语言边界。 */
    fun validEnabledAgents(enabledAgents: List<String>?): Boolean = enabledAgents == null ||
        enabledAgents.size <= 14 && enabledAgents.all {
            it.isNotEmpty() && it.encodeToByteArray().size <= 64 && canonicalAgentKey(it).isNotEmpty()
        } && enabledAgents.distinct().size == enabledAgents.size &&
        enabledAgents.map(::canonicalAgentKey).distinct().size == enabledAgents.size
}
