package com.manonloki.lokimetrisdisplay

import kotlin.test.*

/** 面板排序同时覆盖Token与独立额度，保持统计值和线协议次序不变。 */
class TerminalUsageDisplayTest {
    private val amount = TerminalAmount("12345", "available", "complete", "exact")
    private fun tokens(vararg names: String) = TerminalTokens(
        TerminalDay("2026-10-22", "Asia/Shanghai", 1, 10), 9, amount,
        names.map { TerminalAgent(it, amount) },
    )
    private fun quota(provider: String) = ProviderQuotaEntry(
        provider, null, null,
        if (provider == "cursor") null else ProviderQuotaWindow("weekly", 250, null),
        if (provider == "cursor") ProviderQuotaWindow("monthly", 500, null) else null,
    )
    private fun snapshot(tokens: TerminalTokens?, vararg providers: String) = TerminalSnapshot(
        1, tokens, null, false, emptyList(), emptyList(), null,
        ProviderQuotaSnapshot(123, providers.map(::quota)),
    )

    @Test fun display_agents_prioritize_cursor_and_keep_other_agents_stable() {
        val tokens = tokens("Work_Buddy", "Hermes", "Grok Build", "OpenCode", "Cursor", "Claude-Code", "codex")
        val original = tokens.agents.toList()

        assertEquals(listOf("codex", "Claude-Code", "Cursor", "Grok Build", "Hermes", "OpenCode", "Work_Buddy"),
            tokens.displayAgents.map { it.agent })
        assertEquals(original, tokens.agents)
        assertSame(amount, tokens.all)
        tokens.displayAgents.forEach { assertSame(amount, it.amount) }
    }

    @Test fun cursor_with_quota_only_appears_before_grok_and_workbuddy_without_fabricating_tokens() {
        val snapshot = snapshot(tokens("WorkBuddy", "Hermes", "grok", "OpenCode", "Claude Code", "codex"),
            "codex", "claude", "cursor", "grok")
        snapshot.validate()

        val rows = snapshot.displayUsageRows
        assertEquals(listOf("Codex", "Claude Code", "Cursor", "Grok", "Hermes", "OpenCode", "WorkBuddy"),
            rows.map { it.displayName })
        val cursor = rows[2]
        assertNull(cursor.tokenAgent)
        assertEquals("0", cursor.tokenText)
        assertEquals("50%", cursor.quota?.monthly?.percentText)
        assertEquals(6, snapshot.tokens?.agents?.size)
        assertNull(snapshot.tokens?.agents?.firstOrNull { it.agent == "cursor" })
        assertEquals("12345", rows.last().tokenAgent?.amount?.total)
    }

    @Test fun matching_quota_stays_with_its_token_row_and_missing_cursor_displays_zero() {
        val snapshot = snapshot(tokens("WorkBuddy", "Claude-Code", "codex"), "claude")
        snapshot.validate()

        val rows = snapshot.displayUsageRows
        assertEquals(listOf("Codex", "Claude Code", "Cursor", "WorkBuddy"), rows.map { it.displayName })
        assertSame(snapshot.providerQuota?.providers?.single(), rows[1].quota)
        assertSame(snapshot.tokens?.agents?.get(1), rows[1].tokenAgent)
        assertEquals(1, rows.count { it.quota != null })
        assertNull(rows[2].tokenAgent)
        assertNull(rows[2].quota)
        assertEquals("0", rows[2].tokenText)
        assertEquals(listOf("WorkBuddy", "Claude-Code", "codex"), snapshot.tokens?.agents?.map { it.agent })
        assertSame(amount, snapshot.tokens?.all)
    }

    @Test fun quota_rows_survive_when_no_token_snapshot_is_available() {
        val snapshot = snapshot(null, "codex", "claude", "cursor", "grok")
        snapshot.validate()

        assertEquals(listOf("Codex", "Claude", "Cursor", "Grok"), snapshot.displayUsageRows.map { it.displayName })
        assertTrue(snapshot.displayUsageRows.all { it.tokenAgent == null && it.quota != null })
        assertNull(snapshot.tokens)
    }

    @Test fun cursor_missing_amount_displays_zero_without_changing_source_availability() {
        for (availability in listOf("noRecords", "unavailable")) {
            val amount = TerminalAmount(null, availability, "unknown", "exact")
            val row = TerminalUsageRow(TerminalAgent("Cursor", amount), null)
            assertEquals("0", row.tokenText)
            assertSame(amount, row.tokenAgent?.amount)
            assertNull(row.tokenAgent?.amount?.total)
            assertEquals(availability, row.tokenAgent?.amount?.availability)
        }
    }

    @Test fun cursor_real_zero_and_usage_are_retained_without_duplicate_fallback() {
        for (total in listOf("0", "12345")) {
            val amount = TerminalAmount(total, "available", "complete", "exact")
            val tokens = tokens("CUR-SOR", "workbuddy").copy(agents = listOf(TerminalAgent("CUR-SOR", amount)))
            val rows = snapshot(tokens).displayUsageRows
            assertEquals(1, rows.size)
            assertEquals(total, rows.single().tokenText)
        }
    }

    @Test fun missing_tokens_do_not_add_default_cursor_to_unsynced_snapshot() {
        assertTrue(snapshot(null).displayUsageRows.isEmpty())
    }

