package com.manonloki.lokimetrisdisplay

/** 本机面板布局独立于桌面快照和连接状态，隐藏卡片不会停止接收内容。 */
data class PanelConfiguration(
    val showUsage: Boolean = true,
    val showHooks: Boolean = true,
    val usageDetail: UsageDetail = UsageDetail.COMPACT,
    val usageSize: UsageCardSize = UsageCardSize.SMALL,
    val hookLayout: HookLayout = HookLayout.SINGLE,
) {
    companion object {
        /** 未知或损坏的选项回退到默认布局，不影响既有设备身份。 */
        fun restore(showUsage: Boolean = true, showHooks: Boolean = true,
                    detail: String? = null, size: String? = null,
                    hookLayout: String? = null): PanelConfiguration = PanelConfiguration(
            showUsage, showHooks,
            UsageDetail.entries.find { it.key == detail } ?: UsageDetail.COMPACT,
            UsageCardSize.entries.find { it.key == size } ?: UsageCardSize.SMALL,
            HookLayout.entries.find { it.key == hookLayout } ?: HookLayout.SINGLE,
        )
    }
}

enum class UsageDetail(val key: String) { COMPACT("compact"), DETAILED("detailed") }
enum class UsageCardSize(val key: String, val columns: Int) { SMALL("1x1", 1), LARGE("2x2", 2) }

/** Hook 每页独立选择一张或四张卡片，不复用用量卡片的尺寸选项。 */
enum class HookLayout(val key: String, val columns: Int, val pageSize: Int) {
    SINGLE("1x1", 1, 1),
    GRID("2x2", 2, 4);

    /** 保持来源顺序；末页空槽保留网格位置，没有 Hook 时显示一页占位。 */
    fun <T> pages(items: List<T>): List<List<T?>> {
        if (items.isEmpty()) return listOf(List(pageSize) { null })
        return items.chunked(pageSize).map { page ->
            List(pageSize) { index -> page.getOrNull(index) }
        }
    }
}
