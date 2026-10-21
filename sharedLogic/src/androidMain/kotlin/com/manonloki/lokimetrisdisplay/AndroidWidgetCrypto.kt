package com.manonloki.lokimetrisdisplay

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** 与桌面 Rust / iOS 共用固定认证域，响应绑定本次原始请求 nonce，不能回放旧摘要。 */
internal object AndroidWidgetCrypto {
    private val requestDomain = "loki-widget-request-v1".toByteArray(Charsets.UTF_8)
    private val responseDomain = "loki-widget-response-v1".toByteArray(Charsets.UTF_8)
    private val random = SecureRandom()

    fun nonce(): ByteArray = ByteArray(12).also(random::nextBytes)
    fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    fun decode(text: String, maxBytes: Int): ByteArray {
        require(text.length <= ((maxBytes + 2) / 3) * 4)
        return Base64.getDecoder().decode(text).also { require(it.size <= maxBytes && encode(it) == text) }
    }

    fun request(key: String, nonce: ByteArray): String {
        require(nonce.size == 12)
        return encode(cipher(Cipher.ENCRYPT_MODE, key, nonce, requestDomain).doFinal(requestDomain))
    }

    fun response(key: String, requestNonce: ByteArray, nonce: ByteArray, ciphertext: ByteArray): ByteArray {
        require(requestNonce.size == 12 && nonce.size == 12 && ciphertext.size in 16..AndroidWidgetSnapshot.MAX_BYTES + 16)
        return cipher(Cipher.DECRYPT_MODE, key, nonce, responseDomain + requestNonce).doFinal(ciphertext)
            .also { require(it.size <= AndroidWidgetSnapshot.MAX_BYTES) }
    }

    private fun cipher(mode: Int, encodedKey: String, nonce: ByteArray, aad: ByteArray): Cipher {
        val bytes = decode(encodedKey, 32)
        try {
            require(bytes.size == 32)
            return Cipher.getInstance("ChaCha20-Poly1305").apply {
                init(mode, SecretKeySpec(bytes, "ChaCha20"), IvParameterSpec(nonce)); updateAAD(aad)
            }
        } finally { bytes.fill(0) }
    }
}
