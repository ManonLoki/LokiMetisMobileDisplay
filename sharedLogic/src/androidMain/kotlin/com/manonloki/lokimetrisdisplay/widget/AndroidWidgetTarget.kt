package com.manonloki.lokimetrisdisplay

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.UUID

/** 认证 TCP 实际对端与桌面授予的独立只读密钥；代次变化撤销旧 HTTP 请求。 */
data class AndroidWidgetTarget(
    val sourceId: String, val deviceId: String, val host: String, val port: Int, val key: String,
    val generation: String = UUID.randomUUID().toString(), val version: Int = 1,
) {
    /** 诊断或断言意外格式化目标时也不暴露读取密钥、地址或设备身份。 */
    override fun toString(): String = "AndroidWidgetTarget(version=$version, generation=$generation)"

    /** 校验版本、身份、数值主机和 32 字节读取密钥。 */
    fun validate() {
        require(version == 1 && MdnsProtocol.isCanonicalDeviceId(sourceId) && MdnsProtocol.isCanonicalDeviceId(deviceId))
        require(sourceId != deviceId && MdnsProtocol.isCanonicalDeviceId(generation) && port in 1..65535)
        require(validHost(host))
        val bytes = AndroidWidgetCrypto.decode(key, WidgetHttpBinaryField.KEY)
        bytes.fill(0)
    }

    /** 除代次外完全相同即视为同一连接，重复授予时沿用原代次而不撤销在途请求。 */
    internal fun sameConnection(other: AndroidWidgetTarget): Boolean =
        connection.sameConnection(other.connection)

    private val connection: RefreshConnection get() = RefreshConnection(version, sourceId, deviceId, host, port, key)

    companion object {
        /** 只接受数值形式的私网/链路本地/环回实际对端，不解析广告提供的域名或 URL。 */
        internal fun validHost(host: String): Boolean {
            if (!WidgetEndpointRules.validHostText(host) || host.contains('[') || host.contains(']')) return false
            if (!host.contains(':')) return WidgetEndpointRules.isPrivateIPv4Literal(host)
            val pieces = host.split('%')
            if (pieces.size > 2 || pieces[0].any { it !in "0123456789abcdef:." }) return false
            if (pieces.size == 2 && !WidgetEndpointRules.validIPv6Scope(pieces[1])) return false
            val address = runCatching { InetAddress.getByName(pieces[0]) }.getOrNull() ?: return false
            if (address !is Inet4Address && address !is Inet6Address) return false
            return WidgetEndpointRules.isPrivateAddress(address.address.map { it.toInt() and 255 })
        }
    }
}
