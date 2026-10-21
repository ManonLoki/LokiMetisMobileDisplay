package com.manonloki.lokimetrisdisplay

import kotlin.test.*

/** 组件私有格式升级保留额度，兼容旧缓存，不把原始正文带进组件。 */
class ProviderQuotaCodecTest {
    @Test fun quota_roundtrip_preserves_weekly_only_and_legacy_without_quota() {
        val quota = ProviderQuotaSnapshot(123, listOf(ProviderQuotaEntry("codex", "pro", null, ProviderQuotaWindow("weekly", 970, 1900000000))))
        val snapshot = TerminalSnapshot(1, null, null, false, emptyList(), emptyList(), null, quota)
        val record = AndroidWidgetSnapshot.fromLive("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 1_000, snapshot)
        val bytes = AndroidWidgetCodec.encode(AndroidWidgetCodec.State(record, null))
        assertEquals(quota, AndroidWidgetCodec.decode(bytes).snapshot.snapshot.providerQuota)
        val oldRecord = record.copy(snapshot = snapshot.copy(providerQuota = null))
        val current = AndroidWidgetCodec.encode(AndroidWidgetCodec.State(oldRecord, null))
        val legacy = current.copyOf(current.size - 1)
        legacy[3] = 0x31
        assertNull(AndroidWidgetCodec.decode(legacy).snapshot.snapshot.providerQuota)
        assertFails { AndroidWidgetCodec.decode(bytes.copyOf(bytes.size - 1)) }
        // v2 少写每项末尾的月窗口标志；单项快照去掉最后一个字节即为 v2 布局。
        val v2 = bytes.copyOf(bytes.size - 1).also { it[3] = 0x32 }
        assertEquals(quota, AndroidWidgetCodec.decode(v2).snapshot.snapshot.providerQuota)
    }
    @Test fun quota_roundtrip_keeps_claude_and_cursor_monthly() {
        val quota = ProviderQuotaSnapshot(123, listOf(
            ProviderQuotaEntry("codex", null, null, ProviderQuotaWindow("weekly", 10, null)),
            ProviderQuotaEntry("claude", null, ProviderQuotaWindow("fiveHour", 300, 1900000000), ProviderQuotaWindow("weekly", 50, null)),
            ProviderQuotaEntry("cursor", "pro", null, null, ProviderQuotaWindow("monthly", 1000, 1900000000)),
            ProviderQuotaEntry("grok", null, null, ProviderQuotaWindow("weekly", 0, null))))
        val snapshot = TerminalSnapshot(1, null, null, false, emptyList(), emptyList(), null, quota)
        val record = AndroidWidgetSnapshot.fromLive("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 1_000, snapshot)
        val bytes = AndroidWidgetCodec.encode(AndroidWidgetCodec.State(record, null))
        assertEquals(quota, AndroidWidgetCodec.decode(bytes).snapshot.snapshot.providerQuota)
    }
}
