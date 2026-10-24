package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.connection.AndroidLanNetworkState
import com.manonloki.lokimetrisdisplay.connection.AndroidLanRoute
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AndroidLanNetworkStateTest {
    private val wifi = AndroidLanRoute("wlan0", setOf("192.168.1.2/24"), setOf("192.168.1.0/24 -> wlan0"))

    @Test fun replacingWifiNetworkWithTheSameLocalAddressStillRestartsDiscovery() {
        val state = AndroidLanNetworkState<Int>()
        assertTrue(state.updated(100, wifi))
        assertFalse(state.updated(100, wifi))
        assertTrue(state.updated(101, wifi))
        assertTrue(state.lost(100))
        assertFalse(state.updated(101, wifi))
    }

    @Test fun dhcpAndRouteChangesOnTheSameNetworkInvalidateOldConnections() {
        val state = AndroidLanNetworkState<Int>()
        assertTrue(state.updated(100, wifi))
        assertTrue(state.updated(100, wifi.copy(addresses = setOf("192.168.2.2/24"))))
        assertTrue(state.updated(100, wifi.copy(routes = setOf("192.168.1.0/24 -> eth0"))))
    }

    @Test fun interfaceAndAddressOrderingDoNotProduceDuplicateChanges() {
        val state = AndroidLanNetworkState<Int>()
        val route = wifi.copy(addresses = linkedSetOf("192.168.1.2/24", "fe80::1/64"))
        assertTrue(state.updated(100, route))
        assertFalse(state.updated(100, route.copy(addresses = linkedSetOf("fe80::1/64", "192.168.1.2/24"))))
        assertTrue(state.updated(100, route.copy(interfaceName = "eth0")))
    }

    @Test fun lossAndStopDiscardOldTopologyBeforeTheNextForegroundSession() {
        val state = AndroidLanNetworkState<Int>()
        assertFalse(state.lost(100))
        assertTrue(state.updated(100, wifi))
        assertTrue(state.lost(100))
        assertFalse(state.lost(100))
        assertTrue(state.updated(100, wifi))
        state.clear()
        assertFalse(state.lost(100))
        assertTrue(state.updated(100, wifi))
    }
}
