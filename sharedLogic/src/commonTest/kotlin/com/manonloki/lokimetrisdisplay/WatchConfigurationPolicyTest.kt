package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.rules.TerminalValueRules
import com.manonloki.lokimetrisdisplay.storage.RefreshConnection
import com.manonloki.lokimetrisdisplay.storage.WatchConfigurationAcceptance
import com.manonloki.lokimetrisdisplay.storage.WatchConfigurationPolicy
import com.manonloki.lokimetrisdisplay.storage.WatchConfigurationState
import com.manonloki.lokimetrisdisplay.storage.WatchConfigurationTarget
import kotlin.test.*

/** 以纯配置对象验证修订、防回退、撤销和来源绑定；地址解析及密钥存储由平台测试覆盖。 */
class WatchConfigurationPolicyTest {
    private val phone = "12345678-1234-4abc-8def-123456789abc"
    private val desktop = "22345678-1234-4abc-8def-123456789abc"
    private val other = "32345678-1234-4abc-8def-123456789abc"
    private val generation = "42345678-1234-4abc-8def-123456789abc"
    private val policy = WatchConfigurationPolicy

    private fun target(deviceId: String = phone, sourceId: String = desktop, generation: String = this.generation,
                       host: String = "192.168.1.20", key: String = "private-key") =
        WatchConfigurationTarget(sourceId, deviceId, generation,
            RefreshConnection(1, sourceId, deviceId, host, 8123, key))

    private fun configuration(revision: String = "1", target: WatchConfigurationTarget? = target(),
                              phoneId: String = phone, version: Int = 1) =
        WatchConfigurationState(version, phoneId, revision, target)

    @Test fun bindingAndUnsignedRevisionAreValidatedWithoutSignedOrFloatingConversion() {
        assertTrue(policy.valid(configuration(revision = ULong.MAX_VALUE.toString())))
        assertTrue(policy.valid(configuration(revision = "0", target = null)))
        for (value in listOf("", "01", "-1", "+1", "1.0", "18446744073709551616")) {
            assertFalse(policy.valid(configuration(revision = value)), value)
        }
        assertFalse(policy.valid(configuration(version = Int.MIN_VALUE)))
        assertFalse(policy.valid(configuration(version = 2)))
        assertFalse(policy.valid(configuration(phoneId = phone.uppercase())))
        assertFalse(policy.valid(configuration(phoneId = TerminalValueRules.ZERO_ID)))
        assertFalse(policy.valid(configuration(target = target(deviceId = other))))
        assertFalse(policy.valid(configuration(target = target(sourceId = phone))))
        assertFalse(policy.valid(configuration(target = target(generation = "invalid"))))
    }

    @Test fun revocationRejectsLateAuthorizationAndEqualRevisionConflict() {
        val authorized = configuration("1")
        val revoked = configuration("2", target = null)
        assertEquals(WatchConfigurationAcceptance.REPLACE, policy.acceptance(authorized, null))
        assertEquals(WatchConfigurationAcceptance.REPLACE, policy.acceptance(revoked, authorized))
        assertEquals(WatchConfigurationAcceptance.REJECT, policy.acceptance(authorized, revoked))
        assertEquals(WatchConfigurationAcceptance.REJECT, policy.acceptance(configuration("2"), revoked))
        assertEquals(WatchConfigurationAcceptance.UNCHANGED, policy.acceptance(configuration("2", null), revoked))
        assertEquals(WatchConfigurationAcceptance.REPLACE, policy.acceptance(configuration("3"), revoked))
        val lastAuthorization = configuration((ULong.MAX_VALUE - 1UL).toString())
        val finalRevocation = configuration(ULong.MAX_VALUE.toString(), null)
        assertEquals(WatchConfigurationAcceptance.REPLACE, policy.acceptance(finalRevocation, lastAuthorization))
        assertEquals(WatchConfigurationAcceptance.REJECT, policy.acceptance(lastAuthorization, finalRevocation))
        assertEquals(WatchConfigurationAcceptance.REJECT,
            policy.acceptance(configuration(ULong.MAX_VALUE.toString()), finalRevocation))
    }

