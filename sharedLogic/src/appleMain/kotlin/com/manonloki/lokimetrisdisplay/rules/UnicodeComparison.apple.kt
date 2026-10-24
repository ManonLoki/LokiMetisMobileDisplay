package com.manonloki.lokimetrisdisplay.rules

import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSString
import platform.Foundation.precomposedStringWithCanonicalMapping

@OptIn(ExperimentalForeignApi::class)
@Suppress("CAST_NEVER_SUCCEEDS")
internal actual fun normalizeComparisonText(value: String): String =
    (value as NSString).precomposedStringWithCanonicalMapping
