package com.manonloki.lokimetrisdisplay

/** 系统报告的终端展示形态；名称、IP和页面宽度不参与选择。 */
enum class TerminalDeviceType(val wireValue: String) {
    PHONE("phone"), TABLET("tablet");

    companion object {
        /** Android应用级系统最小宽度分类；未知配置不冒充手机。 */
        fun fromSmallestWidthDp(width: Int): TerminalDeviceType? = when {
            width <= 0 -> null
            width >= 600 -> TABLET
            else -> PHONE
        }
    }
}

/** 每个认证连接只在实时能力广告后报告一次，缓存读取不能调用此入口。 */
class TerminalDeviceTypeReport(private val type: TerminalDeviceType?) {
    private var reported = false
    /** socket切换、关闭或认证失败时撤销上一轮的能力与已发送状态。 */
    fun reset() { reported = false }
    /** 先严格校验有界能力表，再决定是否向支持本扩展的桌面发送。 */
    fun afterAuthenticatedSnapshot(capabilities: List<String>): TerminalDeviceType? {
        require(capabilities.size <= 16 && capabilities.toSet().size == capabilities.size)
        require(capabilities.all { it.isNotEmpty() && it.encodeToByteArray().size <= 64 })
        if (reported || type == null || "deviceFormFactorV1" !in capabilities) return null
        reported = true
        return type
    }
}
