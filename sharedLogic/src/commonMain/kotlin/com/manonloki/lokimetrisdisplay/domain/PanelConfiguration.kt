package com.manonloki.lokimetrisdisplay.domain

/** 本机面板布局独立于桌面快照和连接状态，隐藏卡片不会停止接收内容。 */
data class PanelConfiguration(
    val showUsage: Boolean = true,
    val showHooks: Boolean = true,
    val usageDetail: UsageDetail = UsageDetail.COMPACT,
    val hookLayout: HookLayout = HookLayout.SINGLE,
) {
    companion object {
        /** Swift 不使用 Kotlin 默认参数；所有宿主从此取得同一份初始布局。 */
        fun defaults(): PanelConfiguration = PanelConfiguration()

        /** 未知或损坏的选项回退到默认布局，不影响既有设备身份。 */
        fun restore(showUsage: Boolean = true, showHooks: Boolean = true,
                    detail: String? = null, hookLayout: String? = null): PanelConfiguration = PanelConfiguration(
            showUsage, showHooks,
            UsageDetail.entries.find { it.key == detail } ?: UsageDetail.COMPACT,
            HookLayout.entries.find { it.key == hookLayout } ?: HookLayout.SINGLE,
        )
    }
}

/** 用量卡片详略档位；key 为持久化值。 */
enum class UsageDetail(val key: String) { COMPACT("compact"), DETAILED("detailed") }

/** Hook 每页独立选择一张或四张卡片，不复用用量卡片的尺寸选项。 */
enum class HookLayout(val key: String, val columns: Int, val pageSize: Int) {
    SINGLE("1x1", 1, 1),
    GRID("2x2", 2, 4);

    /** 至少保留一页占位；使用减一后相除，最大 Int 数量也不会在进位时溢出。 */
    fun pageCount(itemCount: Int): Int = if (itemCount <= 0) 1 else 1 + (itemCount - 1) / pageSize

    /** Swift 友好的位置查询：来源索引保持原序，空槽或非法页格统一返回 -1。 */
    fun itemIndex(itemCount: Int, page: Int, cell: Int): Int {
        if (itemCount <= 0 || page !in 0 until pageCount(itemCount) || cell !in 0 until pageSize) return -1
        val index = page.toLong() * pageSize + cell
        return if (index < itemCount) index.toInt() else -1
    }

    /** 保持来源顺序；末页空槽保留网格位置，没有 Hook 时显示一页占位。 */
    fun <T> pages(items: List<T>): List<List<T?>> = List(pageCount(items.size)) { page ->
        List(pageSize) { cell ->
            itemIndex(items.size, page, cell).takeIf { it >= 0 }?.let(items::get)
        }
    }
}
