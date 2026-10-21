package com.manonloki.lokimetrisdisplay

/** 已认证完整快照的宿主无关投影；数字保留十进制u64，不重新统计桌面用量。 */
data class TerminalSnapshot(
    val version: Int, val tokens: TerminalTokens?, val tokenError: String?,
    val hooksAvailable: Boolean, val hooks: List<TerminalHook>,
    val assets: List<TerminalAsset>, val catalogError: String?,
    val providerQuota: ProviderQuotaSnapshot? = null,
) {
    /** 合并真实Token明细和独立额度，只有额度的账户也按面板优先级显示。 */
    val displayUsageRows: List<TerminalUsageRow> get() {
        val agents = tokens?.agents.orEmpty()
        val quotas = providerQuota?.providers.orEmpty()
        val matchedKeys = agents.mapNotNull { providerQuotaKey(it.agent) }.toSet()
        return (agents.map { agent ->
            TerminalUsageRow(agent, quotas.firstOrNull { it.provider == providerQuotaKey(agent.agent) })
        } + quotas.filterNot { it.provider in matchedKeys }.map { TerminalUsageRow(null, it) })
            .sortedBy { displayAgentOrder(it.tokenAgent?.agent ?: requireNotNull(it.quota).provider) }
    }

    /** 网络消息共用语义校验，未来版本、重复槽位或缺值不能冒充有效数据。 */
    fun validate() {
        require(version == 1 && hooks.size <= 12 && assets.size <= 64)
        require(hooks.map { it.slot }.distinct().size == hooks.size)
        require(assets.map { it.hash }.distinct().size == assets.size)
        require(hooksAvailable || hooks.isEmpty())
        require(tokenError == null || tokens == null)
        require(tokenError == null || tokenError.encodeToByteArray().size <= 512)
        require(catalogError == null || catalogError.encodeToByteArray().size <= 512)
        providerQuota?.validate(); tokens?.validate(); hooks.forEach { it.validate() }; assets.forEach { it.validate() }
    }
}

/** 单项用量与可用性、覆盖资格和置信度保持绑定。 */
data class TerminalAmount(val total: String?, val availability: String, val completeness: String, val confidence: String) {
    /** 零值与无记录分离，非规范整数、溢出或未知质量拒绝进入展示。 */
    fun validate() {
        require(availability in listOf("available", "noRecords", "unavailable"))
        require(completeness in listOf("complete", "partial", "unknown"))
        require(confidence in listOf("exact", "derived", "suspected"))
        if (availability == "available") require(total != null && canonicalUnsigned(total)) else require(total == null)
    }
    /** UI显示精确原值，不经Double或缩略换算。 */
    val text: String get() = when (availability) { "available" -> total ?: "—"; "noRecords" -> "无记录"; else -> "不可用" }
    /** 部分或推算质量始终可见，不把不完整统计当作精确总量。 */
    val quality: String get() = listOfNotNull(when (completeness) { "partial" -> "部分"; "unknown" -> "范围未知"; else -> null },
        when (confidence) { "derived" -> "估算"; "suspected" -> "待核对"; else -> null }).joinToString(" · ")
}

/** 统计日期只接受 yyyy-MM-dd；预编译避免每份快照重复构造。 */
private val DAY_PATTERN = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")

/** 桌面同轮统计日界；毫秒不替换为手机时区。 */
data class TerminalDay(val date: String, val zone: String, val startMs: Long, val endMs: Long)
/** 单个Agent组件与总量保留同一观测时刻。 */
data class TerminalAgent(val agent: String, val amount: TerminalAmount) {
    val displayName: String get() = agentDisplayName(agent)
}

/** 只规范展示名；认证标识、缓存键和自定义名称保持原样。 */
fun agentDisplayName(raw: String): String = when (normalizedAgentName(raw)) {
    "codex" -> "Codex"
    "claude", "claudecode" -> "Claude Code"
    "grok", "grokbuild" -> "Grok"
    "workbuddy" -> "WorkBuddy"
    "cursor" -> "Cursor"
    "opencode" -> "OpenCode"
    "hermes" -> "Hermes"
    "openclaw" -> "OpenClaw"
    "codebuddy" -> "CodeBuddy"
    "qwencode" -> "Qwen Code"
    "kimicode" -> "Kimi Code"
    "qoder" -> "Qoder"
    "gemini", "geminicli" -> "Gemini CLI"
    "githubcopilot", "githubcopilotcli" -> "GitHub Copilot"
    else -> raw
}

/** 仅把有真实额度接口的Agent关联到提供商，未知名称不猜测。 */
fun providerQuotaKey(agent: String): String? = when (normalizedAgentName(agent)) {
    "codex" -> "codex"
    "claude", "claudecode" -> "claude"
    "cursor" -> "cursor"
    "grok", "grokbuild" -> "grok"
    else -> null
}

