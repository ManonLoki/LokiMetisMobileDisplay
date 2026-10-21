package com.manonloki.lokimetrisdisplay

import java.io.File
import java.nio.file.Files
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.test.*

/** 纯JCA、临时目录和合成材料；不访问Android服务、真实配对或用户秘密。 */
class PairingRecoveryTest {
    private val device = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private val previous = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val client = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val secret = Base64.getEncoder().encodeToString(ByteArray(32) { 17 })
    private val code = Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
    private val material get() = PairingRecoveryCodec.Material(client, device, "演示端", secret)
    private val payload get() = PairingRecoveryCodec.Payload(device, listOf(material))

    @Test fun random_roundtrip_excludes_plaintext_and_redacts_descriptions() {
        val first = PairingRecoveryCodec.export(payload)
        val second = PairingRecoveryCodec.export(payload)
        assertNotEquals(first.recoveryCode, second.recoveryCode)
        assertFalse(first.bytes.contentEquals(second.bytes))
        val text = first.bytes.toString(Charsets.UTF_8)
        listOf(device, client, secret, first.recoveryCode, "演示端").forEach { assertFalse(text.contains(it)) }
        assertEquals(payload, PairingRecoveryCodec.open(first.bytes, "\n${first.recoveryCode} "))
        assertFalse(first.toString().contains(first.recoveryCode)); assertFalse(payload.toString().contains(secret))
        assertFalse(material.toString().contains(secret))
    }

    @Test fun cryptokit_and_jca_share_a_fixed_wire_vector() {
        val bytes = PairingRecoveryCodec.seal(payload, code, ByteArray(12) { it.toByte() })
        val envelope = RecoveryJson.objectFrom(bytes)
        assertEquals(VECTOR_CIPHERTEXT, envelope["ciphertext"])
        assertEquals("l6gFI6oTPSNRrzy1egeAaQ==", envelope["tag"])
        assertEquals(payload, PairingRecoveryCodec.open(bytes, code))
    }

    @Test fun wrong_keys_tampering_and_noncanonical_json_are_rejected() {
        val output = PairingRecoveryCodec.export(payload)
        assertFails { PairingRecoveryCodec.open(output.bytes, code) }
        listOf("1234", output.recoveryCode.dropLast(1), output.recoveryCode + " X").forEach {
            assertFails { PairingRecoveryCodec.open(output.bytes, it) }
        }
        val original = RecoveryJson.objectFrom(output.bytes)
        listOf("nonce", "ciphertext", "tag").forEach { field ->
            val raw = Base64.getDecoder().decode(original.getValue(field) as String)
            raw[0] = (raw[0].toInt() xor 1).toByte()
            val changed = original + (field to Base64.getEncoder().encodeToString(raw))
            assertFails { PairingRecoveryCodec.open(RecoveryJson.encode(changed), output.recoveryCode) }
        }
        val text = output.bytes.toString(Charsets.UTF_8)
        listOf(
            text.replace("\"version\":1", "\"version\":1.0"),
            text.replace("\"version\":1", "\"version\":true"),
            text.replace("\"version\":1", "\"version\":\"1\""),
            text.replace("\"version\":1", "\"version\":1,\"version\":1"),
            text.replace("\"version\":1", "\"version\":1,\"\\u0076ersion\":1"),
            text.replace("AES-256-GCM", "OTHER"), "[$text]",
        ).forEach { assertFails { PairingRecoveryCodec.open(it.toByteArray(), output.recoveryCode) } }
        assertFails { PairingRecoveryCodec.open(ByteArray(PairingRecoveryCodec.MAX_BYTES + 1), code) }
        assertFails { RecoveryJson.objectFrom("{\"name\":\"\\ud800\"}".toByteArray()) }
    }

    @Test fun authenticated_payload_requires_exact_role_identity_and_materials() {
        val valid = mapOf("version" to 1, "role" to "mobile", "deviceId" to device, "records" to listOf(material.fields()))
        listOf(valid + ("role" to "desktop"), valid + ("deviceId" to client), valid + ("endpoint" to "192.168.1.5"),
            valid + ("records" to listOf(material.fields() + ("hook" to "private")))).forEach {
            assertFails { PairingRecoveryCodec.open(authenticated(it), code) }
        }
        listOf(material.copy(deviceId = client), material.copy(clientId = device), material.copy(clientId = client.uppercase()),
            material.copy(name = "\u0001"), material.copy(name = " "), material.copy(name = "字".repeat(54)),
            material.copy(secret = secret.dropLast(1)), material.copy(secret = Base64.getEncoder().encodeToString(ByteArray(32)))).forEach {
            assertFails { PairingRecoveryCodec.validate(PairingRecoveryCodec.Payload(device, listOf(it))) }
        }
        assertFails { PairingRecoveryCodec.validate(payload.copy(materials = emptyList())) }
        assertFails { PairingRecoveryCodec.validate(payload.copy(materials = listOf(material, material))) }
        assertFails { PairingRecoveryCodec.validate(payload.copy(materials = List(65) { material })) }
    }

