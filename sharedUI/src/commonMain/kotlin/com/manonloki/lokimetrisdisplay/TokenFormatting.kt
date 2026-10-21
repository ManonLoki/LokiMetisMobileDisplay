package com.manonloki.lokimetrisdisplay

/** 只缩写展示值；整数商和有界余数避免 u64 的浮点精度损失与乘法溢出。 */
internal fun compactTokenAmount(value: String): String {
    if (value.isEmpty() || value.any { it !in '0'..'9' }) return value
    val total = value.toULongOrNull() ?: return value
    if (total < 1_000UL) return value
    val scales = listOf(1_000UL, 1_000_000UL, 1_000_000_000UL)
    val suffixes = listOf("K", "M", "B")
    var unit = when {
        total >= scales[2] -> 2
        total >= scales[1] -> 1
        else -> 0
    }
    while (true) {
        val scale = scales[unit]
        var whole = total / scale
        var fraction = ((total % scale) * 100UL + scale / 2UL) / scale
        if (fraction == 100UL) { whole += 1UL; fraction = 0UL }
        if (whole >= 1_000UL && unit < 2) { unit += 1; continue }
        val decimals = fraction.toString().padStart(2, '0').trimEnd('0')
        return whole.toString() + if (decimals.isEmpty()) suffixes[unit] else ".$decimals${suffixes[unit]}"
    }
}

/** 完整十进制仅加分组符，保留原始有效位与不可用状态。 */
internal fun exactTokenAmount(value: String): String =
    if (value.isNotEmpty() && value.all { it in '0'..'9' }) value.reversed().chunked(3).joinToString(",").reversed() else value
