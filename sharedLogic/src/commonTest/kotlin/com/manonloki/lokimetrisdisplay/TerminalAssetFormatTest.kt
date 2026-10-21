package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertFailsWith

/** 展示资源五格式与32MiB边界在Android和iOS清单入口保持一致。 */
class TerminalAssetFormatTest {
    @Test fun supported_mime_types_preserve_existing_size_and_hash_boundaries() {
        val hash = "a".repeat(64)
        listOf("image/bmp", "image/png", "image/jpeg", "image/webp", "image/gif").forEach { mime ->
            TerminalAsset(hash, mime, 1).validate()
            TerminalAsset(hash, mime, 33_554_432).validate()
            assertFailsWith<IllegalArgumentException> { TerminalAsset(hash, mime, 0).validate() }
            assertFailsWith<IllegalArgumentException> { TerminalAsset(hash, mime, 33_554_433).validate() }
            assertFailsWith<IllegalArgumentException> { TerminalAsset("../image", mime, 1).validate() }
        }
        assertFailsWith<IllegalArgumentException> { TerminalAsset(hash, "image/svg+xml", 1).validate() }
        assertFailsWith<IllegalArgumentException> { TerminalAsset(hash, "image/wep", 1).validate() }
    }
}