    @Test fun interrupted_recovery_replays_complete_map_before_identity() = isolated { journal ->
        for (stop in listOf("records", "identity")) {
            val disk = FakeDisk(previous, journal)
            disk.stopAfter = stop
            assertFails { disk.transaction().begin(device, encrypted) }
            assertTrue(journal.isFile)
            assertEquals(encrypted, disk.records)
            assertFalse(journal.readText().contains(secret))
            disk.stopAfter = null
            disk.transaction().replay()
            assertEquals(device, disk.identity); assertEquals(encrypted, disk.records)
            assertFalse(journal.exists())
        }
    }

    @Test fun failed_commit_and_conflicts_never_create_an_unrelated_identity() = isolated { journal ->
        val disk = FakeDisk(previous, journal)
        disk.commitRecords = false
        assertFails { disk.transaction().begin(device, encrypted) }
        assertEquals(previous, disk.identity); assertTrue(journal.isFile)
        disk.commitRecords = true; disk.transaction().replay()
        assertEquals(device, disk.identity); assertFalse(journal.exists())
        assertFails { disk.transaction().begin(previous, encrypted) }
        assertEquals(device, disk.identity); assertEquals(encrypted, disk.records)
    }

    @Test fun invalid_or_conflicting_pending_journal_is_preserved_without_writes() = isolated { journal ->
        val disk = FakeDisk(previous, journal)
        disk.stopAfter = "records"
        assertFails { disk.transaction().begin(device, encrypted) }
        val valid = journal.readBytes()
        disk.stopAfter = null; disk.identity = client
        assertFails { disk.transaction().replay() }
        assertEquals(client, disk.identity); assertContentEquals(valid, journal.readBytes())
        disk.identity = previous; disk.records = mapOf(client to "other-ciphertext")
        assertFails { disk.transaction().replay() }; assertEquals(previous, disk.identity)
        disk.records = emptyMap(); journal.writeText("{\"version\":1,\"version\":1}")
        assertFails { disk.transaction().replay() }; assertTrue(disk.records.isEmpty()); assertEquals(previous, disk.identity)
    }

    private val encrypted get() = mapOf(client to "{\"iv\":\"synthetic-nonce\",\"ciphertext\":\"synthetic-encrypted-bytes\"}")
    private inner class FakeDisk(var identity: String, val journal: File) {
        var records = emptyMap<String, String>()
        var stopAfter: String? = null
        var commitRecords = true
        fun transaction() = PairingRecoveryTransaction(journal,
            loadRecords = { records },
            saveRecords = { records = it; check(stopAfter != "records") { "simulated_process_exit" }; commitRecords },
            loadIdentity = { identity },
            saveIdentity = { identity = it; check(stopAfter != "identity") { "simulated_process_exit" }; true },
            validateRecords = { target, values -> check(target == device && values == encrypted) { "synthetic_invalid_ciphertext" } })
    }
    private fun isolated(body: (File) -> Unit) {
        val directory = Files.createTempDirectory("pairing-recovery-test-").toFile()
        try { body(File(directory, "pending.json")) } finally { directory.deleteRecursively() }
    }
    private fun authenticated(payload: Map<String, Any>): ByteArray {
        val nonce = ByteArray(12) { it.toByte() }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(Base64.getDecoder().decode(code), "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD("LokiMetris/pairing-recovery/mobile/1".toByteArray())
        val sealed = cipher.doFinal(RecoveryJson.encode(payload))
        return RecoveryJson.encode(mapOf("format" to "loki-metris-pairing-recovery", "version" to 1, "algorithm" to "AES-256-GCM",
            "nonce" to Base64.getEncoder().encodeToString(nonce),
            "ciphertext" to Base64.getEncoder().encodeToString(sealed.copyOfRange(0, sealed.size - 16)),
            "tag" to Base64.getEncoder().encodeToString(sealed.copyOfRange(sealed.size - 16, sealed.size))))
    }

    companion object {
        private const val VECTOR_CIPHERTEXT = "PCCyfrOMoX7EJbWxk4obDuC15FeTVjwfWwTIsX4KY585c82fgqJx+xfHHI7r5EtbjXtMryizwLVN81k7IriOzJNQrx+9pW8FPm6ID47ub4lZ66hPFwIyCdDJ/60Z3YHsqpl0h8UgqXv/fV/TKRRAXZZFBs6VrEb/BJt196CFDW3YMWOl1/qoMGuCZZVeuS/vDpeAVhhy8CnvPIsUmbGKjfC1sjeHnqEbhVn/HGMUYR8nKWGNqYdRzwC8sqIF543RVh7PqEiPk5tyBJa0/xOc1qQsvSR4Uv+jNMPflQQayqgGcZH9o3JGdxcV/TWXbCF9iuHWGfgSs4d6BAUa5/lgrTanl+LusydQVeVDeg=="
    }
}
