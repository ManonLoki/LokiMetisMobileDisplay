package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.presentation.TokenFormatting
import kotlin.test.Test
import kotlin.test.assertEquals

/** 主面板与小组件的单位上限各自验证，共用整数舍入并保留 u64 最大值精度。 */
class TokenFormattingTest {
    @Test
    fun widgetUsesExtendedUnitsWithoutUnsignedOverflow() {
        mapOf(
            "999995" to "1M", "999995000000" to "1T",
            "999995000000000" to "1P", "999995000000000000" to "1E",
            "1000000000000000000" to "1E", "18446744073709551615" to "18.45E",
            "18446744073709551616" to "18446744073709551616", "不可用" to "不可用",
        ).forEach { (value, expected) -> assertEquals(expected, TokenFormatting.compactForWidget(value), value) }
    }

    @Test
    fun compactUnitsRoundHalfUpAndPromoteAtBoundaries() {
        mapOf(
            "0" to "0", "999" to "999", "1000" to "1K", "1005" to "1.01K",
            "1010" to "1.01K", "1100" to "1.1K", "999994" to "999.99K",
            "999995" to "1M", "1000000" to "1M", "221193571" to "221.19M",
            "999999999" to "1B", "1000000000" to "1B", "1000000000000" to "1000B",
        ).forEach { (input, expected) -> assertEquals(expected, TokenFormatting.compact(input), input) }
    }

    @Test
    fun unsignedMaximumRemainsExactAndUsesBAsLargestUnit() {
        val maximum = "18446744073709551615"
        assertEquals("18446744073.71B", TokenFormatting.compact(maximum))
        assertEquals("18,446,744,073,709,551,615", TokenFormatting.exact(maximum))
        assertEquals("221,193,571", TokenFormatting.exact("221193571"))
        assertEquals("0", TokenFormatting.exact("0"))
    }

    @Test
    fun missingAndUnavailableValuesAreNeverTurnedIntoZero() {
        listOf("无记录", "不可用", "—", "", "18446744073709551616").forEach {
            assertEquals(it, TokenFormatting.compact(it))
        }
        listOf("无记录", "不可用", "—", "").forEach { assertEquals(it, TokenFormatting.exact(it)) }
    }
}
