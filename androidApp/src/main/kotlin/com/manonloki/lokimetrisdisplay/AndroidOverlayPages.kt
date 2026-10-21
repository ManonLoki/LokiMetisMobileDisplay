package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.util.TypedValue
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.text.DateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** 从 Token 左滑进入额度、右滑进入 Hooks；保存稳定语义值而不是枚举序号。 */
internal enum class OverlayPage(val id: String, val label: String) {
    HOOKS("hooks", "Hooks"), TOKEN("token", "Token"), QUOTA("quota", "额度");

    fun adjacent(direction: Int): OverlayPage? = entries.getOrNull(ordinal + direction)

    companion object {
        fun restore(id: String?): OverlayPage = entries.firstOrNull { it.id == id } ?: TOKEN
    }
}

/** 每次只展示一类数据；只消费当前认证连接的新投影，不回填离线旧数据。 */
internal class OverlayPageContent(context: Context) : LinearLayout(context) {
    init {
        orientation = VERTICAL
        setPadding(0, dp(8), 0, dp(8))
    }

    fun render(page: OverlayPage, view: TerminalLinkView?) {
        removeAllViews()
        val snapshot = view?.takeIf { it.connected && it.receivedAtMs != null }?.snapshot
        if (snapshot == null) {
            text("等待桌面同步 · 离线", color = MUTED)
            text(if (view?.selectedId == null) "请打开应用，选择已配对桌面。" else "正在等待已配对桌面的认证连接与新数据。")
            text("尚无当前连接的同步时间", size = 12f, color = MUTED)
            return
        }
        when (page) {
            OverlayPage.TOKEN -> tokens(snapshot.tokens)
            OverlayPage.QUOTA -> quota(snapshot.providerQuota)
            OverlayPage.HOOKS -> hooks(snapshot)
        }
        text("同步于 " + DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM)
            .format(Date(requireNotNull(requireNotNull(view).receivedAtMs))), size = 11f, color = MUTED)
    }

    private fun tokens(tokens: TerminalTokens?) {
        text("Token 总量", size = 13f, color = MUTED)
        if (tokens == null) {
            text("不可用", size = 22f)
            text("桌面暂未提供 Token 统计", color = MUTED)
            return
        }
        val quality = listOf(
            when (tokens.all.completeness) { "complete" -> "完整"; "partial" -> "部分"; else -> "范围未知" },
            when (tokens.all.confidence) { "exact" -> "精确"; "derived" -> "估算"; else -> "待核对" },
        ).joinToString(" · ")
        text(tokens.all.text, size = 42f, color = CYAN).apply {
            typeface = Typeface.MONOSPACE
            setSingleLine()
            setAutoSizeTextTypeUniformWithConfiguration(16, 42, 1, TypedValue.COMPLEX_UNIT_SP)
            contentDescription = "Token 总量 ${tokens.all.text}，$quality"
        }
        text("统计日 ${tokens.day.date}\n时区 ${tokens.day.zone}", size = 12f, color = MUTED)
    }

    private fun quota(quota: ProviderQuotaSnapshot?) {
        text("额度剩余", size = 16f, bold = true)
        if (quota == null || quota.providers.isEmpty()) {
            text("暂无额度数据", size = 20f)
            text("桌面尚未提供可用的额度窗口。", size = 12f, color = MUTED)
            return
        }
        quota.providers.forEach { provider ->
            text(provider.label + (provider.plan?.let { " · $it" } ?: ""), size = 15f, bold = true)
            val row = LinearLayout(context).apply { orientation = HORIZONTAL }
            provider.windows.forEach { window ->
                val column = LinearLayout(context).apply {
                    orientation = VERTICAL
                    setPadding(0, 0, dp(8), 0)
                }
                val windowLabel = window.kindLabel
                val color = when (window.level) { 0 -> RED; 1 -> AMBER; else -> GREEN }
                column.addView(label("$windowLabel ${window.percentText}", size = 14f, color = color, bold = true))
                column.addView(ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
                    setPadding(0, 0, 0, 0)
                    minimumHeight = 0
                    minHeight = 0
                    isIndeterminate = false
                    max = 1_000
                    progress = window.remainingTenths
                    progressTintList = ColorStateList.valueOf(color)
                    progressBackgroundTintList = ColorStateList.valueOf(Color.rgb(50, 65, 76))
                    contentDescription = "${provider.label}，$windowLabel 额度剩余 ${window.percentText}"
                }, LayoutParams(LayoutParams.MATCH_PARENT, dp(6)))
                window.resetAtUnix?.let { column.addView(label("重置 ${quotaTime(it)}", size = 11f, color = MUTED)) }
                row.addView(column, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            }
            addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        }
        text("额度更新 ${quotaTime(quota.observedAtUnix)}", size = 11f, color = MUTED)
    }

    private fun hooks(snapshot: TerminalSnapshot) {
        if (!snapshot.hooksAvailable) { text("Hooks 暂不可用", size = 20f); return }
        if (snapshot.hooks.isEmpty()) { text("Hooks 暂无状态", size = 20f); return }
        text(listOf("idle" to "空闲", "running" to "运行", "asking" to "询问", "error" to "出错")
            .joinToString(" · ") { (behavior, label) -> "$label ${snapshot.hooks.count { it.behavior == behavior }}" }, color = MUTED)
        snapshot.hooks.forEach { hook ->
            text("${agentDisplayName(hook.agent)} #${hook.slot}", size = 15f, bold = true)
            text(hook.label, color = when (hook.behavior) { "running" -> CYAN; "asking" -> AMBER; "error" -> RED; else -> FOREGROUND })
        }
    }

    private fun text(value: String, size: Float = 13f, color: Int = FOREGROUND, bold: Boolean = false): TextView =
        label(value, size, color, bold).also { addView(it, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)) }

    private fun label(value: String, size: Float, color: Int, bold: Boolean = false) = TextView(context).apply {
        text = value
        textSize = size
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
        setLineSpacing(dp(2).toFloat(), 1f)
        setPadding(0, dp(4), 0, dp(4))
    }

    private fun quotaTime(seconds: Long): String = runCatching {
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withLocale(Locale.getDefault())
            .format(Instant.ofEpochSecond(seconds).atZone(ZoneId.systemDefault()))
    }.getOrElse { "时间未知" }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    companion object {
        private val FOREGROUND = Color.rgb(221, 233, 237)
        private val MUTED = Color.rgb(155, 177, 188)
        private val CYAN = Color.rgb(100, 229, 227)
        private val RED = Color.rgb(250, 82, 82)
        private val AMBER = Color.rgb(245, 197, 66)
        private val GREEN = Color.rgb(64, 192, 87)
    }
}

