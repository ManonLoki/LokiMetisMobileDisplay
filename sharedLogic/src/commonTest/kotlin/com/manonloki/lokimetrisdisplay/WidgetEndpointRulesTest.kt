package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.protocol.WidgetEndpointRules
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WidgetEndpointRulesTest {
    @Test fun ipv4LiteralsRemainStrictAndOnlyExistingLocalRangesAreAccepted() {
        for (host in listOf("10.0.0.0", "10.255.255.255", "127.0.0.1", "127.255.255.255",
                "172.16.0.0", "172.31.255.255", "192.168.0.0", "192.168.255.255", "169.254.0.0")) {
            assertTrue(WidgetEndpointRules.isPrivateIPv4Literal(host), host)
        }
        for (host in listOf("8.8.8.8", "0.0.0.0", "172.15.255.255", "172.32.0.0", "192.169.0.1",
                "169.255.0.1", "255.255.255.255", "127.1", "127.0.0.1.", "127..0.1", "127.0.0.01",
                "256.0.0.1", "+127.0.0.1", "0x7f.0.0.1", "１２７.0.0.1", "999999999999999999.0.0.1")) {
            assertFalse(WidgetEndpointRules.isPrivateIPv4Literal(host), host)
        }
    }

    @Test fun hostAndScopeBoundariesPreserveLowercaseAsciiAndExistingScopeCharacters() {
        assertTrue(WidgetEndpointRules.validHostText("a".repeat(253)))
        for (host in listOf("", "a".repeat(254), "DESKTOP.local", " host.local", "host.local\n", "本机.local", "a\u007f"))
            assertFalse(WidgetEndpointRules.validHostText(host), host)
        for (scope in listOf("en0", "wlan0", "a-0._", ".", "..", "a".repeat(32)))
            assertTrue(WidgetEndpointRules.validIPv6Scope(scope), scope)
        for (scope in listOf("", "a".repeat(33), "EN0", "../en0", "en0%1", "en0:1", "网卡"))
            assertFalse(WidgetEndpointRules.validIPv6Scope(scope), scope)
    }

    @Test fun parsedIpv4AndMappedIpv6HaveTheSameClassification() {
        for ((bytes, expected) in listOf(listOf(10, 0, 0, 1) to true, listOf(127, 0, 0, 1) to true,
                listOf(192, 168, 1, 1) to true, listOf(172, 16, 0, 1) to true,
                listOf(8, 8, 8, 8) to false, listOf(0, 0, 0, 0) to false)) {
            assertEquals(expected, WidgetEndpointRules.isPrivateAddress(bytes))
            assertEquals(expected, WidgetEndpointRules.isPrivateAddress(List(10) { 0 } + listOf(255, 255) + bytes))
        }
    }

    @Test fun parsedIpv6AcceptsOnlyLoopbackUniqueLocalAndLinkLocal() {
        assertTrue(WidgetEndpointRules.isPrivateAddress(List(15) { 0 } + 1))
        for (prefix in listOf(listOf(0xfc, 0), listOf(0xfd, 0xff), listOf(0xfe, 0x80), listOf(0xfe, 0xbf)))
            assertTrue(WidgetEndpointRules.isPrivateAddress(prefix + List(14) { 0 }))
        for (bytes in listOf(List(16) { 0 }, listOf(0xff, 2) + List(14) { 0 },
                listOf(0x20, 1) + List(14) { 0 }, listOf(0xfe, 0xc0) + List(14) { 0 },
                List(12) { 0 } + listOf(192, 168, 1, 1)))
            assertFalse(WidgetEndpointRules.isPrivateAddress(bytes))
        for (bytes in listOf(emptyList(), List(3) { 0 }, List(17) { 0 }, listOf(127, -1, 0, 1), listOf(127, 0, 0, 256)))
            assertFalse(WidgetEndpointRules.isPrivateAddress(bytes))
    }
}
