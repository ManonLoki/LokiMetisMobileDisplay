package com.manonloki.lokimetrisdisplay

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalInspectionMode
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** 入口提供窗口可见和最小化状态；失焦仍允许副屏正常播放。 */
@Composable
fun desktopMotionEnabled(windowVisible: Boolean, minimized: Boolean, animationsAllowed: Boolean = true): Boolean =
    windowVisible && !minimized && animationsAllowed && !LocalInspectionMode.current

/** 使用本机时区与日期格式，只格式化上游时间，不改写快照日期。 */
fun quotaTimestamp(unixSeconds: Long): String = runCatching {
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withLocale(Locale.getDefault())
        .format(Instant.ofEpochSecond(unixSeconds).atZone(ZoneId.systemDefault()))
}.getOrElse { "时间未知" }
