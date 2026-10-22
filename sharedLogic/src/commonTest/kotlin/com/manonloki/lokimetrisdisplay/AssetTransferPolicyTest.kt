package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AssetTransferPolicyTest {
    private val asset = AssetTransferDescriptor("a".repeat(64), "image/gif", ULong.MAX_VALUE.toString())

    @Test fun inFlightRequiresExactDescriptorAndCurrentReferenceWhileNullKeepsSnapshotJob() {
        val manifest = AssetTransferManifest(listOf(asset), setOf(asset.hash))
        assertTrue(AssetTransferRules.keepInFlight(null, manifest.copy(assets = emptyList(), referencedHashes = emptySet())))
        assertTrue(AssetTransferRules.keepInFlight(asset, manifest))
        assertFalse(AssetTransferRules.keepInFlight(asset, manifest.copy(referencedHashes = emptySet())))
        assertFalse(AssetTransferRules.keepInFlight(asset, manifest.copy(assets = emptyList())))
        for (changed in listOf(asset.copy(hash = "b".repeat(64)), asset.copy(mime = "image/png"),
                asset.copy(byteLength = (ULong.MAX_VALUE - 1UL).toString()))) {
            assertFalse(AssetTransferRules.keepInFlight(asset,
                AssetTransferManifest(listOf(changed), setOf(asset.hash, changed.hash))))
        }
    }

    @Test fun pendingIndicesPreserveManifestOrderAndSkipUnreferencedLoadedAndFailedHashes() {
        val first = asset.copy(hash = "c".repeat(64))
        val loaded = asset.copy(hash = "a".repeat(64))
        val unreferenced = asset.copy(hash = "d".repeat(64))
        val failed = asset.copy(hash = "b".repeat(64))
        val last = asset.copy(hash = "e".repeat(64))
        val manifest = AssetTransferManifest(listOf(first, loaded, unreferenced, failed, last),
            setOf(first.hash, loaded.hash, failed.hash, last.hash))
        assertEquals(listOf(0, 4), AssetTransferRules.pendingIndices(manifest, setOf(loaded.hash, failed.hash)))
        assertEquals(listOf(0, 1, 3, 4), AssetTransferRules.pendingIndices(manifest, emptySet()))
    }

    @Test fun policyDoesNotValidateRewriteOrDeduplicateTheInputManifest() {
        val manifest = AssetTransferManifest(listOf(asset, asset), setOf(asset.hash))
        assertEquals(listOf(0, 1), AssetTransferRules.pendingIndices(manifest, emptySet()))
        assertTrue(AssetTransferRules.pendingIndices(manifest, setOf(asset.hash)).isEmpty())
        assertTrue(AssetTransferRules.pendingIndices(manifest.copy(referencedHashes = emptySet()), emptySet()).isEmpty())
        // 协议入口已经负责格式验证；引用决策不额外解析或截断宿主提供的十进制长度。
        val opaque = asset.copy(byteLength = "opaque")
        assertTrue(AssetTransferRules.keepInFlight(opaque, AssetTransferManifest(listOf(opaque), setOf(opaque.hash))))
    }
}
