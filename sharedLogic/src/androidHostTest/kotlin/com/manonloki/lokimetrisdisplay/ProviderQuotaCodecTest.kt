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
        val legacy = current.copyOf(current.size - 2)
        legacy[3] = 0x31
        assertNull(AndroidWidgetCodec.decode(legacy).snapshot.snapshot.providerQuota)
        assertFails { AndroidWidgetCodec.decode(bytes.copyOf(bytes.size - 1)) }
        // v3没有名单标志，v2再少写每项末尾的月窗口标志。
        val v3 = bytes.copyOf(bytes.size - 1).also { it[3] = 0x33 }
        assertNull(AndroidWidgetCodec.decode(v3).snapshot.snapshot.enabledAgents)
        assertEquals(quota, AndroidWidgetCodec.decode(v3).snapshot.snapshot.providerQuota)
        val v2 = v3.copyOf(v3.size - 1).also { it[3] = 0x32 }
        assertEquals(quota, AndroidWidgetCodec.decode(v2).snapshot.snapshot.providerQuota)
        assertNull(AndroidWidgetCodec.decode(v2).snapshot.snapshot.enabledAgents)
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

    @Test fun enabled_agent_cache_distinguishes_legacy_unknown_disabled_and_selected_after_restart() {
        val quota = ProviderQuotaSnapshot(123, listOf(
            ProviderQuotaEntry("codex", null, null, ProviderQuotaWindow("weekly", 10, null)),
            ProviderQuotaEntry("claude", null, null, ProviderQuotaWindow("weekly", 20, null)),
            ProviderQuotaEntry("cursor", null, null, null, ProviderQuotaWindow("monthly", 30, null))))
        for (enabled in listOf(null, emptyList(), listOf("codex", "cursor"))) {
            val snapshot = TerminalSnapshot(1, null, null, false, emptyList(), emptyList(), null, quota, enabled)
            val record = AndroidWidgetSnapshot.fromLive("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 1_000, snapshot)
            val encoded = AndroidWidgetCodec.encode(AndroidWidgetCodec.State(record, null))
            assertEquals(0x34, encoded[3].toInt())
            val restored = AndroidWidgetCodec.decode(encoded).snapshot.snapshot
            assertEquals(enabled, restored.enabledAgents)
            assertEquals(quota, restored.providerQuota)
            assertEquals(when (enabled) {
                null -> listOf("codex", "claude", "cursor")
                emptyList<String>() -> emptyList()
                else -> listOf("codex", "cursor")
            }, restored.displayProviderQuota?.providers?.map { it.provider })
            assertEquals(snapshot.displayUsageRows, restored.displayUsageRows)
        }
    }
}
