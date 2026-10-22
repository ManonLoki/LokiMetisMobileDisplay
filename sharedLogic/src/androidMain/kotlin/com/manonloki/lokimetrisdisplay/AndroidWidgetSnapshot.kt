package com.manonloki.lokimetrisdisplay

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.Base64
import java.util.UUID

/** 小组件与悬浮摘要只保留用量和四态；正文、图片及长期配对秘密不进入持久化。 */
data class AndroidWidgetSnapshot(val sourceId: String, val receivedAtMs: Long, val snapshot: TerminalSnapshot) {
/** 校验摘要已裁剪：不含正文、图片或资源目录。 */
    fun validate() {
        require(MdnsProtocol.isCanonicalDeviceId(sourceId) && receivedAtMs >= 0)
        snapshot.validate()
        require(snapshot.assets.isEmpty() && snapshot.catalogError == null)
        require(snapshot.hooks.all { it.content.isEmpty() && !it.contentTruncated && it.image == null })
    }

    companion object {
        const val MAX_BYTES = 64 * 1024
        const val REFRESH_INTERVAL_MS = 15 * 60 * 1000L

        /** 只接受 owner 已验证的完整快照；新对象不引用任何 Hook 正文或图片。 */
        fun fromLive(sourceId: String, receivedAtMs: Long, snapshot: TerminalSnapshot): AndroidWidgetSnapshot {
            snapshot.validate()
            return AndroidWidgetSnapshot(sourceId, receivedAtMs, snapshot.copy(
                tokens = snapshot.tokens?.let { it.copy(agents = it.agents.toList()) },
                hooks = snapshot.hooks.map { it.copy(content = "", contentTruncated = false, image = null) },
                assets = emptyList(), catalogError = null,
                enabledAgents = snapshot.enabledAgents?.toList(),
            )).also { it.validate() }
        }
    }
}

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
        require(key.length == 44)
        val bytes = Base64.getDecoder().decode(key)
        try { require(bytes.size == 32 && Base64.getEncoder().encodeToString(bytes) == key) }
        finally { bytes.fill(0) }
    }

    /** 除代次外完全相同即视为同一连接，重复授予时沿用原代次而不撤销在途请求。 */
    internal fun sameConnection(other: AndroidWidgetTarget): Boolean =
        version == other.version && sourceId == other.sourceId && deviceId == other.deviceId &&
            host == other.host && port == other.port && key == other.key

    companion object {
        /** 只接受数值形式的私网/链路本地/环回实际对端，不解析广告提供的域名或 URL。 */
        internal fun validHost(host: String): Boolean {
            if (host.isEmpty() || host.length > 253 || host != host.lowercase() ||
                host.any { it.code !in 33..126 } || host.contains('[') || host.contains(']')) return false
            if (!host.contains(':')) {
                val pieces = host.split('.')
                if (pieces.size != 4 || pieces.any { it.isEmpty() || it.any { char -> char !in '0'..'9' } ||
                        (it.length > 1 && it[0] == '0') || it.toIntOrNull() !in 0..255 }) return false
                return privateIPv4(pieces.map { it.toInt() })
            }
            val pieces = host.split('%')
            if (pieces.size > 2 || pieces[0].any { it !in "0123456789abcdef:." }) return false
            if (pieces.size == 2 && (pieces[1].isEmpty() || pieces[1].length > 32 ||
                    pieces[1].any { it !in 'a'..'z' && it !in '0'..'9' && it !in "-._" })) return false
            val address = runCatching { InetAddress.getByName(pieces[0]) }.getOrNull() ?: return false
            if (address is Inet4Address) return privateIPv4(address.address.map { it.toInt() and 255 })
            if (address !is Inet6Address) return false
            val bytes = address.address.map { it.toInt() and 255 }
            return address.isLoopbackAddress || (bytes[0] and 0xfe) == 0xfc ||
                (bytes[0] == 0xfe && (bytes[1] and 0xc0) == 0x80)
        }

        private fun privateIPv4(bytes: List<Int>): Boolean = bytes[0] == 10 || bytes[0] == 127 ||
            (bytes[0] == 172 && bytes[1] in 16..31) || (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 169 && bytes[1] == 254)
    }
}
