package com.manonloki.lokimetrisdisplay

import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 临时 noBackup 目录与测试专用 AES key；不触碰设备 Keystore、真实配对或用户数据。 */
class AndroidWidgetDataTest {
    private val source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val device = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private val widgetKey = "lRknhcPotblkxFclfQ/VvPvqBMbhA3J+2WPJ+fIB+eo="
    private val storageKey = SecretKeySpec(ByteArray(32) { 17 }, "AES")

    private fun target(host: String = "192.168.1.10", sourceId: String = source): AndroidWidgetTarget =
        AndroidWidgetTarget(sourceId, device, host, 12345, widgetKey)

    private fun full(): TerminalSnapshot = TerminalSnapshot(1,
        TerminalTokens(TerminalDay("2026-10-21", "Asia/Shanghai", 100, 500), 300,
            TerminalAmount("18446744073709551615", "available", "partial", "derived"), emptyList()),
        null, true, listOf(TerminalHook("codex", 1, "running", "private-hook-body", true, "a".repeat(64))),
        listOf(TerminalAsset("a".repeat(64), "image/png", 1024)), "private-catalog-error")

    private fun record(at: Long = 1_000, sourceId: String = source): AndroidWidgetSnapshot =
        AndroidWidgetSnapshot.fromLive(sourceId, at, full())

