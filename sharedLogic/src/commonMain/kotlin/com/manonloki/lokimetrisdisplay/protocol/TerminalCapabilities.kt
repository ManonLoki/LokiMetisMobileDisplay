package com.manonloki.lokimetrisdisplay

/** 当前认证快照的能力合同；JSON 字段缺失由平台映射为空表，坏类型映射为 null。 */
object TerminalCapabilities {
    const val MAX_COUNT = 16
    const val MAX_NAME_BYTES = 64
    const val DEVICE_FORM_FACTOR = "deviceFormFactorV1"
    const val WATCH_COMPANION = "watchCompanionV1"
    const val WIDGET_HTTP = "widgetHttpV1"

    fun isValid(values: List<String>?): Boolean = values != null && values.size <= MAX_COUNT &&
        values.all { it.isNotEmpty() && it.encodeToByteArray().size <= MAX_NAME_BYTES } &&
        values.map(::normalizeComparisonText).distinct().size == values.size

    /** 未知能力可忽略，损坏能力表不能授予扩展。 */
    fun supports(values: List<String>?, capability: String): Boolean = isValid(values) && capability in values.orEmpty()
}
