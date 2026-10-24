package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.storage.RefreshConnection
import kotlin.test.*

class RefreshConnectionTest {
    private fun connection(version: Int = 1, source: String = "source", device: String = "device",
                           host: String = "192.168.1.10", port: Int = 1234, key: String = "secret") =
        RefreshConnection(version, source, device, host, port, key)
    @Test fun everyCredentialFieldParticipatesAndDiagnosticsAreRedacted() {
        val original = connection()
        assertTrue(original.sameConnection(connection()))
        for (changed in listOf(connection(version = 2), connection(source = "other"), connection(device = "other"),
                connection(host = "192.168.1.11"), connection(port = 1235), connection(key = "other"))) {
            assertFalse(original.sameConnection(changed))
        }
        assertFalse(original.toString().contains("secret"))
        assertFalse(original.toString().contains("192.168"))
    }
}
