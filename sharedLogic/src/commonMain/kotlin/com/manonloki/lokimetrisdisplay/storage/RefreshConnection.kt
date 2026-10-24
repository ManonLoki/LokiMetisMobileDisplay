package com.manonloki.lokimetrisdisplay.storage

/** 配置身份只用于相等性决策；格式、系统解析和密钥存取由平台边界验证。 */
class RefreshConnection(
    private val version: Int, private val sourceId: String, private val deviceId: String,
    private val host: String, private val port: Int, private val key: String,
) {
    /** 重复授权保持原代次；任一连接字段变化都必须使旧请求失效。 */
    fun sameConnection(other: RefreshConnection): Boolean = version == other.version &&
        sourceId == other.sourceId && deviceId == other.deviceId && host == other.host &&
        port == other.port && key == other.key

    override fun toString(): String = "RefreshConnection(redacted)"
}
