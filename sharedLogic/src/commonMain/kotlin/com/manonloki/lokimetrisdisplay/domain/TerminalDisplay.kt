package com.manonloki.lokimetrisdisplay.domain

import com.manonloki.lokimetrisdisplay.rules.canonicalUnsigned
import com.manonloki.lokimetrisdisplay.rules.normalizeComparisonText
import com.manonloki.lokimetrisdisplay.rules.validHash

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
        if (enabledAgents == null) value else value.copy(agents = value.agents.filter { AgentIdentity.isEnabled(it.agent, enabledAgents) })
    }
    /** 独立额度与Token明细使用相同启用集合，空名单明确撤下所有提供商。 */
    val displayProviderQuota: ProviderQuotaSnapshot? get() = providerQuota?.let { value ->
        if (enabledAgents == null) value else value.copy(providers = value.providers.filter { AgentIdentity.isEnabled(it.provider, enabledAgents) })
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
        require(AgentIdentity.validEnabledAgents(enabledAgents))
        providerQuota?.validate(); tokens?.validate(); hooks.forEach { it.validate() }; assets.forEach { it.validate() }
    }
    /** Swift 在解码与缓存入口使用显式结果，不传播 Kotlin 异常。 */
    fun isValid(): Boolean = runCatching { validate() }.isSuccess
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
    /** 领域值保留精确十进制；K/M/B 缩写与分组符由展示层另行处理。 */
    val text: String get() = when (availability) { "available" -> total ?: "—"; "noRecords" -> "无记录"; else -> "不可用" }
    val hasNumericValue: Boolean get() = availability == "available" && total != null
    fun isValid(): Boolean = runCatching { validate() }.isSuccess
}

/** 统计日期只接受 yyyy-MM-dd；预编译避免每份快照重复构造。 */
private val DAY_PATTERN = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")

/** 桌面同轮统计日界；毫秒不替换为手机时区。 */
data class TerminalDay(val date: String, val zone: String, val startMs: Long, val endMs: Long)
/** 单个Agent组件与总量保留同一观测时刻。 */
data class TerminalAgent(val agent: String, val amount: TerminalAmount)

/** 完整Token总量及分Agent投影。 */
data class TerminalTokens(val day: TerminalDay, val observedMs: Long, val all: TerminalAmount, val agents: List<TerminalAgent>) {
    /** 日界、观测和唯一Agent来自同一快照，不在移动端重算日期或补零。 */
    fun validate() {
        require(DAY_PATTERN.matches(day.date) && day.zone.encodeToByteArray().size <= 256)
        require(day.startMs < day.endMs && observedMs >= day.startMs && observedMs < day.endMs)
        require(agents.size <= 14 && agents.map { normalizeComparisonText(it.agent) }.distinct().size == agents.size)
        all.validate(); agents.forEach { require(validAgent(it.agent)); it.amount.validate() }
    }
    fun isValid(): Boolean = runCatching { validate() }.isSuccess
}

/** Hook使用桌面最终槽位四态，正文和图像引用不会进入配对或系统日志。 */
data class TerminalHook(val agent: String, val slot: Int, val behavior: String, val content: String, val contentTruncated: Boolean, val image: String?) {
    /** 有限槽位、正文和内容摘要形成稳定展示投影。 */
    fun validate() {
        require(validAgent(agent) && slot in 1..12 && behavior in listOf("idle", "running", "asking", "error"))
        require(content.encodeToByteArray().size <= 512 && (image == null || validHash(image)))
    }
}

/** 资源只以摘要寻址，禁止远端路径或URL。 */
data class TerminalAsset(val hash: String, val mime: String, val length: Long) {
    /** 符合协议上限的元信息才允许建立Rust资源接收器。 */
    fun validate() { require(validHash(hash) && mime in SUPPORTED_MIMES && length in 1..MAX_LENGTH) }
    fun isValid(): Boolean = runCatching { validate() }.isSuccess

    companion object {
        /** 与桌面协议一致的图片格式白名单。 */
        val SUPPORTED_MIMES = setOf("image/bmp", "image/png", "image/jpeg", "image/webp", "image/gif")
        /** 单张编码正文上限32MiB。 */
        const val MAX_LENGTH = 33_554_432L
    }
}

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
