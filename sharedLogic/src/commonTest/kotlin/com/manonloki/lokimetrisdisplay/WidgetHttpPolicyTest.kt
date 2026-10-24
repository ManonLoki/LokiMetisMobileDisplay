package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.protocol.WidgetHttpBinaryField
import com.manonloki.lokimetrisdisplay.protocol.WidgetHttpClientProfile
import com.manonloki.lokimetrisdisplay.protocol.WidgetHttpPolicy
import kotlin.test.*

/** 验证 HTTP 元信息、Base64 平台差异及请求 nonce 绑定规则，不发送真实网络请求。 */
class WidgetHttpPolicyTest {
    @Test fun protocolConstantsAndRequestCompatibilityRemainExplicit() {
        assertEquals("http", WidgetHttpPolicy.SCHEME)
        assertEquals("POST", WidgetHttpPolicy.METHOD)
        assertEquals("/api/widget/v1/snapshot", WidgetHttpPolicy.PATH)
        assertEquals(6_000, WidgetHttpPolicy.TIMEOUT_MS)
        assertEquals(98_304, WidgetHttpPolicy.MAX_RESPONSE_BYTES)
        assertFalse(WidgetHttpPolicy.FOLLOW_REDIRECTS)
        assertTrue(WidgetHttpPolicy.validRequestSize(1024, WidgetHttpClientProfile.ANDROID))
        assertFalse(WidgetHttpPolicy.validRequestSize(1025, WidgetHttpClientProfile.ANDROID))
        assertTrue(WidgetHttpPolicy.validRequestSize(1025, WidgetHttpClientProfile.APPLE))
        assertFalse(WidgetHttpPolicy.validRequestSize(-1, WidgetHttpClientProfile.APPLE))
    }

    @Test fun responseStatusTypeEndpointAndDeclaredCapacityStayBounded() {
        assertTrue(WidgetHttpPolicy.acceptsResponse(200, "Application/JSON; charset=utf-8", true))
        assertFalse(WidgetHttpPolicy.acceptsResponse(302, "application/json", true))
        assertFalse(WidgetHttpPolicy.acceptsResponse(200, "text/plain", true))
        assertFalse(WidgetHttpPolicy.acceptsResponse(200, null, true))
        assertFalse(WidgetHttpPolicy.acceptsResponse(200, "application/json", false))
        assertTrue(WidgetHttpPolicy.acceptsDeclaredResponseSize(-1))
        assertTrue(WidgetHttpPolicy.acceptsDeclaredResponseSize(98_304))
        assertFalse(WidgetHttpPolicy.acceptsDeclaredResponseSize(98_305))
        assertTrue(WidgetHttpPolicy.fitsCapacity(98_303, 1, 98_304))
        assertFalse(WidgetHttpPolicy.fitsCapacity(98_304, 1, 98_304))
        assertFalse(WidgetHttpPolicy.fitsCapacity(Long.MAX_VALUE, 1, 98_304))
        assertFalse(WidgetHttpPolicy.fitsCapacity(1, Long.MAX_VALUE, Long.MAX_VALUE))
        assertFalse(WidgetHttpPolicy.fitsCapacity(-1, 0, 98_304))
        assertFalse(WidgetHttpPolicy.fitsCapacity(0, -1, 98_304))
    }

    @Test fun base64ProfilesPreserveAndroidCanonicalAndAppleDecoderSemantics() {
        val nonce = WidgetHttpBinaryField.NONCE
        assertTrue(WidgetHttpPolicy.acceptsBase64Input(16, nonce, WidgetHttpClientProfile.ANDROID))
        assertFalse(WidgetHttpPolicy.acceptsBase64Input(17, nonce, WidgetHttpClientProfile.ANDROID))
        assertTrue(WidgetHttpPolicy.acceptsBase64Input(17, nonce, WidgetHttpClientProfile.APPLE))
        assertFalse(WidgetHttpPolicy.acceptsDecodedBase64(nonce, WidgetHttpClientProfile.ANDROID, 12, false))
        assertTrue(WidgetHttpPolicy.acceptsDecodedBase64(nonce, WidgetHttpClientProfile.APPLE, 12, false))
        assertFalse(WidgetHttpPolicy.acceptsDecodedBase64(nonce, WidgetHttpClientProfile.APPLE, 11, true))
        assertFalse(WidgetHttpPolicy.acceptsDecodedBase64(WidgetHttpBinaryField.KEY, WidgetHttpClientProfile.APPLE, 32, false))
        assertTrue(WidgetHttpPolicy.acceptsDecodedBase64(WidgetHttpBinaryField.KEY, WidgetHttpClientProfile.APPLE, 32, true))
        assertFalse(WidgetHttpPolicy.acceptsBase64Input(Long.MAX_VALUE, WidgetHttpBinaryField.KEY, WidgetHttpClientProfile.APPLE))
    }

    @Test fun nonceCiphertextAndPlaintextHaveExactInclusiveEdges() {
        assertTrue(WidgetHttpPolicy.validResponseEnvelope(12, 12, 16))
        assertTrue(WidgetHttpPolicy.validResponseEnvelope(12, 12, 65_552))
        assertFalse(WidgetHttpPolicy.validResponseEnvelope(11, 12, 16))
        assertFalse(WidgetHttpPolicy.validResponseEnvelope(12, 13, 16))
        assertFalse(WidgetHttpPolicy.validResponseEnvelope(12, 12, 15))
        assertFalse(WidgetHttpPolicy.validResponseEnvelope(12, 12, 65_553))
        assertFalse(WidgetHttpPolicy.validResponseEnvelope(12, 12, Long.MAX_VALUE))
        assertTrue(WidgetHttpPolicy.validPlaintextSize(65_536))
        assertFalse(WidgetHttpPolicy.validPlaintextSize(65_537))
        assertFalse(WidgetHttpPolicy.validPlaintextSize(-1))
    }

    @Test fun associatedDataBindsTheOriginalRequestNonceAndSourceMessage() {
        val nonce = ByteArray(12) { (it + 128).toByte() }
        assertEquals("loki-widget-request-v1", WidgetHttpPolicy.REQUEST_CONTEXT)
        val aad = assertNotNull(WidgetHttpPolicy.responseAssociatedData(nonce))
        assertContentEquals("loki-widget-response-v1".encodeToByteArray() + nonce, aad)
        assertFalse(aad.contentEquals(WidgetHttpPolicy.responseAssociatedData(ByteArray(12))))
        assertNull(WidgetHttpPolicy.responseAssociatedData(ByteArray(11)))
        assertTrue(WidgetHttpPolicy.acceptsMessageSource("source", "source", "snapshot"))
        assertFalse(WidgetHttpPolicy.acceptsMessageSource("source", "other", "snapshot"))
        assertFalse(WidgetHttpPolicy.acceptsMessageSource("source", "source", "ping"))
    }
}
