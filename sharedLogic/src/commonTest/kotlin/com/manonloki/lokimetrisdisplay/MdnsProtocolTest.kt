package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.protocol.MdnsProtocol
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 发现服务与稳定身份的跨平台合同测试。 */
class MdnsProtocolTest {
    private val id = "12345678-1234-4abc-8def-123456789abc"

    /** 手机浏览桌面服务，不再发布只能关闭连接的旧终端广播。 */
    @Test
    fun desktop_service_matches_current_protocol() {
        assertEquals("_loki-host._tcp.local.", MdnsProtocol.SERVICE_TYPE + MdnsProtocol.DOMAIN)
    }

    /** 既有设备ID不允许静默重建或接受非规范值。 */
    @Test
    fun identity_requires_nonzero_canonical_lowercase_uuid() {
        assertTrue(MdnsProtocol.isCanonicalDeviceId(id))
        listOf("", "00000000-0000-0000-0000-000000000000", id.uppercase(),
            id.replace('-', '_'), id.dropLast(1), " $id", id.replace('a', 'g'))
            .forEach { assertFalse(MdnsProtocol.isCanonicalDeviceId(it), it) }
    }

    /** 中英文与emoji统一按UTF-8上限校验，控制字符不能进入广告或设备信息。 */
    @Test
    fun names_use_utf8_byte_limit_and_reject_controls() {
        assertNull(MdnsProtocol.nameError("a".repeat(160)))
        assertNull(MdnsProtocol.nameError("屏".repeat(53)))
        assertNotNull(MdnsProtocol.nameError("屏".repeat(54)))
        assertNull(MdnsProtocol.nameError("😀".repeat(40)))
        assertNotNull(MdnsProtocol.nameError("😀".repeat(41)))
        listOf("", " \t", "\u2003", "a\nb", "a\u0000b", "a\u007fb", "a\u0085b")
            .forEach { assertNotNull(MdnsProtocol.nameError(it)) }
    }
}
