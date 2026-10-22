package com.manonloki.lokimetrisdisplay

/** 桌面宿主发现与终端身份合同；DNS-SD广告不授信，移动端主动连接桌面。 */
object MdnsProtocol {
    const val SERVICE_TYPE = "_loki-host._tcp."
    const val DOMAIN = "local."
    const val DEFAULT_NAME = "LokiMetris Display"
    const val MAX_NAME_BYTES = 160

    /** UUID与既有安装身份保持一致，拒绝零值、大写和非规范分隔。 */
    fun isCanonicalDeviceId(id: String): Boolean =
        id.length == 36 && id != "00000000-0000-0000-0000-000000000000" &&
            id.withIndex().all { (index, char) ->
                if (index == 8 || index == 13 || index == 18 || index == 23) char == '-'
                else char in '0'..'9' || char in 'a'..'f'
            }

    /** 名称按UTF-8字节限制，错误可直接显示在本机设置中。 */
    fun nameError(name: String): String? = when {
        name.isBlank() -> "请输入设备名称"
        name.any { it.code in 0..31 || it.code in 127..159 } -> "设备名称不能包含控制字符"
        name.encodeToByteArray().size > MAX_NAME_BYTES -> "设备名称不能超过 160 个 UTF-8 字节"
        else -> null
    }

}