    @Test fun enabled_codex_and_cursor_filter_details_and_quota_without_recomputing_totals() {
        val original = snapshot(tokens("WorkBuddy", "Claude Code", "codex", "grok"), "codex", "claude", "cursor", "grok")
        val selected = original.copy(enabledAgents = listOf("codex", "cursor"))
        selected.validate()

        assertEquals(listOf("codex"), selected.displayTokens?.agents?.map { it.agent })
        assertEquals(listOf("codex", "cursor"), selected.displayProviderQuota?.providers?.map { it.provider })
        assertEquals(listOf("Codex", "Cursor"), selected.displayUsageRows.map { it.displayName })
        assertEquals("0", selected.displayUsageRows.last().tokenText)
        assertSame(original.tokens, selected.tokens)
        assertSame(original.providerQuota, selected.providerQuota)
        assertSame(original.tokens?.all, selected.displayTokens?.all)
        assertEquals(original.tokens?.all?.quality, selected.displayTokens?.all?.quality)
    }

    @Test fun disabled_cursor_does_not_return_as_a_default_row_and_empty_list_hides_all_agents() {
        val original = snapshot(tokens("codex", "claudeCode", "cursor"), "codex", "claude", "cursor")
        val codex = original.copy(enabledAgents = listOf("codex"))
        assertEquals(listOf("Codex"), codex.displayUsageRows.map { it.displayName })
        assertEquals(listOf("codex"), codex.displayProviderQuota?.providers?.map { it.provider })

        val disabled = original.copy(enabledAgents = emptyList())
        disabled.validate()
        assertTrue(disabled.displayUsageRows.isEmpty())
        assertTrue(disabled.displayTokens?.agents.orEmpty().isEmpty())
        assertTrue(disabled.displayProviderQuota?.providers.orEmpty().isEmpty())
        assertSame(original.tokens?.all, disabled.displayTokens?.all)
        assertEquals(3, disabled.tokens?.agents?.size)
        assertEquals(3, disabled.providerQuota?.providers?.size)
    }

    @Test fun explicit_list_filters_quota_without_tokens_and_only_enabled_cursor_gets_zero() {
        val original = snapshot(null, "codex", "claude", "cursor", "grok")
        val selected = original.copy(enabledAgents = listOf("codex", "cursor"))
        assertEquals(listOf("Codex", "Cursor"), selected.displayUsageRows.map { it.displayName })
        assertEquals(listOf("codex", "cursor"), selected.displayProviderQuota?.providers?.map { it.provider })
        assertEquals("0", selected.displayUsageRows.last().tokenText)
        assertTrue(original.copy(enabledAgents = emptyList()).displayUsageRows.isEmpty())

        val cursorOnly = snapshot(null).copy(enabledAgents = listOf("cursor"))
        assertEquals("Cursor", cursorOnly.displayUsageRows.single().displayName)
        assertEquals("0", cursorOnly.displayUsageRows.single().tokenText)
        assertNull(cursorOnly.displayUsageRows.single().tokenAgent)
        assertTrue(snapshot(null).displayUsageRows.isEmpty())
    }

    @Test fun desktop_camel_case_and_historical_agent_aliases_match_the_same_enabled_set() {
        val enabled = listOf("codex", "claudeCode", "cursor", "openCode", "workBuddy", "hermes", "openClaw", "codeBuddy",
            "qwenCode", "kimiCode", "qoder", "geminiCli", "gitHubCopilot", "grok")
        val names = arrayOf("Codex", "Claude-Code", "CUR_SOR", "Open Code", "Work_Buddy", "Hermes", "Open-Claw", "Code Buddy",
            "Qwen Code", "Kimi-Code", "Qoder", "Gemini CLI", "GitHub Copilot CLI", "Grok Build")
        val selected = snapshot(tokens(*names), "codex", "claude", "cursor", "grok").copy(enabledAgents = enabled)
        selected.validate()
        assertEquals(14, selected.displayTokens?.agents?.size)
        assertEquals(14, selected.displayUsageRows.size)
        assertEquals(listOf("codex", "claude", "cursor", "grok"), selected.displayProviderQuota?.providers?.map { it.provider })
        assertEquals("GitHub Copilot", agentDisplayName("gitHubCopilot"))
        assertEquals("claude", providerQuotaKey("claudeCode"))
        assertEquals("grok", providerQuotaKey("grok-build"))
    }

    @Test fun changing_enabled_list_immediately_changes_projection_and_null_keeps_legacy_behavior() {
        val original = snapshot(tokens("codex", "claude-code"), "codex", "claude", "cursor")
        val selected = original.copy(enabledAgents = listOf("claudeCode"))
        assertEquals(listOf("Claude Code"), selected.displayUsageRows.map { it.displayName })
        assertEquals(listOf("Cursor"), selected.copy(enabledAgents = listOf("cursor")).displayUsageRows.map { it.displayName })
        assertEquals(listOf("Codex", "Claude Code", "Cursor"), selected.copy(enabledAgents = null).displayUsageRows.map { it.displayName })
        assertSame(original.tokens, original.displayTokens)
        assertSame(original.providerQuota, original.displayProviderQuota)
    }

    @Test fun enabled_list_rejects_duplicates_alias_duplicates_and_unbounded_utf8_names() {
        val original = snapshot(null)
        original.copy(enabledAgents = listOf("字".repeat(21))).validate()
        for (invalid in listOf(listOf(""), listOf("   "), listOf("--_"), listOf("字".repeat(22)), listOf("codex", "codex"),
                listOf("claudeCode", "Claude-Code"), listOf("grok", "grok-build"), List(15) { "tool$it" })) {
            assertFails { original.copy(enabledAgents = invalid).validate() }
        }
    }
}
