package com.manonloki.lokimetrisdisplay.protocol

import com.manonloki.lokimetrisdisplay.storage.TerminalWidgetSnapshot

/** Android 与 Apple 的请求容量、Base64 接纳规则不同，使用固定平台配置选择。 */
enum class WidgetHttpClientProfile { ANDROID, APPLE }
enum class WidgetHttpBinaryField { KEY, NONCE, RESPONSE_CIPHERTEXT }

/** 独立只读摘要的固定线协议；系统网络、JSON 和密码运算由各平台执行。 */
object WidgetHttpPolicy {
    const val SCHEME = "http"
    const val METHOD = "POST"
    const val PATH = "/api/widget/v1/snapshot"
    const val MEDIA_TYPE = "application/json"
    const val REQUEST_CONTEXT = "loki-widget-request-v1"
    const val RESPONSE_CONTEXT = "loki-widget-response-v1"
    const val FOLLOW_REDIRECTS = false
    const val TIMEOUT_MS = 6_000
    const val MAX_RESPONSE_BYTES = 96 * 1024
    const val ANDROID_MAX_REQUEST_BYTES = 1024
    const val NONCE_BYTES = 12
    const val KEY_BYTES = 32
    const val TAG_BYTES = 16

    fun validRequestSize(bytes: Long, profile: WidgetHttpClientProfile): Boolean =
        bytes >= 0 && (profile == WidgetHttpClientProfile.APPLE || bytes <= ANDROID_MAX_REQUEST_BYTES)

    fun acceptsResponse(status: Int, mediaType: String?, sameRequestURL: Boolean): Boolean =
        status == 200 && sameRequestURL && mediaType?.substringBefore(';')?.trim()?.lowercase() == MEDIA_TYPE

    /** 负的声明长度沿用系统“未知长度”语义；实际流始终另外限长。 */
    fun acceptsDeclaredResponseSize(bytes: Long): Boolean = bytes <= MAX_RESPONSE_BYTES

    /** 通用有界读取器也用于私有文件；先减后比，避免先加而溢出。 */
    fun fitsCapacity(bufferedBytes: Long, incomingBytes: Long, maximumBytes: Long): Boolean =
        maximumBytes >= 0 && bufferedBytes in 0..maximumBytes && incomingBytes >= 0 &&
            incomingBytes <= maximumBytes - bufferedBytes

    private fun maximumDecodedBytes(field: WidgetHttpBinaryField): Int = when (field) {
        WidgetHttpBinaryField.KEY -> KEY_BYTES
        WidgetHttpBinaryField.NONCE -> NONCE_BYTES
        WidgetHttpBinaryField.RESPONSE_CIPHERTEXT -> TerminalWidgetSnapshot.MAX_BYTES + TAG_BYTES
    }

    private fun canonicalRequired(field: WidgetHttpBinaryField, profile: WidgetHttpClientProfile): Boolean =
        field == WidgetHttpBinaryField.KEY || profile == WidgetHttpClientProfile.ANDROID

    /** Android 在 Base64 解码前检查容量；Apple 响应由 Foundation 判断可解码性。 */
    fun acceptsBase64Input(characters: Long, field: WidgetHttpBinaryField, profile: WidgetHttpClientProfile): Boolean =
        characters >= 0 && (!canonicalRequired(field, profile) ||
            characters <= ((maximumDecodedBytes(field) + 2) / 3) * 4)

    fun acceptsDecodedBase64(field: WidgetHttpBinaryField, profile: WidgetHttpClientProfile,
                             decodedBytes: Long, canonicalEncoding: Boolean): Boolean =
        (!canonicalRequired(field, profile) || canonicalEncoding) && when (field) {
            WidgetHttpBinaryField.KEY -> decodedBytes == KEY_BYTES.toLong()
            WidgetHttpBinaryField.NONCE -> validNonceSize(decodedBytes)
            WidgetHttpBinaryField.RESPONSE_CIPHERTEXT -> decodedBytes in TAG_BYTES.toLong()..maximumDecodedBytes(field).toLong()
        }

    fun validNonceSize(bytes: Long): Boolean = bytes == NONCE_BYTES.toLong()
    fun validPlaintextSize(bytes: Long): Boolean = bytes in 0..TerminalWidgetSnapshot.MAX_BYTES.toLong()

    fun validResponseEnvelope(requestNonceBytes: Long, responseNonceBytes: Long, ciphertextBytes: Long): Boolean =
        validNonceSize(requestNonceBytes) && validNonceSize(responseNonceBytes) &&
            ciphertextBytes in TAG_BYTES.toLong()..(TerminalWidgetSnapshot.MAX_BYTES + TAG_BYTES).toLong()

    /** 附加认证数据绑定本轮请求 nonce，旧响应不能复用；只复制固定的小型认证元信息。 */
    fun responseAssociatedData(requestNonce: ByteArray): ByteArray? =
        if (validNonceSize(requestNonce.size.toLong())) RESPONSE_CONTEXT.encodeToByteArray() + requestNonce else null

    fun acceptsMessageSource(expectedSourceId: String, sourceId: String, type: String): Boolean =
        expectedSourceId == sourceId && type == "snapshot"
}

/** 只共享固定地址边界与已解析字节的分类；IPv6 解析、DNS 与 URL 组装仍归宿主。 */
object WidgetEndpointRules {
    fun validHostText(host: String): Boolean = host.isNotEmpty() && host.length <= 253 &&
        host.all { it.code in 33..126 } && host == host.lowercase()

    /** 仅接受四段规范十进制，不接纳前导零、缩写、符号或越界字节。 */
    fun isPrivateIPv4Literal(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4 || parts.any { it.isEmpty() || it.any { char -> char !in '0'..'9' } ||
                (it.length > 1 && it[0] == '0') }) return false
        return privateIPv4(parts.map { it.toIntOrNull() ?: return false })
    }

    fun validIPv6Scope(scope: String): Boolean = scope.length in 1..32 &&
        scope.all { it in 'a'..'z' || it in '0'..'9' || it in "-._" }

    /** 平台解析器可将 IPv4-mapped IPv6 返回为四或十六字节，两者使用相同私网规则。 */
    fun isPrivateAddress(bytes: List<Int>): Boolean {
        if (bytes.any { it !in 0..255 }) return false
        if (bytes.size == 4) return privateIPv4(bytes)
        if (bytes.size != 16 || bytes.all { it == 0 } || bytes[0] == 0xff) return false
        if (bytes.take(10).all { it == 0 } && bytes[10] == 0xff && bytes[11] == 0xff)
            return privateIPv4(bytes.takeLast(4))
        val loopback = bytes.take(15).all { it == 0 } && bytes[15] == 1
        return loopback || (bytes[0] and 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] and 0xc0) == 0x80)
    }

    private fun privateIPv4(bytes: List<Int>): Boolean = bytes.size == 4 && bytes.all { it in 0..255 } &&
        (bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 172 && bytes[1] in 16..31) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254))
}
