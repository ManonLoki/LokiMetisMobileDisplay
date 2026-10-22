package com.manonloki.lokimetrisdisplay

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** 使用用户本地时区和日期格式；参数始终来自上游更新时间。 */
internal fun formatQuotaTimestamp(unixSeconds: Long): String = runCatching {
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault())
        .format(Instant.ofEpochSecond(unixSeconds).atZone(ZoneId.systemDefault()))
}.getOrElse { "时间未知" }
