package com.manonloki.lokimetrisdisplay

import kotlin.test.*

/** 系统分类和实时协商共同决定上报，旧主机与坏能力表均不能开启新消息。 */
class TerminalDeviceTypeTest {
    /** 平板边界来自系统dp，未知配置保持未知；不根据设备名称猜测。 */
    @Test fun system_width_classification_preserves_unknown_and_tablet_boundary() {
        assertNull(TerminalDeviceType.fromSmallestWidthDp(0))
        assertEquals(TerminalDeviceType.PHONE, TerminalDeviceType.fromSmallestWidthDp(599))
        assertEquals(TerminalDeviceType.TABLET, TerminalDeviceType.fromSmallestWidthDp(600))
        assertEquals(TerminalDeviceType.TABLET, TerminalDeviceType.fromSmallestWidthDp(800))
    }
    /** 旧桌面零发送，同连接只发一次，重新认证必须重新看到能力广告。 */
    @Test fun only_live_capability_reports_once_per_connection() {
        val report = TerminalDeviceTypeReport(TerminalDeviceType.TABLET)
        assertNull(report.afterAuthenticatedSnapshot(emptyList()))
        assertNull(report.afterAuthenticatedSnapshot(listOf("watchCompanionV1")))
        assertEquals(TerminalDeviceType.TABLET, report.afterAuthenticatedSnapshot(listOf("deviceFormFactorV1")))
        assertNull(report.afterAuthenticatedSnapshot(listOf("deviceFormFactorV1")))
        report.reset()
        assertNull(report.afterAuthenticatedSnapshot(emptyList()))
        assertEquals(TerminalDeviceType.TABLET, report.afterAuthenticatedSnapshot(listOf("deviceFormFactorV1")))
        assertNull(TerminalDeviceTypeReport(null).afterAuthenticatedSnapshot(listOf("deviceFormFactorV1")))
    }
    /** 重复、超长或过量能力不消耗一次上报资格。 */
    @Test fun invalid_capabilities_fail_before_reporting() {
        val report = TerminalDeviceTypeReport(TerminalDeviceType.PHONE)
        listOf(listOf("deviceFormFactorV1", "deviceFormFactorV1"), List(17) { "cap$it" }, listOf(""), listOf("长".repeat(22))).forEach { values ->
            assertFailsWith<IllegalArgumentException> { report.afterAuthenticatedSnapshot(values) }
        }
        assertEquals(TerminalDeviceType.PHONE, report.afterAuthenticatedSnapshot(listOf("deviceFormFactorV1")))
    }
}
