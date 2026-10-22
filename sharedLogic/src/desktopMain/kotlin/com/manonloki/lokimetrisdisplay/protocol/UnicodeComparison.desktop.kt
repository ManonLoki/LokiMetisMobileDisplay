package com.manonloki.lokimetrisdisplay

import java.text.Normalizer

/** JVM 与 Android 使用相同 Unicode NFC 规范化，保持提供商去重规则一致。 */
internal actual fun normalizeComparisonText(value: String): String =
    Normalizer.normalize(value, Normalizer.Form.NFC)
