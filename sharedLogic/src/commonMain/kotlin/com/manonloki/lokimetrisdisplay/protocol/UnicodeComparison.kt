package com.manonloki.lokimetrisdisplay

/** 仅生成 Unicode NFC 比较键；原始名称、展示值和 Codable／缓存字段保持不变。 */
internal expect fun normalizeComparisonText(value: String): String
