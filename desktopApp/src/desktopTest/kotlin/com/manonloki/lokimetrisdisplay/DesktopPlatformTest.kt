package com.manonloki.lokimetrisdisplay

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.test.*

class DesktopPlatformTest {
    @Test fun quotaTimestampFormatsSecondsInLocalZoneAndHandlesOverflow() {
        val seconds = 1_790_000_000L
        val expected = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withLocale(Locale.getDefault())
            .format(Instant.ofEpochSecond(seconds).atZone(ZoneId.systemDefault()))
        assertEquals(expected, quotaTimestamp(seconds))
        assertEquals("时间未知", quotaTimestamp(Long.MAX_VALUE))
    }
}
