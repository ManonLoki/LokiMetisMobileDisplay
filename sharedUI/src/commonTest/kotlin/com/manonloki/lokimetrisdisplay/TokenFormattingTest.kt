package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals

class TokenFormattingTest {
    @Test
    fun compactUnitsRoundHalfUpAndPromoteAtBoundaries() {
        mapOf(
            "0" to "0", "999" to "999", "1000" to "1K", "1005" to "1.01K",
            "1010" to "1.01K", "1100" to "1.1K", "999994" to "999.99K",
            "999995" to "1M", "1000000" to "1M", "221193571" to "221.19M",
            "999999999" to "1B", "1000000000" to "1B", "1000000000000" to "1000B",
        ).forEach { (input, expected) -> assertEquals(expected, compactTokenAmount(input), input) }
    }

    @Test
    fun unsignedMaximumRemainsExactAndUsesBAsLargestUnit() {
        val maximum = "18446744073709551615"
        assertEquals("18446744073.71B", compactTokenAmount(maximum))
        assertEquals("18,446,744,073,709,551,615", exactTokenAmount(maximum))
        assertEquals("221,193,571", exactTokenAmount("221193571"))
        assertEquals("0", exactTokenAmount("0"))
    }

    @Test
    fun missingAndUnavailableValuesAreNeverTurnedIntoZero() {
        listOf("无记录", "不可用", "—", "", "18446744073709551616").forEach {
            assertEquals(it, compactTokenAmount(it))
        }
        listOf("无记录", "不可用", "—", "").forEach { assertEquals(it, exactTokenAmount(it)) }
    }
}