/** 横向手势换有限页面，纵向仍交给 ScrollView，不要求快速甩动。 */
internal class OverlaySwipeScrollView(context: Context, private val turnPage: (Int) -> Boolean) : ScrollView(context) {
    var maximumHeight = Int.MAX_VALUE
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var axis = 0

    private fun track(event: MotionEvent) {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) { downX = event.x; downY = event.y; axis = 0 }
        if (axis == 0 && event.actionMasked == MotionEvent.ACTION_MOVE) {
            val dx = abs(event.x - downX)
            val dy = abs(event.y - downY)
            if (dx > slop && dx > dy * 1.3f) axis = 2
            else if (dy > slop && dy >= dx) axis = 1
        }
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        track(event)
        return axis == 2 || super.onInterceptTouchEvent(event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        track(event)
        if (axis != 2) return super.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP) {
            val dx = event.x - downX
            if (abs(dx) >= maxOf(slop * 3f, width * 0.16f)) turnPage(if (dx < 0) 1 else -1)
            performClick()
        }
        return true
    }

    override fun performClick(): Boolean = super.performClick()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val supplied = View.MeasureSpec.getSize(heightMeasureSpec)
        val limit = if (View.MeasureSpec.getMode(heightMeasureSpec) == View.MeasureSpec.UNSPECIFIED) maximumHeight else minOf(maximumHeight, supplied)
        super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(limit, View.MeasureSpec.AT_MOST))
    }
}
