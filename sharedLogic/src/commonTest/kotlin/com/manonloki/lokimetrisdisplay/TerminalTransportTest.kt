package com.manonloki.lokimetrisdisplay

import kotlin.test.*

/** 验证半帧累积、阶段切换和自动连接的纯策略；不建立真实 socket 或执行密码握手。 */
class TerminalTransportTest {
    /** 四字节头与正文跨read累积，完整后恰好一次交付。 */
    @Test fun split_frame_delivers_once() {
        val frames = TerminalFrames(); val received = mutableListOf<String>()
        frames.append(byteArrayOf(0, 0), { 4096 }) { received += it.decodeToString() }
        frames.append(byteArrayOf(0, 3, 97), { 4096 }) { received += it.decodeToString() }
        assertTrue(received.isEmpty())
        frames.append(byteArrayOf(98, 99), { 4096 }) { received += it.decodeToString() }
        assertEquals(listOf("abc"), received)
    }
    /** 超大头在没有正文时立即拒绝，避免分配无界帧。 */
    @Test fun oversized_header_fails_without_body() {
        assertFailsWith<IllegalArgumentException> { TerminalFrames().append(byteArrayOf(0, 1, 0, 0), { 4096 }) {} }
        assertFailsWith<IllegalArgumentException> { TerminalFrames().append(byteArrayOf(-1, -1, -1, -1), { 98304 }) {} }
    }
    /** 同一网络包内回调切换阶段，下一帧使用新阶段上限。 */
    @Test fun stage_limit_is_rechecked_after_each_delivery() {
        var limit = 4096; var count = 0
        val input = byteArrayOf(0,0,0,1,1,0,0,0,2,2,2)
        assertFailsWith<IllegalArgumentException> { TerminalFrames().append(input, { limit }) { count++; limit = 1 } }
        assertEquals(1, count)
    }
    /** 初装自动发现候选，但首次配对必须通过用户选择开始。 */
    @Test fun first_foreground_discovers_without_starting_pairing() {
        val policy = TerminalConnectionPolicy()
        assertFalse(policy.requested); policy.enterForeground(); assertTrue(policy.requested)
        assertNull(policy.automaticSelection(null, emptySet(), listOf("new-desktop")))
    }
    /** 宿主撤销连接资格后，错误重试也不能重开；恢复资格后可自动选择已有信任。 */
    @Test fun background_pauses_and_foreground_resumes_paired_connection() {
        val policy = TerminalConnectionPolicy(); policy.enterForeground()
        assertEquals("trusted", policy.automaticSelection(null, setOf("trusted"), listOf("new", "trusted")))
        policy.leaveForeground(); policy.discover()
        assertFalse(policy.requested); assertNull(policy.nextDelayMs())
        assertNull(policy.automaticSelection("trusted", setOf("trusted"), listOf("trusted")))
        policy.enterForeground()
        assertEquals("trusted", policy.automaticSelection("trusted", setOf("trusted"), listOf("trusted")))
    }
    /** 初次配对被后台关闭后，恢复发现不能自动重新开码或切到另一桌面。 */
    @Test fun foreground_does_not_reopen_unpaired_selection() {
        val policy = TerminalConnectionPolicy(); policy.enterForeground()
        policy.leaveForeground(); policy.enterForeground()
        assertNull(policy.automaticSelection("new", setOf("trusted"), listOf("new", "trusted")))
        assertNull(policy.automaticSelection("trusted", setOf("trusted"), listOf("new")))
    }
    /** 同一端点最多八次，真实新端点或前台恢复才续预算。 */
    @Test fun retries_are_bounded_and_renewable() {
        val policy = TerminalConnectionPolicy(); policy.enterForeground()
        assertEquals(listOf(500L,1000L,2000L,4000L,8000L,8000L,8000L,8000L), List(8) { policy.nextDelayMs() })
        assertNull(policy.nextDelayMs())
        assertNull(policy.automaticSelection("trusted", setOf("trusted"), listOf("trusted")))
        policy.renewedEndpoint(); assertEquals(500L, policy.nextDelayMs())
        policy.leaveForeground(); policy.renewedEndpoint(); assertNull(policy.nextDelayMs())
        policy.enterForeground(); assertEquals(500L, policy.nextDelayMs())
    }
    /** 已认证快照成功后恢复传输预算，不允许成功事件在后台自行打开连接。 */
    @Test fun authenticated_snapshot_resets_budget_without_changing_foreground_intent() {
        val policy = TerminalConnectionPolicy(); policy.enterForeground()
        repeat(8) { policy.nextDelayMs() }
        policy.connected()
        assertEquals(0, policy.attempts)
        assertEquals(500L, policy.nextDelayMs())
        policy.leaveForeground(); policy.connected()
        assertFalse(policy.requested)
        assertNull(policy.nextDelayMs())
    }
    /** u64最大值无损，溢出、前导零和缺失值不能伪装可用统计。 */
    @Test fun token_numbers_preserve_unsigned_precision() {
        TerminalAmount("18446744073709551615", "available", "partial", "derived").validate()
        listOf("18446744073709551616", "01", "-1", "1.0").forEach { value ->
            assertFailsWith<IllegalArgumentException> { TerminalAmount(value, "available", "complete", "exact").validate() }
        }
        assertFailsWith<IllegalArgumentException> { TerminalAmount("0", "unavailable", "unknown", "exact").validate() }
    }
    /** 重复槽位和Hook不可用时残留内容不能被完整快照接受。 */
    @Test fun snapshot_rejects_duplicate_or_unavailable_hooks() {
        val hook = TerminalHook("codex", 1, "running", "正文", false, null)
        val snapshot = TerminalSnapshot(1,null,null,true,listOf(hook),emptyList(),null)
        snapshot.validate()
        assertFailsWith<IllegalArgumentException> { snapshot.copy(hooks = listOf(hook,hook)).validate() }
        assertFailsWith<IllegalArgumentException> { snapshot.copy(hooksAvailable = false).validate() }
    }
    /** 观测必须落在桌面日界内，重复Agent不能混入分量。 */
    @Test fun tokens_require_matching_day_and_unique_agents() {
        val amount = TerminalAmount("0","available","complete","exact")
        val agent = TerminalAgent("codex", amount)
        val tokens = TerminalTokens(TerminalDay("2026-10-21","Asia/Shanghai",1,10),9,amount,listOf(agent))
        tokens.validate()
        assertFailsWith<IllegalArgumentException> { tokens.copy(observedMs = 10).validate() }
        assertFailsWith<IllegalArgumentException> { tokens.copy(agents = listOf(agent,agent)).validate() }
    }
    /** 系统提交失败后即使其内部内存已改变，也不能让load或clientIds看到未提交信任。 */
    @Test fun failed_store_and_forget_preserve_committed_records() {
        val records = CommittedRecords(mapOf("old" to "secret-old"))
        var system = records.snapshot()
        assertFalse(records.update("new", "secret-new") { system = it; false })
        assertEquals(mapOf("old" to "secret-old"), records.snapshot())
        assertTrue("new" in system)
        assertFalse(records.update("old", null) { system = it; false })
        assertEquals("secret-old", records.snapshot()["old"])
        assertTrue(records.update("third", "secret-third") { system = it; true })
        assertEquals(mapOf("old" to "secret-old", "third" to "secret-third"), system)
        assertEquals(system, records.snapshot())
    }

