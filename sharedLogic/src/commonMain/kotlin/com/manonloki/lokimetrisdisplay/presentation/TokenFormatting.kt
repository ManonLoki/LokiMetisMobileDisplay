package com.manonloki.lokimetrisdisplay.presentation

/** 宿主无关的 Token 数字展示，Android 与 iOS 主界面使用同一套精度和进位规则。 */
object TokenFormatting {
    /** 只缩写展示值；整数商和有界余数避免 u64 的浮点精度损失与乘法溢出。 */
    fun compact(value: String): String = compact(value, 2)

    /** 系统小组件可用更高数量级；与主面板共用舍入算法，单位策略保持原有差异。 */
    fun compactForWidget(value: String): String = compact(value, 5)

    private fun compact(value: String, maximumUnit: Int): String {
        if (value.isEmpty() || value.any { it !in '0'..'9' }) return value
        val total = value.toULongOrNull() ?: return value
        if (total < 1_000UL) return value
        val scales = listOf(1_000UL, 1_000_000UL, 1_000_000_000UL,
            1_000_000_000_000UL, 1_000_000_000_000_000UL, 1_000_000_000_000_000_000UL)
        val suffixes = listOf("K", "M", "B", "T", "P", "E")
        var unit = (0..maximumUnit).last { total >= scales[it] }
        while (true) {
            val scale = scales[unit]
            var whole = total / scale
            // 所有 scale 可被 200 整除；先缩小除数，E 级也不会因余数乘 100 而溢出。
            var fraction = ((total % scale) + scale / 200UL) / (scale / 100UL)
            if (fraction == 100UL) { whole += 1UL; fraction = 0UL }
            if (whole >= 1_000UL && unit < maximumUnit) { unit += 1; continue }
            val decimals = fraction.toString().padStart(2, '0').trimEnd('0')
            return whole.toString() + if (decimals.isEmpty()) suffixes[unit] else ".$decimals${suffixes[unit]}"
        }
    }

    /** 完整十进制仅加分组符，保留原始有效位与不可用状态。 */
    fun exact(value: String): String =
        if (value.isNotEmpty() && value.all { it in '0'..'9' }) value.reversed().chunked(3).joinToString(",").reversed() else value

}
