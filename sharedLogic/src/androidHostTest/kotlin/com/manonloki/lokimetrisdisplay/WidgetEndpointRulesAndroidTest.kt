package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 使用 JVM 的数值地址解析器衔接共享分类规则，不查询桌面主机名或发起连接。 */
class WidgetEndpointRulesAndroidTest {
    @Test fun nativeParserFeedsSharedAddressRulesWithoutAcceptingNamesOrNormalizingCase() {
        for (host in listOf("10.0.0.1", "172.31.255.255", "169.254.1.1", "::1", "fc00::1", "fdff::1",
                "fe80::1%wlan0", "fe80::1%" + "a".repeat(32), "::ffff:192.168.1.1", "::ffff:c0a8:101"))
            assertTrue(AndroidWidgetTarget.validHost(host), host)
        for (host in listOf("desktop.local", "desktop.local.", "FD00::1", "fe80::1%WLAN0", "fe80::1%" + "a".repeat(33),
                "fe80::1%../wlan0", "192.168.01.1", "::", "ff02::1", "fec0::1", "::192.168.1.1", "::ffff:8.8.8.8"))
            assertFalse(AndroidWidgetTarget.validHost(host), host)
    }
}
