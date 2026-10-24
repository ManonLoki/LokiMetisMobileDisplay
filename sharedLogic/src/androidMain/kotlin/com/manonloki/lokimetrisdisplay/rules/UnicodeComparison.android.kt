package com.manonloki.lokimetrisdisplay.rules

import java.text.Normalizer

internal actual fun normalizeComparisonText(value: String): String =
    Normalizer.normalize(value, Normalizer.Form.NFC)
