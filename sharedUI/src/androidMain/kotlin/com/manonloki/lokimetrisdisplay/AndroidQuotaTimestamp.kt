package com.manonloki.lokimetrisdisplay

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

internal actual fun formatQuotaTimestamp(unixSeconds: Long): String = runCatching {
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault())
        .format(Instant.ofEpochSecond(unixSeconds).atZone(ZoneId.systemDefault()))
}.getOrElse { "时间未知" }
