package com.manonloki.lokimetrisdisplay

/** 桌面已读取的额度快照；终端不持有提供商凭据，也不根据Token推算额度。 */
data class ProviderQuotaSnapshot(val observedAtUnix: Long, val providers: List<ProviderQuotaEntry>) {
    /** 有界、唯一且按指定顺序排列；空列表明确撤下旧额度。 */
    fun validate() {
        val order = listOf("codex", "claude", "cursor", "grok")
        require(observedAtUnix >= 0 && providers.size <= order.size)
        var previous = -1
        providers.forEach {
            val index = order.indexOf(it.provider)
            require(index > previous); previous = index
            it.validate()
        }
    }
    fun isValid(): Boolean = runCatching { validate() }.isSuccess
}

/** 各窗口独立可空，只有周或月额度也保留；当前上游仅 Cursor 提供月窗口，模型不按提供商限制窗口种类。 */
data class ProviderQuotaEntry(val provider: String, val plan: String?, val fiveHour: ProviderQuotaWindow?, val weekly: ProviderQuotaWindow?, val monthly: ProviderQuotaWindow? = null) {
    /** 方案只允许桌面消毒后的短ASCII文本，不接受邮箱、路径或控制符。 */
    fun validate() {
        require(fiveHour != null || weekly != null || monthly != null)
        require(plan == null || plan.isNotEmpty() && plan.length <= 24 && plan.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in " _-." })
        fiveHour?.validate("fiveHour"); weekly?.validate("weekly"); monthly?.validate("monthly")
    }
    fun isValid(): Boolean = runCatching { validate() }.isSuccess
    val label: String get() = when (provider) { "codex" -> "Codex"; "claude" -> "Claude"; "cursor" -> "Cursor"; else -> "Grok" }
    /** 仅用于显示，协议中的套餐标识保持原值。 */
    val planLabel: String? get() = plan?.replaceFirstChar { it.uppercaseChar() }
    /** 所有面板共用的展示顺序：每月、每周、5h，缺失窗口跳过。 */
    val windows: List<ProviderQuotaWindow> get() = listOfNotNull(monthly, weekly, fiveHour)
}

/** 比例使用整数千分比，避免浮点往返及把零余额当作缺失。 */
data class ProviderQuotaWindow(val kind: String, val usedTenths: Int, val resetAtUnix: Long?) {
    fun validate(expected: String) { require(kind == expected && usedTenths in 0..1000 && (resetAtUnix == null || resetAtUnix >= 0)) }
    fun isValid(expected: String): Boolean = runCatching { validate(expected) }.isSuccess
    val remainingTenths: Int get() = 1000 - usedTenths
    /** 面板统一窗口文字。 */
    val kindLabel: String get() = when (kind) { "monthly" -> "每月"; "weekly" -> "每周"; else -> "5h" }
    val percentText: String get() = remainingTenths.let { if (it % 10 == 0) "${it / 10}%" else "${it / 10}.${it % 10}%" }
    /** 红、黄、绿三个语义档，所有原生展示消费同一阈值。 */
    val level: Int get() = when (remainingTenths) { in 0..200 -> 0; in 201..500 -> 1; else -> 2 }
}