    /** 数万层嵌套在平台递归解析前拒绝，括号出现在字符串内不会被误计深度。 */
    @Test fun json_depth_is_bounded_before_platform_parser() {
        val deep = "{\"x\":" + "[".repeat(10000) + "0" + "]".repeat(10000) + "}"
        assertFailsWith<IllegalArgumentException> { TerminalJsonBoundary.validateObject(deep) }
        TerminalJsonBoundary.validateObject("{\"x\":\"[[{\\\"quoted\\\"}]]\",\"v\":[true,false,null,-1.25e+2]}")
    }
    /** 系统JSONTokener的单引号、注释、非引号键或尾随正文扩展不能进入线协议。 */
    @Test fun json_rejects_platform_extensions_and_trailing_data() {
        listOf("{'x':1}", "{x:1}", "{/*c*/\"x\":1}", "{}[]", "{\"x\":01}", "{\"x\":1,}", "{\"x\":NaN}").forEach { value ->
            assertFails { TerminalJsonBoundary.validateObject(value) }
        }
        TerminalJsonBoundary.validateObject(" \r\n{\"amount\":18446744073709551615}\t")
    }

    /** 最新重试或选择覆盖旧操作，只消费一次。 */
    @Test fun latest_user_operation_is_delivered_once() {
        val pending = TerminalPendingIntent()
        pending.submit(TerminalUserIntent.Select("desktop")); pending.submit(TerminalUserIntent.Discover)
        assertEquals(TerminalUserIntent.Discover, pending.take()); assertNull(pending.take())
        pending.submit(TerminalUserIntent.Discover); pending.submit(TerminalUserIntent.Select("desktop"))
        assertEquals(TerminalUserIntent.Select("desktop"), pending.take())
    }
    /** 忘记必须取消该桌面尚未执行的选择，同时不能撤销另一桌面的选择。 */
    @Test fun forget_cancels_only_matching_pending_selection() {
        val pending = TerminalPendingIntent(); pending.submit(TerminalUserIntent.Select("first"))
        pending.forget("second"); assertEquals(TerminalUserIntent.Select("first"), pending.take())
        pending.submit(TerminalUserIntent.Select("first")); pending.forget("first")
        assertNull(pending.take())
    }

    /** 失效后不保留Token、Hooks或接收时间，同时不改变身份和配对选择。 */
    @Test fun disconnected_display_drops_live_data_without_forgetting_pairing() {
        val host = TerminalHost("desktop", "Desktop", paired = true, available = true)
        val snapshot = TerminalSnapshot(1, null, null, true,
            listOf(TerminalHook("codex", 1, "idle", "old status", false, null)), emptyList(), null)
        val live = TerminalLinkView("phone", "Phone", hosts = listOf(host), selectedId = host.id,
            connected = true, snapshot = snapshot, receivedAtMs = 123, assetWarning = "old warning")
        val cleared = live.withoutLiveDisplay()
        assertFalse(cleared.connected); assertNull(cleared.snapshot); assertNull(cleared.receivedAtMs); assertNull(cleared.assetWarning)
        assertEquals(live.deviceId, cleared.deviceId); assertEquals(live.selectedId, cleared.selectedId); assertEquals(live.hosts, cleared.hosts)
        assertEquals(cleared, cleared.withoutLiveDisplay())
    }

}
