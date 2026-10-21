package com.manonloki.lokimetrisdisplay

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** 系统 JCA 与标准库实现，可在宿主测试；不依赖 Android、文件或真实 Keystore。 */
internal object PairingRecoveryCodec {
    const val MAX_BYTES = 256 * 1024
    const val MAX_PLAINTEXT_BYTES = 64 * 1024
    const val MAX_RECORDS = 64
    private const val FORMAT = "loki-metris-pairing-recovery"
    private val aad = "LokiMetris/pairing-recovery/mobile/1".toByteArray(Charsets.UTF_8)

    data class Material(val clientId: String, val deviceId: String, val name: String, val secret: String) {
        fun fields(): Map<String, Any> = mapOf("clientId" to clientId, "deviceId" to deviceId, "name" to name, "secret" to secret)
        override fun toString() = "PairingRecoveryMaterial(redacted)"
    }
    data class Payload(val deviceId: String, val materials: List<Material>) {
        override fun toString() = "PairingRecoveryPayload(redacted)"
    }
    data class Exported(val bytes: ByteArray, val recoveryCode: String) {
        override fun toString() = "PairingRecoveryExported(redacted)"
    }

    fun export(payload: Payload): Exported {
        validate(payload)
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        try {
            val code = Base64.getEncoder().encodeToString(key)
            return Exported(seal(payload, code, ByteArray(12).also { SecureRandom().nextBytes(it) }), code)
        } finally { key.fill(0) }
    }

    fun open(bytes: ByteArray, recoveryCode: String): Payload {
        require(bytes.size <= MAX_BYTES) { "pairing_recovery_too_large" }
        val envelope = RecoveryJson.objectFrom(bytes)
        require(envelope.keys == setOf("format", "version", "algorithm", "nonce", "ciphertext", "tag") &&
            envelope["format"] == FORMAT && envelope["version"] == 1 && envelope["algorithm"] == "AES-256-GCM") { "pairing_recovery_invalid" }
        val nonce = base64(envelope.text("nonce"), 12)
        val ciphertext = base64(envelope.text("ciphertext"))
        val tag = base64(envelope.text("tag"), 16)
        require(ciphertext.isNotEmpty() && ciphertext.size <= MAX_PLAINTEXT_BYTES) { "pairing_recovery_too_large" }
        val key = base64(recoveryCode.trim(), 32)
        val plaintext = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(aad)
            cipher.doFinal(ciphertext + tag)
        } catch (_: java.security.GeneralSecurityException) {
            throw IllegalArgumentException("pairing_recovery_authentication")
        } finally { key.fill(0) }
        try {
            val value = RecoveryJson.objectFrom(plaintext)
            require(value.keys == setOf("version", "role", "deviceId", "records") && value["version"] == 1 &&
                value["role"] == "mobile") { "pairing_recovery_invalid" }
            val records = value["records"]
            require(records is List<*> && records.size in 1..MAX_RECORDS) { "pairing_recovery_invalid" }
            val payload = Payload(value.text("deviceId"), records.map { material(it) })
            validate(payload)
            return payload
        } finally { plaintext.fill(0) }
    }

    fun material(value: Any?): Material {
        require(value is Map<*, *> && value.keys == setOf("clientId", "deviceId", "name", "secret")) { "pairing_recovery_invalid" }
        fun text(key: String): String = value[key].let { require(it is String) { "pairing_recovery_invalid" }; it }
        return Material(text("clientId"), text("deviceId"), text("name"), text("secret"))
    }

    fun validate(payload: Payload) {
        require(MdnsProtocol.isCanonicalDeviceId(payload.deviceId) && payload.materials.size in 1..MAX_RECORDS) { "pairing_recovery_invalid" }
        val clients = mutableSetOf<String>()
        payload.materials.forEach { item ->
            require(MdnsProtocol.isCanonicalDeviceId(item.clientId) && item.clientId != payload.deviceId && clients.add(item.clientId) &&
                item.deviceId == payload.deviceId && MdnsProtocol.nameError(item.name) == null) { "pairing_recovery_invalid" }
            val secret = base64(item.secret, 32)
            try { require(secret.any { it != 0.toByte() }) { "pairing_recovery_invalid" } } finally { secret.fill(0) }
        }
    }

    /** 固定随机量仅供合成跨端向量测试；生产调用 export 自动取安全随机量。 */
    fun seal(payload: Payload, recoveryCode: String, nonce: ByteArray): ByteArray {
        validate(payload)
        require(nonce.size == 12) { "pairing_recovery_invalid" }
        val plaintext = RecoveryJson.encode(mapOf("version" to 1, "role" to "mobile", "deviceId" to payload.deviceId,
            "records" to payload.materials.map { it.fields() }))
        require(plaintext.size <= MAX_PLAINTEXT_BYTES) { "pairing_recovery_too_large" }
        val key = base64(recoveryCode.trim(), 32)
        val combined = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(aad); cipher.doFinal(plaintext)
        } finally { key.fill(0); plaintext.fill(0) }
        val envelope = RecoveryJson.encode(mapOf("format" to FORMAT, "version" to 1, "algorithm" to "AES-256-GCM",
            "nonce" to encode64(nonce), "ciphertext" to encode64(combined.copyOfRange(0, combined.size - 16)),
            "tag" to encode64(combined.copyOfRange(combined.size - 16, combined.size))))
        require(envelope.size <= MAX_BYTES) { "pairing_recovery_too_large" }
        return envelope
    }

    private fun Map<String, Any>.text(key: String): String = get(key).let { require(it is String) { "pairing_recovery_invalid" }; it }
    private fun encode64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    private fun base64(value: String, size: Int? = null): ByteArray {
        val decoded = Base64.getDecoder().decode(value)
        require(encode64(decoded) == value && (size == null || decoded.size == size)) { "pairing_recovery_invalid" }
        return decoded
    }
}

