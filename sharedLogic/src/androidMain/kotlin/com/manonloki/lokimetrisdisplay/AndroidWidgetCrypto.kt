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

    /** 每次请求生成新的 12 字节随机 nonce。 */
    fun nonce(): ByteArray = ByteArray(12).also(random::nextBytes)
    /** 标准 Base64，与桌面端编码一致。 */
    fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    /** 先限制长度再解码，并要求规范编码，拒绝可变形输入。 */
    fun decode(text: String, maxBytes: Int): ByteArray {
        require(text.length <= ((maxBytes + 2) / 3) * 4)
        return Base64.getDecoder().decode(text).also { require(it.size <= maxBytes && encode(it) == text) }
    }

    /** 生成请求认证标签：以请求域为明文和附加数据加密。 */
    fun request(key: String, nonce: ByteArray): String {
        require(nonce.size == 12)
        return encode(cipher(Cipher.ENCRYPT_MODE, key, nonce, requestDomain).doFinal(requestDomain))
    }

    /** 解密响应，附加数据绑定请求 nonce，旧响应无法通过认证。 */
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
