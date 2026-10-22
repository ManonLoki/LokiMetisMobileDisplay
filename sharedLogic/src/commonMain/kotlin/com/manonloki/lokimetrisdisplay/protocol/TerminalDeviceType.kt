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

/** 非抛异常的宿主边界：非法能力表与合法但无需上报是不同结果。 */
data class TerminalDeviceTypeDecision(val valid: Boolean, val type: TerminalDeviceType?)

/** 每个认证连接只在实时能力广告后报告一次，缓存读取不能调用此入口。 */
class TerminalDeviceTypeReport(private val type: TerminalDeviceType?) {
    private var reported = false
    /** socket切换、关闭或认证失败时撤销上一轮的能力与已发送状态。 */
    fun reset() { reported = false }
    /** Android 严格校验入口；状态和能力规则复用不抛异常的 Swift 边界。 */
    fun afterAuthenticatedSnapshot(capabilities: List<String>): TerminalDeviceType? {
        val decision = evaluateAuthenticatedSnapshot(capabilities)
        require(decision.valid)
        return decision.type
    }

    /** 缺失能力字段由宿主传空表，类型错误传 null；任何非法输入都不消耗上报资格。 */
    fun evaluateAuthenticatedSnapshot(capabilities: List<String>?): TerminalDeviceTypeDecision {
        if (!TerminalCapabilities.isValid(capabilities)) {
            return TerminalDeviceTypeDecision(false, null)
        }
        if (reported || type == null || !TerminalCapabilities.supports(capabilities, TerminalCapabilities.DEVICE_FORM_FACTOR)) return TerminalDeviceTypeDecision(true, null)
        reported = true
        return TerminalDeviceTypeDecision(true, type)
    }
}