/** 恢复格式仅需对象、数组、字符串和版本 1；严格拒绝重复键、JSON扩展和无限嵌套。 */
internal object RecoveryJson {
    fun objectFrom(bytes: ByteArray): Map<String, Any> {
        require(bytes.size <= PairingRecoveryCodec.MAX_BYTES) { "pairing_recovery_too_large" }
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        val parser = Parser(text)
        val value = parser.value(0); parser.space()
        require(parser.index == text.length && value is Map<*, *>) { "pairing_recovery_invalid" }
        @Suppress("UNCHECKED_CAST") return value as Map<String, Any>
    }

    fun encode(value: Map<String, Any>): ByteArray = buildString { appendValue(value) }.toByteArray(Charsets.UTF_8)
    private fun StringBuilder.appendValue(value: Any) {
        when (value) {
            is String -> {
                require(validUnicode(value)) { "pairing_recovery_invalid" }
                append('"')
                value.forEach { char ->
                    when (char) {
                        '"' -> append("\\\""); '\\' -> append("\\\\")
                        '\b' -> append("\\b"); '\u000c' -> append("\\f"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
                        else -> if (char.code < 32) append("\\u" + char.code.toString(16).padStart(4, '0')) else append(char)
                    }
                }
                append('"')
            }
            is Int -> { require(value == 1); append('1') }
            is List<*> -> { append('['); value.forEachIndexed { index, item -> if (index > 0) append(','); appendValue(requireNotNull(item)) }; append(']') }
            is Map<*, *> -> {
                append('{')
                val keys = value.keys.map { require(it is String); it }.sorted()
                keys.forEachIndexed { index, key -> if (index > 0) append(','); appendValue(key); append(':'); appendValue(requireNotNull(value[key])) }
                append('}')
            }
            else -> throw IllegalArgumentException("pairing_recovery_invalid")
        }
    }

    private fun validUnicode(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            if (Character.isHighSurrogate(char)) {
                if (index >= text.length || !Character.isLowSurrogate(text[index++])) return false
            } else if (Character.isLowSurrogate(char)) return false
        }
        return true
    }

    private class Parser(private val text: String) {
        var index = 0
        fun space() { while (index < text.length && text[index] in " \t\r\n") index++ }
        private fun take(char: Char): Boolean = if (index < text.length && text[index] == char) { index++; true } else false
        fun value(depth: Int): Any {
            require(depth <= 8) { "pairing_recovery_invalid" }; space()
            if (take('{')) {
                val result = linkedMapOf<String, Any>()
                space(); if (take('}')) return result
                while (true) {
                    space(); val key = string(); space()
                    require(key !in result && result.size < 128 && take(':')) { "pairing_recovery_invalid" }
                    result[key] = value(depth + 1); space()
                    if (take('}')) return result
                    require(take(',')) { "pairing_recovery_invalid" }
                }
            }
            if (take('[')) {
                val result = mutableListOf<Any>()
                space(); if (take(']')) return result
                while (true) {
                    require(result.size < PairingRecoveryCodec.MAX_RECORDS) { "pairing_recovery_invalid" }
                    result.add(value(depth + 1)); space()
                    if (take(']')) return result
                    require(take(',')) { "pairing_recovery_invalid" }
                }
            }
            require(index < text.length) { "pairing_recovery_invalid" }
            if (text[index] == '"') return string()
            require(take('1')) { "pairing_recovery_invalid" }; return 1
        }

        private fun string(): String {
            require(take('"')) { "pairing_recovery_invalid" }
            val result = StringBuilder()
            while (index < text.length) {
                val char = text[index++]
                if (char == '"') {
                    val value = result.toString()
                    require(value.length <= PairingRecoveryCodec.MAX_PLAINTEXT_BYTES * 2 && validUnicode(value)) { "pairing_recovery_invalid" }
                    return value
                }
                require(char.code >= 32) { "pairing_recovery_invalid" }
                if (char != '\\') { result.append(char); continue }
                require(index < text.length) { "pairing_recovery_invalid" }
                when (val escaped = text[index++]) {
                    '"', '\\', '/' -> result.append(escaped)
                    'b' -> result.append('\b'); 'f' -> result.append('\u000c'); 'n' -> result.append('\n'); 'r' -> result.append('\r'); 't' -> result.append('\t')
                    'u' -> {
                        require(index + 4 <= text.length) { "pairing_recovery_invalid" }
                        val digits = text.substring(index, index + 4)
                        require(digits.all { it in "0123456789abcdefABCDEF" }) { "pairing_recovery_invalid" }
                        result.append(digits.toInt(16).toChar()); index += 4
                    }
                    else -> throw IllegalArgumentException("pairing_recovery_invalid")
                }
            }
            throw IllegalArgumentException("pairing_recovery_invalid")
        }
    }
}