    @Test fun sameRevisionRequiresAllCredentialAndGenerationFieldsToMatch() {
        val current = configuration("9223372036854775808")
        assertEquals(WatchConfigurationAcceptance.UNCHANGED, policy.acceptance(configuration(current.revision), current))
        for (changed in listOf(target(host = "192.168.1.21"), target(key = "changed"), target(generation = other),
                target(sourceId = other))) {
            assertEquals(WatchConfigurationAcceptance.REJECT, policy.acceptance(configuration(current.revision, changed), current))
        }
        assertEquals(WatchConfigurationAcceptance.REPLACE,
            policy.acceptance(configuration("0", target(deviceId = other), phoneId = other), current))
        assertEquals(WatchConfigurationAcceptance.REJECT, policy.acceptance(configuration("bad"), current))
    }

    @Test fun generationReuseAndPublicationDeduplicationPreserveExplicitRevocations() {
        val current = configuration()
        val regenerated = target(generation = other)
        assertTrue(policy.reusePreviousTarget(current.target, regenerated))
        assertFalse(policy.reusePreviousTarget(current.target, target(key = "rotated")))
        assertFalse(policy.reusePreviousTarget(current.target, null))
        assertFalse(policy.needsPublication(current, target(), false))
        assertTrue(policy.needsPublication(current, regenerated, false))
        assertTrue(policy.needsPublication(current, current.target, true))
        assertTrue(policy.needsPublication(current, null, false))
        assertFalse(policy.needsPublication(configuration(target = null), null, false))
        assertTrue(policy.needsPublication(null, null, false))
    }

    @Test fun revisionIssuanceAndRepairStayExactAtTheWholeUnsignedBoundary() {
        assertEquals("1", policy.nextRevision("0", "0"))
        assertEquals("51", policy.nextRevision("50", "20"))
        assertEquals("51", policy.nextRevision("20", "50"))
        assertEquals("9223372036854775808", policy.nextRevision(Long.MAX_VALUE.toString(), "0"))
        assertEquals(ULong.MAX_VALUE.toString(), policy.nextRevision((ULong.MAX_VALUE - 1UL).toString(), "0"))
        assertNull(policy.nextRevision(ULong.MAX_VALUE.toString(), "0"))
        assertNull(policy.nextRevision("0", ULong.MAX_VALUE.toString()))
        assertNull(policy.nextRevision("01", "0"))
        assertNull(policy.nextRevision("0", "-1"))
        assertEquals(ULong.MAX_VALUE.toString(), policy.observedRevisionFloor("1", ULong.MAX_VALUE.toString()))
        assertFalse(policy.shouldReissue("10", "9", false))
        assertFalse(policy.shouldReissue("10", "10", true))
        assertTrue(policy.shouldReissue("10", "10", false))
        assertTrue(policy.shouldReissue("10", ULong.MAX_VALUE.toString(), false))
        assertFalse(policy.shouldReissue("10", "bad", false))
    }

    @Test fun configurationChangesRetainOnlyEligibleCachedSnapshotAndTransfer() {
        val current = configuration()
        val revoked = configuration("2", null)
        assertTrue(policy.keepSnapshot(current, phone, desktop))
        assertFalse(policy.keepSnapshot(current, other, desktop))
        assertFalse(policy.keepSnapshot(current, phone, other))
        assertTrue(policy.keepSnapshot(revoked, phone, desktop))
        assertFalse(policy.keepSnapshot(revoked, null, null))
        assertTrue(policy.keepTransfer(current, null, true))
        assertTrue(policy.keepTransfer(current, revoked, true))
        assertFalse(policy.keepTransfer(revoked, current, true))
        assertFalse(policy.keepTransfer(configuration(target = target(sourceId = other)), current, true))
        assertFalse(policy.keepTransfer(configuration(phoneId = other, target = target(deviceId = other)), current, true))
        assertFalse(policy.keepTransfer(current, current, false))
        assertTrue(policy.acceptsHTTPSource(current, desktop))
        assertFalse(policy.acceptsHTTPSource(current, other))
        assertFalse(policy.acceptsHTTPSource(revoked, desktop))
        assertFalse(current.toString().contains(phone))
        assertFalse(target().toString().contains("private-key"))
    }
}
