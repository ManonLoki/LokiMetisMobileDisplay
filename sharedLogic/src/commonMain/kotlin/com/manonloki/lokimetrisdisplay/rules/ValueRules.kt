package com.manonloki.lokimetrisdisplay.rules

/** 线协议与本机记录共同使用的格式规则，系统负责密码运算和实际文件访问。 */
object TerminalValueRules {
    const val ZERO_ID = "00000000-0000-0000-0000-000000000000"
    fun isCanonicalUUID(value: String): Boolean = value == ZERO_ID || validDeviceId(value)
    /** UUID与既有安装身份保持一致，拒绝零值、大写和非规范分隔。 */
    fun validDeviceId(value: String): Boolean =
        value.length == 36 && value != ZERO_ID &&
            value.withIndex().all { (index, char) ->
                if (index == 8 || index == 13 || index == 18 || index == 23) char == '-'
                else char in '0'..'9' || char in 'a'..'f'
            }
    fun validContentHash(value: String): Boolean = validHash(value)
    fun containsControl(value: String): Boolean = value.any { it.code in 0..31 || it.code in 127..159 }
}

/** 规范u64十进制贯穿展示和缓存，不允许前导零、符号或超界。 */
internal fun canonicalUnsigned(value: String): Boolean = value.isNotEmpty() && value.length <= 20 &&
    value.all { it in '0'..'9' } && (value == "0" || value[0] != '0') && value.toULongOrNull() != null
/** 内容摘要同时作为私有目录内的固定单层文件名。 */
internal fun validHash(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
