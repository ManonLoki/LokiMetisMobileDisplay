package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.text.TextUtils
import android.util.TypedValue
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.LinearLayout
import android.widget.TextView
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs
import kotlin.math.roundToInt

/** 悬浮窗只有 Token 与 Hooks 两页，左右滑动互换；保存稳定语义值而不是枚举序号。 */
internal enum class OverlayPage(val id: String, val label: String) {
    TOKEN("token", "Token"), HOOKS("hooks", "Hooks");

    val other: OverlayPage get() = if (this == TOKEN) HOOKS else TOKEN

    companion object {
        /** 未知或缺失的保存值回到 Token 页。 */
        fun restore(id: String?): OverlayPage = entries.firstOrNull { it.id == id } ?: TOKEN
    }
}

/**
 * 紧凑卡片每次只画一页，内容行数有上限，不需要滚动容器。
 * 投影未变化时跳过重建；横向滑动交给 [turnPage]，纵向手势不处理。
 */
internal class OverlayPageContent(context: Context, private val turnPage: () -> Unit) : LinearLayout(context) {
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var rendered: Any? = null

    init {
        orientation = VERTICAL
        setPadding(0, dp(4), 0, dp(4))
    }

    /** 只消费当前认证连接的新投影，不回填离线旧数据。 */
    fun render(page: OverlayPage, view: TerminalLinkView?) {
        val snapshot = view?.takeIf { it.connected && it.receivedAtMs != null }?.snapshot
        // 同步时间只显示到分钟，同一分钟内重复推送相同内容不触发视图重建。
        val time = view?.receivedAtMs?.takeIf { snapshot != null }
            ?.let { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it)) }
        val key = listOf(page, snapshot, time, view?.selectedId == null)
        if (key == rendered) return
        rendered = key
        removeAllViews()
        if (snapshot == null) {
            text("等待桌面同步", size = 15f, bold = true)
            text(if (view?.selectedId == null) "请打开应用，选择已配对桌面。" else "正在等待已配对桌面的认证连接。", size = 12f, color = MUTED)
            return
        }
        when (page) {
            OverlayPage.TOKEN -> tokens(snapshot)
            OverlayPage.HOOKS -> hooks(snapshot)
        }
        text("同步于 $time", size = 11f, color = MUTED)
    }

    private fun tokens(snapshot: TerminalSnapshot) {
        val tokens = snapshot.displayTokens
        text(tokens?.all?.text ?: "不可用", size = 30f, color = if (tokens == null) MUTED else CYAN).apply {
            typeface = Typeface.MONOSPACE
            setSingleLine()
            setAutoSizeTextTypeUniformWithConfiguration(14, 30, 1, TypedValue.COMPLEX_UNIT_SP)
            contentDescription = "Token 总量 ${tokens?.all?.text ?: "不可用"}"
        }
        snapshot.displayProviderQuota?.providers.orEmpty().take(MAX_ROWS).forEach { provider ->
            val windows = provider.windows
            if (windows.isEmpty()) return@forEach
            val level = windows.minOf { it.level }
            row(provider.label + "  " + windows.joinToString(" · ") { "${it.kindLabel} ${it.percentText}" },
                color = when (level) { 0 -> RED; 1 -> AMBER; else -> FOREGROUND })
        }
    }

    private fun hooks(snapshot: TerminalSnapshot) {
        val hooks = snapshot.hooks.takeIf { snapshot.hooksAvailable }
        if (hooks.isNullOrEmpty()) { text(if (hooks == null) "Hooks 暂不可用" else "Hooks 暂无状态", size = 15f); return }
        hooks.take(MAX_ROWS).forEach { hook ->
            val line = "${agentDisplayName(hook.agent)} #${hook.slot} ${hook.label}" +
                hook.content.lineSequence().firstOrNull { it.isNotBlank() }?.let { " · ${it.trim()}" }.orEmpty()
            row(line, color = when (hook.behavior) { "running" -> CYAN; "asking" -> AMBER; "error" -> RED; else -> FOREGROUND })
        }
        if (hooks.size > MAX_ROWS) text("另有 ${hooks.size - MAX_ROWS} 项，打开应用查看", size = 11f, color = MUTED)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> { downX = event.x; downY = event.y }
            MotionEvent.ACTION_UP -> {
                val dx = event.x - downX
                if (abs(dx) >= maxOf(slop * 3f, width * 0.16f) && abs(dx) > abs(event.y - downY)) turnPage()
                else performClick()
            }
        }
        return true
    }

    /** 点击内容同样换页，方便无障碍服务和不便滑动的场景。 */
    override fun performClick(): Boolean { super.performClick(); turnPage(); return true }

    private fun row(value: String, color: Int) = text(value, size = 13f, color = color).apply {
        setSingleLine()
        ellipsize = TextUtils.TruncateAt.END
    }

    private fun text(value: String, size: Float, color: Int = FOREGROUND, bold: Boolean = false): TextView =
        TextView(context).apply {
            text = value
            textSize = size
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(2), 0, dp(2))
        }.also { addView(it, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)) }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    companion object {
        private const val MAX_ROWS = 4
        private val FOREGROUND = Color.rgb(221, 233, 237)
        private val MUTED = Color.rgb(155, 177, 188)
        private val CYAN = Color.rgb(100, 229, 227)
        private val RED = Color.rgb(250, 82, 82)
        private val AMBER = Color.rgb(245, 197, 66)
    }
}
