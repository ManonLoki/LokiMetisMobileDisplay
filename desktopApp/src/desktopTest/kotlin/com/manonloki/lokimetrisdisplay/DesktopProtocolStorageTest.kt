package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.attribute.PosixFileAttributeView
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.*

class DesktopProtocolStorageTest {
    private val device = "11111111-1111-4111-8111-111111111111"
    private val client = "22222222-2222-4222-8222-222222222222"
    @Test fun padIdentityPreservesLocalIdentityAndNegotiatesExactlyOncePerConnection() {
        val identity = DesktopPadIdentity(device)
        val metadata = identity.metadata("Desk")
        assertEquals("android", metadata.string("platform")); assertEquals(device, metadata.string("deviceId"))
        assertEquals("1.0.7-desktop-experimental", metadata.string("appVersion"))
        assertFalse(metadata.has("formFactor"))
        assertNull(identity.afterSnapshot(emptyList()))
        val report = assertNotNull(identity.afterSnapshot(listOf("deviceFormFactorV1")))
        assertEquals("tablet", report.string("formFactor"))
        assertNull(identity.afterSnapshot(listOf("deviceFormFactorV1")))
        identity.reset()
        assertEquals("tablet", assertNotNull(identity.afterSnapshot(listOf("deviceFormFactorV1"))).string("formFactor"))
    }
    @Test fun pairingMaterialSurvivesReopenAndForgetWithoutLeakingIntoOtherIdentity() {
        val directory = Files.createTempDirectory("loki-pair-test-")
        try {
            val material = JSONObject().put("deviceId", device).put("clientId", client).put("secret", "private-test-secret")
            val store = DesktopPairingStore(directory, device)
            assertTrue(store.save(material))
            assertEquals(setOf(client), DesktopPairingStore(directory, device).clientIds())
            assertEquals("private-test-secret", DesktopPairingStore(directory, device).load(client)?.string("secret"))
            assertFails { DesktopPairingStore(directory, client) }
            val file = directory.resolve("pairings-v1.json")
            if (Files.getFileAttributeView(file, PosixFileAttributeView::class.java, NOFOLLOW_LINKS) != null)
                assertEquals(PosixFilePermissions.fromString("rw-------"), Files.getPosixFilePermissions(file))
            assertTrue(store.forget(client)); assertTrue(DesktopPairingStore(directory, device).clientIds().isEmpty())
        } finally { directory.toFile().deleteRecursively() }
    }
    @Test fun failedCommitLeavesPreviouslyCommittedMaterial() {
        val directory = Files.createTempDirectory("loki-pair-fail-")
        try {
            val store = DesktopPairingStore(directory, device)
            assertTrue(store.save(JSONObject().put("deviceId", device).put("clientId", client).put("secret", "old-secret")))
            Files.delete(directory.resolve("pairings-v1.json")); Files.createDirectory(directory.resolve("pairings-v1.json"))
            assertFalse(store.forget(client)); assertEquals("old-secret", store.load(client)?.string("secret"))
        } finally { directory.toFile().deleteRecursively() }
    }
    @Test fun snapshotRejectsWrongTypesAndDuplicateSlots() {
        val valid = """{"type":"snapshot","snapshot":{"version":1,"hooksAvailable":true,"hooks":[],"assets":[]}}"""
        assertNotNull(DesktopDisplayJson.snapshot(JSONObject(valid)))
        assertFails { DesktopDisplayJson.snapshot(JSONObject(valid.replace("\"version\":1", "\"version\":\"1\""))) }
        val duplicate = JSONObject(valid)
        val hook = JSONObject().put("agent", "Codex").put("slot", 1).put("behavior", "idle").put("content", "").put("contentTruncated", false)
        duplicate.obj("snapshot").getJSONArray("hooks").put(hook).put(hook)
        assertFails { DesktopDisplayJson.snapshot(duplicate) }
        val duplicateKeys = "{\"type\":\"snapshot\",\"type\":\"ping\"}"
        assertFails { TerminalJsonBoundary.validateObject(duplicateKeys); JSONObject(duplicateKeys) }
    }
}
