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

    /** Swift 的 JSON 类型错误传 null，坏能力表必须返回错误而不把 Kotlin 异常带过边界。 */
    @Test fun native_decision_rejects_invalid_input_without_consuming_report() {
        val report = TerminalDeviceTypeReport(TerminalDeviceType.TABLET)
        val invalid = listOf(null, listOf(""), listOf("deviceFormFactorV1", "deviceFormFactorV1"),
            List(17) { "cap$it" }, listOf("长".repeat(22)))
        for (capabilities in invalid) {
            assertEquals(TerminalDeviceTypeDecision(false, null), report.evaluateAuthenticatedSnapshot(capabilities))
        }
        assertEquals(TerminalDeviceTypeDecision(true, TerminalDeviceType.TABLET),
            report.evaluateAuthenticatedSnapshot(listOf("deviceFormFactorV1")))
        // 已上报后也不能忽略同连接随后出现的非法能力表。
        assertEquals(TerminalDeviceTypeDecision(false, null), report.evaluateAuthenticatedSnapshot(null))
    }

    /** 宿主边界验证未知形态、旧主机、单连接一次及重新认证后的上报资格。 */
    @Test fun native_decision_preserves_live_capability_and_reconnection_rules() {
        val supported = listOf("deviceFormFactorV1", "watchCompanionV1")
        for (type in TerminalDeviceType.entries) {
            val report = TerminalDeviceTypeReport(type)
            assertEquals(TerminalDeviceTypeDecision(true, null), report.evaluateAuthenticatedSnapshot(emptyList()))
            assertEquals(TerminalDeviceTypeDecision(true, null), report.evaluateAuthenticatedSnapshot(listOf("watchCompanionV1")))
            assertEquals(TerminalDeviceTypeDecision(true, type), report.evaluateAuthenticatedSnapshot(supported))
            assertEquals(TerminalDeviceTypeDecision(true, null), report.evaluateAuthenticatedSnapshot(supported))
            report.reset()
            assertEquals(TerminalDeviceTypeDecision(true, null), report.evaluateAuthenticatedSnapshot(emptyList()))
            assertEquals(TerminalDeviceTypeDecision(true, type), report.evaluateAuthenticatedSnapshot(supported))
        }
        assertEquals(TerminalDeviceTypeDecision(true, null), TerminalDeviceTypeReport(null).evaluateAuthenticatedSnapshot(supported))
    }

    /** 两种宿主入口共用状态；边界长度按 UTF-8 字节计算而非字符数量。 */
    @Test fun native_and_android_entries_share_one_report_budget_and_byte_limits() {
        val report = TerminalDeviceTypeReport(TerminalDeviceType.PHONE)
        val atLimit = listOf("deviceFormFactorV1", "a".repeat(64), "长".repeat(21) + "a")
        assertEquals(TerminalDeviceTypeDecision(true, TerminalDeviceType.PHONE), report.evaluateAuthenticatedSnapshot(atLimit))
        assertNull(report.afterAuthenticatedSnapshot(atLimit))
        report.reset()
        assertEquals(TerminalDeviceType.PHONE, report.afterAuthenticatedSnapshot(atLimit))
        assertEquals(TerminalDeviceTypeDecision(true, null), report.evaluateAuthenticatedSnapshot(atLimit))
        assertEquals(TerminalDeviceTypeDecision(false, null), report.evaluateAuthenticatedSnapshot(listOf("a".repeat(65))))
    }
}
