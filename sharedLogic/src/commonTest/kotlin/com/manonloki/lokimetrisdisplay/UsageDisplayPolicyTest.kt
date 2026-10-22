package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 原生宿主消费相同的原始索引，避免过滤后索引变化或各端自行合并产生不同结果。 */
class UsageDisplayPolicyTest {
    @Test fun referencesKeepOriginalPositionsAfterFilteringMatchingAndStableOrdering() {
        val names = listOf("Work_Buddy", "Custom A", "Grok Build", "Claude-Code", "codex", "Custom B")
        val providers = listOf("codex", "claude", "cursor", "grok")
        val rows = UsageDisplayPolicy.projectRows(true, names, providers,
            listOf("codex", "claudeCode", "cursor", "grok", "customa", "customb"))
        assertEquals(listOf(UsageRowReference(4, 0), UsageRowReference(3, 1), UsageRowReference(-1, 2),
            UsageRowReference(2, 3), UsageRowReference(1, -1), UsageRowReference(5, -1)), rows)
        assertEquals(listOf(1, 2, 3, 4, 5), UsageDisplayPolicy.visibleIndices(names,
            listOf("codex", "claude", "grok", "customa", "customb")))
        assertEquals("Work_Buddy", names.first())
    }

    @Test fun absentEmptyAndExplicitCursorKeepDifferentProjectionSemantics() {
        assertTrue(UsageDisplayPolicy.projectRows(false, emptyList(), emptyList(), null).isEmpty())
        assertTrue(UsageDisplayPolicy.projectRows(true, listOf("codex"), listOf("cursor"), emptyList()).isEmpty())
        assertEquals(listOf(UsageRowReference(-1, -1)),
            UsageDisplayPolicy.projectRows(false, emptyList(), emptyList(), listOf("CUR-SOR")))
        assertEquals(listOf(UsageRowReference(-1, 0)),
            UsageDisplayPolicy.projectRows(false, emptyList(), listOf("cursor"), listOf("cursor")))
    }

    @Test fun aliasesUseOneIdentityForNamesEnablementAndProviderMatching() {
        val aliases = listOf("claudeCode", "Claude Code", "claude-code", "CLAUDE")
        aliases.forEach {
            assertEquals("Claude Code", UsageDisplayPolicy.agentDisplayName(it))
            assertEquals("claude", UsageDisplayPolicy.providerQuotaKey(it))
            assertTrue(UsageDisplayPolicy.isEnabled(it, listOf("claudeCode")))
        }
        assertFalse(UsageDisplayPolicy.validEnabledAgents(listOf("claudeCode", "Claude Code")))
        assertFalse(UsageDisplayPolicy.validEnabledAgents(listOf("--_")))
        assertFalse(UsageDisplayPolicy.validEnabledAgents(listOf("界".repeat(22))))
        assertTrue(UsageDisplayPolicy.validEnabledAgents(listOf("界".repeat(21))))
        assertEquals("Custom Name", UsageDisplayPolicy.agentDisplayName("Custom Name"))
    }

    @Test fun canonicalUnicodeNamesMatchEnablementAndRejectEquivalentDuplicatesWithoutChangingSourceText() {
        val composed = "Caf\u00e9"
        val decomposed = "Cafe\u0301"
        assertTrue(UsageDisplayPolicy.isEnabled(composed, listOf(decomposed)))
        assertTrue(UsageDisplayPolicy.isEnabled(decomposed, listOf(composed)))
        assertFalse(UsageDisplayPolicy.validEnabledAgents(listOf(composed, decomposed)))
        assertEquals(listOf(0), UsageDisplayPolicy.visibleIndices(listOf(decomposed, "Other"), listOf(composed)))
        assertEquals(listOf(UsageRowReference(0, -1)),
            UsageDisplayPolicy.projectRows(true, listOf(decomposed), emptyList(), listOf(composed)))
        assertEquals(decomposed, UsageDisplayPolicy.agentDisplayName(decomposed))
    }

    @Test fun defaultZeroDoesNotChangeMissingValuesForOtherProviders() {
        assertEquals("0", UsageDisplayPolicy.tokenText("cursor", "无记录", false))
        assertEquals("123", UsageDisplayPolicy.tokenText("cursor", "123", true))
        assertEquals("无记录", UsageDisplayPolicy.tokenText("codex", "无记录", false))
        assertEquals(null, UsageDisplayPolicy.tokenText("claude", null, false))
        assertEquals("部分·估算", UsageDisplayPolicy.amountQuality("partial", "derived", "·"))
        assertEquals("部分 · 估算", UsageDisplayPolicy.amountQuality("partial", "derived", " · "))
        assertEquals(listOf("空闲", "运行", "询问", "出错"),
            listOf("idle", "running", "asking", "error").map(UsageDisplayPolicy::hookLabel))
    }

    @Test fun foreignLanguageValidationReturnsFalseForCorruptModelsAndIntegerBoundaries() {
        assertFalse(TerminalAmount("18446744073709551616", "available", "complete", "exact").isValid())
        assertFalse(TerminalAmount("1", "unavailable", "complete", "exact").isValid())
        assertFails { TerminalHook("codex", Int.MAX_VALUE, "idle", "", false, null).validate() }
        assertFalse(TerminalAsset("a".repeat(64), "image/png", Long.MAX_VALUE).isValid())
        assertFalse(ProviderQuotaWindow("weekly", Int.MAX_VALUE, null).isValid("weekly"))
        assertFalse(ProviderQuotaWindow("weekly", 0, -1).isValid("weekly"))
        assertFalse(ProviderQuotaEntry("codex", "private@example.com", null,
            ProviderQuotaWindow("weekly", 0, null)).isValid())
        assertFalse(ProviderQuotaSnapshot(0, listOf(
            ProviderQuotaEntry("unknown", null, null, ProviderQuotaWindow("weekly", 0, null)))).isValid())
        assertTrue(ProviderQuotaWindow("weekly", 1000, null).isValid("weekly"))
    }
}
