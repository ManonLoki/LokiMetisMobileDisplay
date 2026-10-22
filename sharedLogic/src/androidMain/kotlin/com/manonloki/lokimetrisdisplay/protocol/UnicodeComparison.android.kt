package com.manonloki.lokimetrisdisplay

import java.text.Normalizer

internal actual fun normalizeComparisonText(value: String): String =
    Normalizer.normalize(value, Normalizer.Form.NFC)
