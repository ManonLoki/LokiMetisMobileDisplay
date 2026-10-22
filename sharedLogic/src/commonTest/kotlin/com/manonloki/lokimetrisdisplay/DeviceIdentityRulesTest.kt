package com.manonloki.lokimetrisdisplay

import kotlin.test.*

class DeviceIdentityRulesTest {
    private val host = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val device = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    @Test fun recoveryRequiresUniqueValidIdentityAndNeverGuesses() {
        assertEquals(IdentityRecoveryStatus.MISSING, DeviceIdentityRules.recoverFromPairingAccounts(emptyList()).status)
        assertEquals(device, DeviceIdentityRules.recoverFromPairingAccounts(listOf("$host.$device", "$other.$device")).deviceId)
        assertEquals(IdentityRecoveryStatus.AMBIGUOUS, DeviceIdentityRules.recoverFromPairingAccounts(listOf("$host.$device", "$host.$other")).status)
        for (accounts in listOf(listOf("bad"), listOf("$host.$device.extra"), listOf("$host.${device.uppercase()}"),
                listOf("$device.$device"), listOf("$host.$device", "$host.$device"), List(65) { "$host.$device" })) {
            assertEquals(IdentityRecoveryStatus.INVALID_INDEX, DeviceIdentityRules.recoverFromPairingAccounts(accounts).status)
        }
    }
}
