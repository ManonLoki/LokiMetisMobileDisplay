package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 用纯元信息验证历史图片、身份更换和清图墓碑，不依赖平台文件或解码器。 */
class HookImageCachePolicyTest {
    private val image = "a".repeat(64)
    private fun fact(slot: Int = 1, agent: String = "codex", hash: String? = null,
                     received: Long = -1, cleared: Long = -1, content: Boolean = false) =
        HookImageFact(slot, agent, hash, received, cleared, content)
    private fun state(at: Long = 1000, summary: Boolean = false, available: Boolean = true,
                      facts: List<HookImageFact> = listOf(fact(hash = image, content = true)),
                      phone: String = "phone", source: String = "desktop") =
        HookImageCacheState(phone, source, at, summary, available, facts)

    @Test fun historyMergeRequiresSameIdentityOrderedTimeAndSummaryContent() {
        val summary = state(3000, true, facts = listOf(fact()))
        assertTrue(HookImageCachePolicy.mayMergeHistory(summary, state()))
        assertFalse(HookImageCachePolicy.mayMergeHistory(summary, null))
        assertFalse(HookImageCachePolicy.mayMergeHistory(summary, state(phone = "other")))
        assertFalse(HookImageCachePolicy.mayMergeHistory(summary, state(source = "other")))
        assertFalse(HookImageCachePolicy.mayMergeHistory(summary, state(at = 4000)))
        assertFalse(HookImageCachePolicy.mayMergeHistory(state(3000), state()))
        assertFalse(HookImageCachePolicy.mayMergeHistory(state(3000, true,
            facts = listOf(fact(hash = image))), state()))
    }

    @Test fun reusedImageRetainsOriginalReceiptAndRequiresItsDescriptor() {
        val incoming = fact()
        val decision = HookImageCachePolicy.decide(incoming, state(), setOf(image))
        assertEquals(HookImageChoice.USE_PREVIOUS, decision.choice)
        assertEquals(fact(hash = image, received = 1000), decision.fact)
        assertEquals(HookImageChoice.KEEP_CURRENT,
            HookImageCachePolicy.decide(incoming, state(), emptySet()).choice)
        val cached = state(3000, true, facts = listOf(fact(hash = image, received = 1000)))
        assertEquals(1000L, HookImageCachePolicy.decide(incoming, cached, setOf(image)).fact.receivedAtMs)
    }

    @Test fun completeClearingAndEqualTimeTombstonesPreventOldImageResurrection() {
        val imageAt1000 = fact(hash = image, received = 1000)
        val cleared = state(2000, false, facts = listOf(fact()))
        assertEquals(fact(cleared = 2000),
            HookImageCachePolicy.decide(imageAt1000, cleared, emptySet()).fact)
        val equal = state(3000, true, facts = listOf(fact(cleared = 1000)))
        assertEquals(fact(cleared = 1000),
            HookImageCachePolicy.decide(imageAt1000, equal, emptySet()).fact)
        assertEquals(HookImageChoice.KEEP_CURRENT,
            HookImageCachePolicy.decide(fact(cleared = 1000),
                state(3000, true, facts = listOf(imageAt1000)), setOf(image)).choice)
        assertEquals(HookImageChoice.KEEP_CURRENT,
            HookImageCachePolicy.decide(fact(hash = image, received = 2001), cleared, emptySet()).choice)
    }

    @Test fun emptySlotAndAgentChangesUseEarlierIdentityCutoffRatherThanNewSummaryTime() {
        val summary = fact(agent = "cursor")
        for (old in listOf(state(facts = emptyList()), state())) {
            val tombstone = HookImageCachePolicy.decide(summary, old, setOf(image))
            assertEquals(HookImageChoice.CLEAR, tombstone.choice)
            assertEquals(1000L, tombstone.fact.clearedAtMs)
            val delayedImage = state(2000, facts = listOf(fact(agent = "cursor", hash = image)))
            val replaced = HookImageCachePolicy.decide(tombstone.fact, delayedImage, setOf(image))
            assertEquals(HookImageChoice.USE_PREVIOUS, replaced.choice)
            assertEquals(2000L, replaced.fact.receivedAtMs)
            assertEquals(HookImageChoice.KEEP_CURRENT,
                HookImageCachePolicy.decide(replaced.fact, old, setOf(image)).choice)
        }
        assertEquals(HookImageChoice.KEEP_CURRENT,
            HookImageCachePolicy.decide(summary, state(available = false, facts = emptyList()), emptySet()).choice)
    }