    private fun isolated(body: (File, AndroidWidgetStore, AndroidWidgetStore) -> Unit) {
        val directory = Files.createTempDirectory("android-widget-test-").toFile()
        try {
            body(directory, AndroidWidgetStore(directory, { storageKey }, { 20_000 }),
                AndroidWidgetStore(directory, { storageKey }, { 20_000 }))
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun summaryDropsPrivateFieldsAndPreservesExactNumbersAndQuality() {
        val value = record()
        assertEquals("18446744073709551615", value.snapshot.tokens?.all?.total)
        assertEquals("部分 · 估算", value.snapshot.tokens?.all?.quality)
        assertEquals("", value.snapshot.hooks.single().content)
        assertFalse(value.snapshot.hooks.single().contentTruncated)
        assertNull(value.snapshot.hooks.single().image)
        assertTrue(value.snapshot.assets.isEmpty()); assertNull(value.snapshot.catalogError)
        assertFails { AndroidWidgetSnapshot(source, 1_000, full()).validate() }
        val bytes = AndroidWidgetCodec.encode(AndroidWidgetCodec.State(value, null))
        assertFalse(bytes.toString(Charsets.UTF_8).contains("private-hook-body"))
        assertFalse(bytes.toString(Charsets.UTF_8).contains("private-catalog-error"))
        assertEquals(value, AndroidWidgetCodec.decode(bytes).snapshot)
    }

    @Test
    fun enabledListIsCopiedAndExplicitlyDisabledAgentsStayHiddenAcrossStoreInstances() = isolated { _, first, second ->
        val enabled = mutableListOf("codex", "cursor")
        val original = full().copy(enabledAgents = enabled)
        val record = AndroidWidgetSnapshot.fromLive(source, 1_000, original)
        enabled.clear()
        assertEquals(listOf("codex", "cursor"), record.snapshot.enabledAgents)
        assertEquals(listOf("Cursor"), record.snapshot.displayUsageRows.map { it.displayName })
        assertTrue(first.acceptLive(record, target()))
        assertEquals(listOf("codex", "cursor"), second.read()?.snapshot?.enabledAgents)

        val disabled = AndroidWidgetSnapshot.fromLive(source, 2_000, full().copy(enabledAgents = emptyList()))
        assertTrue(second.acceptLive(disabled, target()))
        val restarted = assertNotNull(first.read()).snapshot
        assertEquals(emptyList(), restarted.enabledAgents)
        assertTrue(restarted.displayUsageRows.isEmpty())
        assertEquals("18446744073709551615", restarted.displayTokens?.all?.total)
        assertEquals("部分 · 估算", restarted.displayTokens?.all?.quality)
    }

    @Test
    fun targetAllowsOnlyNumericLocalPeersAndCanonicalCredentials() {
        for (host in listOf("192.168.1.10", "10.0.0.1", "172.16.0.1", "169.254.1.1", "127.0.0.1",
                "::1", "fd00::1", "fe80::1%wlan0", "::ffff:192.168.1.1")) target(host).validate()
        for (host in listOf("8.8.8.8", "172.32.0.1", "0.0.0.0", "255.255.255.255", "192.168.01.1",
                "example.com", "http://127.0.0.1", "127.0.0.1/path", "user@127.0.0.1", "::", "ff02::1",
                "2001:db8::1", "::ffff:8.8.8.8", "fe80::1%../wlan0", "fe80::1%", "[::1]")) {
            assertFails(host) { target(host).validate() }
        }
        assertFails { target().copy(port = 0).validate() }
        assertFails { target().copy(sourceId = device).validate() }
        assertFails { target().copy(sourceId = source.uppercase()).validate() }
        assertFails { target().copy(key = widgetKey.dropLast(1)).validate() }
        assertFalse(target().toString().contains(widgetKey))
        assertFalse(target().toString().contains("192.168.1.10"))
    }

    @Test
    fun requestMatchesDesktopRustAndApplePublicVector() {
        val nonce = ByteArray(12) { 3 }
        assertEquals("AwMDAwMDAwMDAwMD", AndroidWidgetCrypto.encode(nonce))
        assertEquals("Xb0+fryh6yKmj9ynUJN1ibves2wo6z40FJxtUvoAbZtNdXluBiI=",
            AndroidWidgetCrypto.request(widgetKey, nonce))
        assertNotEquals(AndroidWidgetCrypto.encode(AndroidWidgetCrypto.nonce()), AndroidWidgetCrypto.encode(AndroidWidgetCrypto.nonce()))
    }

    @Test
    fun responseRequiresExactRequestNonceKeyAndUntamperedCiphertext() {
        val requestNonce = ByteArray(12) { 3 }; val responseNonce = ByteArray(12) { 4 }
        val plaintext = "{\"type\":\"snapshot\"}".toByteArray()
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(Base64.getDecoder().decode(widgetKey), "ChaCha20"), IvParameterSpec(responseNonce))
        cipher.updateAAD("loki-widget-response-v1".toByteArray() + requestNonce)
        val encrypted = cipher.doFinal(plaintext)
        assertContentEquals(plaintext, AndroidWidgetCrypto.response(widgetKey, requestNonce, responseNonce, encrypted))
        assertFails { AndroidWidgetCrypto.response(widgetKey, ByteArray(12) { 5 }, responseNonce, encrypted) }
        assertFails { AndroidWidgetCrypto.response(AndroidWidgetCrypto.encode(ByteArray(32) { 8 }), requestNonce, responseNonce, encrypted) }
        val changed = encrypted.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertFails { AndroidWidgetCrypto.response(widgetKey, requestNonce, responseNonce, changed) }
        assertFails { AndroidWidgetCrypto.response(widgetKey, requestNonce, ByteArray(11), encrypted) }
    }

    @Test
    fun identicalTargetsKeepGenerationWhileAddressChangesRejectOldResponsesAcrossInstances() = isolated { _, first, second ->
        assertTrue(first.acceptLive(record(), target()))
        val initial = assertNotNull(second.target())
        assertTrue(second.acceptLive(record(2_000), target()))
        assertEquals(initial, first.target())
        assertTrue(second.acceptLive(record(3_000), target("192.168.1.11")))
        val next = assertNotNull(first.target())
        assertNotEquals(initial.generation, next.generation)
        assertFalse(first.acceptFetched(initial, record(4_000)))
        assertEquals(3_000, second.read()?.receivedAtMs)
        assertTrue(first.acceptFetched(next, record(4_000)))
        assertEquals(4_000, second.read()?.receivedAtMs)
    }

    @Test
    fun revokedSourcesAndUnsupportedCapabilityCannotBeResurrectedByLateFetch() = isolated { _, first, second ->
        assertTrue(first.clear(source)); assertTrue(first.clear(other))
        assertTrue(first.acceptLive(record(), target()))
        val old = assertNotNull(first.target())
        assertTrue(second.clear(other)); assertEquals(old, first.target())
        assertTrue(second.clear(source)); assertNull(first.read()); assertNull(first.target())
        assertFalse(first.acceptFetched(old, record(2_000)))
        assertTrue(first.acceptLive(record(3_000), target()))
        val previous = assertNotNull(first.target())
        assertTrue(second.acceptLive(record(4_000), null))
        assertNull(first.target()); assertEquals(4_000, first.read()?.receivedAtMs)
        assertFalse(first.acceptFetched(previous, record(5_000)))
        assertTrue(second.acceptLive(record(6_000, other), target(sourceId = other)))
        assertTrue(first.clear(source)); assertEquals(other, first.read()?.sourceId)
    }

    @Test
    fun requestStartPreventsSlowHttpOrOlderLiveSnapshotFromReplacingNewData() = isolated { _, first, second ->
        assertTrue(first.acceptLive(record(5_000), target()))
        val current = assertNotNull(first.target())
        assertFalse(second.acceptFetched(current, record(4_000)))
        assertTrue(second.acceptLive(record(3_000), target()))
        assertEquals(5_000, first.read()?.receivedAtMs)
        assertEquals(current, first.target())
        assertTrue(second.acceptFetched(current, record(6_000)))
        assertFalse(first.acceptFetched(current, record(30_000)))
        assertEquals(6_000, first.read()?.receivedAtMs)
    }

    @Test
    fun diskOnlyContainsRedactedSummaryAndEncryptedTargetAndBadKeyCannotOverwrite() = isolated { directory, first, second ->
        assertTrue(first.acceptLive(record(), target()))
        val initial = assertNotNull(first.target())
        val stored = File(directory, "summary-v1.bin").readBytes()
        assertFalse(stored.toString(Charsets.UTF_8).contains(widgetKey))
        assertFalse(stored.toString(Charsets.UTF_8).contains("192.168.1.10"))
        assertFalse(stored.toString(Charsets.UTF_8).contains("private-hook-body"))
        assertEquals(initial, second.target()); assertEquals(record(), second.read())
        val denied = AndroidWidgetStore(directory, { throw IllegalStateException("test key locked") }, { 20_000 })
        assertFalse(denied.acceptLive(record(2_000), target("192.168.1.12")))
        assertContentEquals(stored, File(directory, "summary-v1.bin").readBytes())
        assertEquals(initial, second.target()); assertEquals(1_000, first.read()?.receivedAtMs)
    }

    @Test
    fun malformedFilesAndSymlinksFailClosedAndExplicitClearRecovers() = isolated { directory, first, second ->
        assertTrue(first.acceptLive(record(), target()))
        val initial = assertNotNull(first.target())
        val file = File(directory, "summary-v1.bin")
        file.appendBytes(byteArrayOf(0))
        assertNull(first.read()); assertNull(second.target())
        assertTrue(first.acceptLive(record(2_000), target()))
        assertNotEquals(initial.generation, first.target()?.generation)
        assertFalse(second.acceptFetched(initial, record(4_000)))
        file.appendBytes(byteArrayOf(0))
        assertTrue(second.clear(source)); assertNull(first.read()); assertNull(first.target())
        assertTrue(first.acceptLive(record(3_000), target()))
        val backup = File(directory, "untouched.bin"); Files.move(file.toPath(), backup.toPath())
        Files.createSymbolicLink(file.toPath(), backup.toPath())
        val original = backup.readBytes()
        assertNull(first.read()); assertFalse(first.acceptLive(record(4_000), target()))
        assertContentEquals(original, backup.readBytes())
        assertTrue(first.clear()); assertContentEquals(original, backup.readBytes())
    }

    @Test
    fun boundedStreamsRejectOversizeBeforeReturningAndAllowCancellationChecks() {
        val max = AndroidWidgetHttpClient.MAX_RESPONSE_BYTES
        assertEquals(max, AndroidWidgetHttpClient.readBounded(ByteArrayInputStream(ByteArray(max)), max).size)
        assertFails { AndroidWidgetHttpClient.readBounded(ByteArrayInputStream(ByteArray(max + 1)), max) }
        var checks = 0
        assertFails { AndroidWidgetHttpClient.readBounded(ByteArrayInputStream(ByteArray(max)), max) {
            checks++; check(checks < 3)
        } }
        assertEquals(3, checks)
        val client = AndroidWidgetHttpClient(); client.cancel()
        assertEquals("cancelled", kotlin.test.assertFailsWith<AndroidWidgetHttpException> { client.fetch(target()) }.reason)
    }
}
