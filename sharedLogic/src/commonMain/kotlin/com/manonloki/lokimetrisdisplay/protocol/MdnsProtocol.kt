package com.manonloki.lokimetrisdisplay.protocol

import com.manonloki.lokimetrisdisplay.rules.TerminalValueRules

/** 桌面宿主发现与终端身份合同；DNS-SD广告不授信，移动端主动连接桌面。 */
object MdnsProtocol {
    const val SERVICE_TYPE = "_loki-host._tcp."
    const val DOMAIN = "local."
    const val DEFAULT_NAME = "LokiMetris Display"
    const val MAX_NAME_BYTES = 160

    /** 设备身份格式归属基础规则，发现层只转发。 */
    fun isCanonicalDeviceId(id: String): Boolean = TerminalValueRules.validDeviceId(id)

    /** 名称按UTF-8字节限制，错误可直接显示在本机设置中。 */
    fun nameError(name: String): String? = when {
        name.isBlank() -> "请输入设备名称"
        name.any { it.code in 0..31 || it.code in 127..159 } -> "设备名称不能包含控制字符"
        name.encodeToByteArray().size > MAX_NAME_BYTES -> "设备名称不能超过 160 个 UTF-8 字节"
        else -> null
    }

}