    @Test fun sameTimeMixedRecordsCannotLoseMarkersOrReplaceClearWithEqualImage() {
        val old = state(5000, true, facts = listOf(fact(cleared = 3000)))
        val olderImage = state(5000, true, facts = listOf(fact(hash = image, received = 1000)))
        val equalImage = state(5000, true, facts = listOf(fact(hash = image, received = 3000)))
        val newerImage = state(5000, true, facts = listOf(fact(hash = image, received = 4000)))
        assertFalse(HookImageCachePolicy.supersedes(olderImage, old))
        assertFalse(HookImageCachePolicy.supersedes(equalImage, old))
        assertTrue(HookImageCachePolicy.supersedes(old, equalImage))
        assertTrue(HookImageCachePolicy.supersedes(newerImage, old))
        val anotherSlot = fact(slot = 2, hash = image, received = 4000)
        assertFalse(HookImageCachePolicy.supersedes(state(5000, true, facts = listOf(anotherSlot)), old))
        assertFalse(HookImageCachePolicy.supersedes(state(5000, true, facts = listOf(fact(), anotherSlot)), old))
        assertFalse(HookImageCachePolicy.supersedes(state(5000, true,
            facts = listOf(fact(agent = "cursor", cleared = 3000), anotherSlot)), old))
        assertTrue(HookImageCachePolicy.supersedes(state(5000, true,
            facts = listOf(fact(cleared = 3000), anotherSlot)), old))
    }

    @Test fun snapshotTimePrecedesCompletenessAndDifferentSourcesStartFresh() {
        val full = state()
        val summary = state(summary = true, facts = emptyList())
        val mixed = state(summary = true, facts = listOf(fact(cleared = 1000)))
        assertEquals(2, HookImageCachePolicy.priority(false, full.facts))
        assertEquals(1, HookImageCachePolicy.priority(true, mixed.facts))
        assertEquals(1, HookImageCachePolicy.priority(false, mixed.facts))
        assertEquals(0, HookImageCachePolicy.priority(true, summary.facts))
        assertFalse(HookImageCachePolicy.supersedes(summary, full))
        assertTrue(HookImageCachePolicy.supersedes(full, summary))
        assertTrue(HookImageCachePolicy.supersedes(summary.copy(receivedAtMs = 1001), full))
        assertFalse(HookImageCachePolicy.supersedes(full, summary.copy(receivedAtMs = 1001)))
        assertTrue(HookImageCachePolicy.supersedes(summary.copy(phoneId = "other"), full))
        assertTrue(HookImageCachePolicy.supersedes(summary.copy(sourceId = "other"), full))
    }

    @Test fun canonicalUnicodeAgentIdentityPreservesHistoricalImagesAndClearMarkersWithoutFoldingAliases() {
        val composed = "Caf\u00e9"
        val decomposed = "Cafe\u0301"
        val incoming = fact(agent = decomposed)
        val old = state(facts = listOf(fact(agent = composed, hash = image)))
        val decision = HookImageCachePolicy.decide(incoming, old, setOf(image))
        assertEquals(HookImageChoice.USE_PREVIOUS, decision.choice)
        assertEquals(fact(agent = decomposed, hash = image, received = 1000), decision.fact)
        val cleared = fact(agent = composed, cleared = 1000)
        assertTrue(HookImageCachePolicy.preservesHistory(listOf(cleared.copy(agent = decomposed)), listOf(cleared)))
        assertFalse(HookImageCachePolicy.preservesHistory(
            listOf(fact(agent = decomposed, hash = image, received = 1000)), listOf(cleared)))
        assertEquals(HookImageChoice.CLEAR,
            HookImageCachePolicy.decide(fact(agent = "CAF\u00c9"), old, setOf(image)).choice)
        assertEquals(HookImageChoice.CLEAR,
            HookImageCachePolicy.decide(fact(agent = "work-buddy"),
                state(facts = listOf(fact(agent = "workbuddy", hash = image))), setOf(image)).choice)
    }
}
