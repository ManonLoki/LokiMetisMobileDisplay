package com.manonloki.lokimetrisdisplay

import kotlin.test.*

class TerminalCapabilitiesTest {
    @Test fun absentUnknownAndSupportedCapabilitiesKeepDifferentMeanings() {
        assertFalse(TerminalCapabilities.isValid(null))
        assertTrue(TerminalCapabilities.isValid(emptyList()))
        assertFalse(TerminalCapabilities.supports(listOf("futureExtension"), TerminalCapabilities.DEVICE_FORM_FACTOR))
        assertTrue(TerminalCapabilities.supports(listOf(TerminalCapabilities.DEVICE_FORM_FACTOR), TerminalCapabilities.DEVICE_FORM_FACTOR))
    }
    @Test fun countUtf8AndCanonicalDuplicateChecksAreShared() {
        assertTrue(TerminalCapabilities.isValid(List(16) { "cap$it" }))
        assertFalse(TerminalCapabilities.isValid(List(17) { "cap$it" }))
        assertTrue(TerminalCapabilities.isValid(listOf("长".repeat(21) + "a")))
        assertFalse(TerminalCapabilities.isValid(listOf("长".repeat(22))))
        assertFalse(TerminalCapabilities.isValid(listOf("")))
        assertFalse(TerminalCapabilities.isValid(listOf("Café", "Cafe\u0301")))
        assertFalse(TerminalCapabilities.supports(listOf("widgetHttpV1", "widgetHttpV1"), TerminalCapabilities.WIDGET_HTTP))
    }
}