private fun normalizedAgentName(raw: String): String = raw.lowercase().filterNot { it == '_' || it == '-' || it.isWhitespace() }

/** 只改变展示顺序；未指定的Agent保持相对次序，WorkBuddy留到最后。 */
private fun displayAgentOrder(raw: String): Int = when (normalizedAgentName(raw)) {
    "codex" -> 0
    "claude", "claudecode" -> 1
    "cursor" -> 2
    "grok", "grokbuild" -> 3
    "workbuddy" -> 5
    else -> 4
}

/** Token与额度独立可缺失，不为只有额度的账户补造用量。 */
data class TerminalUsageRow(val tokenAgent: TerminalAgent?, val quota: ProviderQuotaEntry?) {
    val displayName: String get() = tokenAgent?.displayName ?: requireNotNull(quota).label
}

/** 完整Token总量及分Agent投影。 */
data class TerminalTokens(val day: TerminalDay, val observedMs: Long, val all: TerminalAmount, val agents: List<TerminalAgent>) {
    /** 各宿主共用的展示优先级，不修改快照中的统计次序。 */
    val displayAgents: List<TerminalAgent> get() = agents.sortedBy { displayAgentOrder(it.agent) }

    /** 日界、观测和唯一Agent来自同一快照，不在移动端重算日期或补零。 */
    fun validate() {
        require(DAY_PATTERN.matches(day.date) && day.zone.encodeToByteArray().size <= 256)
        require(day.startMs < day.endMs && observedMs >= day.startMs && observedMs < day.endMs)
        require(agents.size <= 14 && agents.map { it.agent }.distinct().size == agents.size)
        all.validate(); agents.forEach { require(validAgent(it.agent)); it.amount.validate() }
    }
}

/** Hook使用桌面最终槽位四态，正文和图像引用不会进入配对或系统日志。 */
data class TerminalHook(val agent: String, val slot: Int, val behavior: String, val content: String, val contentTruncated: Boolean, val image: String?) {
    /** 有限槽位、正文和内容摘要形成稳定展示投影。 */
    fun validate() {
        require(validAgent(agent) && slot in 1..12 && behavior in listOf("idle", "running", "asking", "error"))
        require(content.encodeToByteArray().size <= 512 && (image == null || validHash(image)))
    }
    /** 只表达已接收的桌面状态，离线时由展示页整体标记缓存。 */
    val label: String get() = when (behavior) { "idle" -> "空闲"; "running" -> "运行"; "asking" -> "询问"; else -> "出错" }
}

/** 资源只以摘要寻址，禁止远端路径或URL。 */
data class TerminalAsset(val hash: String, val mime: String, val length: Long) {
    /** 符合协议上限的元信息才允许建立Rust资源接收器。 */
    fun validate() { require(validHash(hash) && mime in SUPPORTED_MIMES && length in 1..MAX_LENGTH) }

    companion object {
        /** 与桌面协议一致的图片格式白名单。 */
        val SUPPORTED_MIMES = setOf("image/bmp", "image/png", "image/jpeg", "image/webp", "image/gif")
        /** 单张编码正文上限32MiB。 */
        const val MAX_LENGTH = 33_554_432L
    }
}

/** 规范u64十进制贯穿展示和缓存，不允许前导零、符号或超界。 */
internal fun canonicalUnsigned(value: String): Boolean = value.isNotEmpty() && value.length <= 20 &&
    value.all { it in '0'..'9' } && (value == "0" || value[0] != '0') && value.toULongOrNull() != null
/** 内容摘要同时作为私有目录内的固定单层文件名。 */
internal fun validHash(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
/** 有界非空Agent名只作为已认证展示文本。 */
private fun validAgent(value: String): Boolean = value.isNotEmpty() && value.encodeToByteArray().size <= 64

/** DNS-SD候选没有授信作用，真实在线必须等认证后的完整snapshot。 */
data class TerminalHost(val id: String, val name: String, val paired: Boolean, val available: Boolean)
/** UI不可包含秘密；应用owner持有网络，切页只改变本地展示。 */
data class TerminalLinkView(
    val deviceId: String, val deviceName: String, val hosts: List<TerminalHost> = emptyList(),
    val selectedId: String? = null, val status: String = "正在发现桌面端…",
    val error: String? = null, val pairingCode: String? = null, val connected: Boolean = false,
    val canQuerySnapshot: Boolean = false,
    val snapshot: TerminalSnapshot? = null, val receivedAtMs: Long? = null, val assetWarning: String? = null,
)

/** 连接失效立即丢弃全部展示内容，保留设备身份、配对选择及操作反馈。 */
fun TerminalLinkView.withoutLiveDisplay(): TerminalLinkView = copy(
    connected = false, canQuerySnapshot = false, snapshot = null, receivedAtMs = null, assetWarning = null,
)
