package com.manonloki.lokimetrisdisplay

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** 与桌面 Rust / iOS 共用固定认证域，响应绑定本次原始请求 nonce，不能回放旧摘要。 */
internal object AndroidWidgetCrypto {
    private val requestDomain = WidgetHttpPolicy.REQUEST_CONTEXT.encodeToByteArray()
    private val random = SecureRandom()

    /** 每次请求生成新的 12 字节随机 nonce。 */
    fun nonce(): ByteArray = ByteArray(WidgetHttpPolicy.NONCE_BYTES).also(random::nextBytes)
    /** 标准 Base64，与桌面端编码一致。 */
    fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    /** 先限制长度再解码，并要求规范编码，拒绝可变形输入。 */
    fun decode(text: String, field: WidgetHttpBinaryField): ByteArray {
        require(WidgetHttpPolicy.acceptsBase64Input(text.length.toLong(), field, WidgetHttpClientProfile.ANDROID))
        return Base64.getDecoder().decode(text).also {
            try {
                require(WidgetHttpPolicy.acceptsDecodedBase64(field, WidgetHttpClientProfile.ANDROID,
                    it.size.toLong(), encode(it) == text))
            } catch (error: Exception) { it.fill(0); throw error }
        }
    }

    /** 生成请求认证标签：以请求域为明文和附加数据加密。 */
    fun request(key: String, nonce: ByteArray): String {
        require(WidgetHttpPolicy.validNonceSize(nonce.size.toLong()))
        return encode(cipher(Cipher.ENCRYPT_MODE, key, nonce, requestDomain).doFinal(requestDomain))
    }

    /** 解密响应，附加数据绑定请求 nonce，旧响应无法通过认证。 */
    fun response(key: String, requestNonce: ByteArray, nonce: ByteArray, ciphertext: ByteArray): ByteArray {
        require(WidgetHttpPolicy.validResponseEnvelope(requestNonce.size.toLong(), nonce.size.toLong(), ciphertext.size.toLong()))
        val aad = requireNotNull(WidgetHttpPolicy.responseAssociatedData(requestNonce))
        return cipher(Cipher.DECRYPT_MODE, key, nonce, aad).doFinal(ciphertext)
            .also { require(WidgetHttpPolicy.validPlaintextSize(it.size.toLong())) }
    }

    private fun cipher(mode: Int, encodedKey: String, nonce: ByteArray, aad: ByteArray): Cipher {
        val bytes = decode(encodedKey, WidgetHttpBinaryField.KEY)
        try {
            return Cipher.getInstance("ChaCha20-Poly1305").apply {
                init(mode, SecretKeySpec(bytes, "ChaCha20"), IvParameterSpec(nonce)); updateAAD(aad)
            }
        } finally { bytes.fill(0) }
    }
}
