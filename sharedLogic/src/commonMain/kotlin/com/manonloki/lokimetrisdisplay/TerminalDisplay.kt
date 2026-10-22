package com.manonloki.lokimetrisdisplay

/** 已认证完整快照的宿主无关投影；数字保留十进制u64，不重新统计桌面用量。 */
data class TerminalSnapshot(
    val version: Int, val tokens: TerminalTokens?, val tokenError: String?,
    val hooksAvailable: Boolean, val hooks: List<TerminalHook>,
    val assets: List<TerminalAsset>, val catalogError: String?,
    val providerQuota: ProviderQuotaSnapshot? = null,
    val enabledAgents: List<String>? = null,
) {
    /** 名单缺省时兼容旧桌面；只筛选明细，保留桌面总量、统计质量和原始快照。 */
    val displayTokens: TerminalTokens? get() = tokens?.let { value ->
        if (enabledAgents == null) value else value.copy(agents = value.agents.filter { agentEnabled(it.agent) })
    }
    /** 独立额度与Token明细使用相同启用集合，空名单明确撤下所有提供商。 */
    val displayProviderQuota: ProviderQuotaSnapshot? get() = providerQuota?.let { value ->
        if (enabledAgents == null) value else value.copy(providers = value.providers.filter { agentEnabled(it.provider) })
    }

    private fun agentEnabled(name: String): Boolean = enabledAgents?.any { canonicalAgentKey(it) == canonicalAgentKey(name) } ?: true

    /** 合并可见明细和额度；有明确名单时仅启用Cursor才补零，不改变统计快照。 */
    val displayUsageRows: List<TerminalUsageRow> get() {
        val agents = displayTokens?.agents.orEmpty()
        val quotas = displayProviderQuota?.providers.orEmpty()
        val matchedKeys = agents.mapNotNull { providerQuotaKey(it.agent) }.toSet()
        val rows = agents.map { agent ->
            TerminalUsageRow(agent, quotas.firstOrNull { it.provider == providerQuotaKey(agent.agent) })
        } + quotas.filterNot { it.provider in matchedKeys }.map { TerminalUsageRow(null, it) }
        val showDefaultCursor = if (enabledAgents == null) tokens != null else agentEnabled(ZERO_DEFAULT_PROVIDER)
        val cursorRow = if (showDefaultCursor && rows.none { it.isZeroDefaultProvider })
            listOf(TerminalUsageRow(null, null)) else emptyList()
        return (rows + cursorRow).sortedBy { displayAgentOrder(it.sourceName) }
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
        enabledAgents?.let { names ->
            require(names.size <= 14 && names.all { validAgent(it) && canonicalAgentKey(it).isNotEmpty() })
            require(names.distinct().size == names.size && names.map(::canonicalAgentKey).distinct().size == names.size)
        }
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
    val hasNumericValue: Boolean get() = availability == "available" && total != null
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
fun agentDisplayName(raw: String): String = when (canonicalAgentKey(raw)) {
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

/** 仅把有真实额度接口的Agent关联到提供商，未知名称不猜测。 */
fun providerQuotaKey(agent: String): String? = when (canonicalAgentKey(agent)) {
    "codex" -> "codex"
    "claude" -> "claude"
    "cursor" -> "cursor"
    "grok" -> "grok"
    else -> null
}

private fun normalizedAgentName(raw: String): String = raw.lowercase().filterNot { it == '_' || it == '-' || it.isWhitespace() }

/** 桌面camelCase枚举、历史协议名与展示名共用同一匹配键，不改原始标识。 */
internal fun canonicalAgentKey(raw: String): String = when (val key = normalizedAgentName(raw)) {
    "claude", "claudecode" -> "claude"
    "grok", "grokbuild" -> "grok"
    "gemini", "geminicli" -> "gemini"
    "githubcopilot", "githubcopilotcli" -> "githubcopilot"
    else -> key
}

/** 只改变展示顺序；未指定的Agent保持相对次序，WorkBuddy留到最后。 */
private fun displayAgentOrder(raw: String): Int = when (canonicalAgentKey(raw)) {
    "codex" -> 0
    "claude" -> 1
    "cursor" -> 2
    "grok" -> 3
    "workbuddy" -> 5
    else -> 4
}

/** 非序列化UI投影；两者皆空即缺失Cursor的默认零行，不参与统计或额度。 */
data class TerminalUsageRow(val tokenAgent: TerminalAgent?, val quota: ProviderQuotaEntry?) {
    internal val sourceName: String get() = tokenAgent?.agent ?: quota?.provider ?: ZERO_DEFAULT_PROVIDER
    val displayName: String get() = tokenAgent?.displayName ?: quota?.label ?: agentDisplayName(sourceName)
    internal val isZeroDefaultProvider: Boolean get() = providerQuotaKey(sourceName) == ZERO_DEFAULT_PROVIDER
    /** 与Swift `WidgetUsageRow.presentation` 同一规则：默认零提供方缺数字时显示0。 */
    val tokenText: String? get() = if (isZeroDefaultProvider && tokenAgent?.amount?.hasNumericValue != true)
        "0" else tokenAgent?.amount?.text
}

/** 缺少Token数字时仍显示0的提供方；缺失整行时补占位行。 */
private const val ZERO_DEFAULT_PROVIDER = "cursor"

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
    val snapshot: TerminalSnapshot? = null, val receivedAtMs: Long? = null, val assetWarning: String? = null,
)

/** 连接失效立即丢弃全部展示内容，保留设备身份、配对选择及操作反馈。 */
fun TerminalLinkView.withoutLiveDisplay(): TerminalLinkView = copy(
    connected = false, snapshot = null, receivedAtMs = null, assetWarning = null,
)
