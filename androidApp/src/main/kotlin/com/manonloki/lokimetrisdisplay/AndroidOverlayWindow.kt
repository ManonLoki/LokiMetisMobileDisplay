package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 悬浮窗的视图、页签与窗口几何。只负责画和拖动，不感知服务生命周期、权限或通知；
 * 用户关闭和系统移除分别通过 [onClose]、[onLost] 交回服务决定后续状态。
 */
internal class AndroidOverlayWindow(
    private val context: Context,
    title: String,
    start: Point,
    private val onClose: () -> Unit,
    private val onLost: () -> Unit,
) {
    private val windows = context.getSystemService(WindowManager::class.java)
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private var page = OverlayPage.restore(preferences.getString(PAGE_KEY, null))
    private var latest: TerminalLinkView? = null
    private val heading: TextView
    private val content = OverlayPageContent(context, ::turnPage)
    private val root: LinearLayout
    private val params: WindowManager.LayoutParams

    /** 最近一次约束后的屏幕坐标；服务在重建窗口时沿用。 */
    val position: Point get() = Point(params.x, params.y)

    init {
        val safe = safeBounds()
        val scale = context.resources.configuration.fontScale.coerceAtLeast(1f)
        val width = minOf(safe.width(), dp((240 * scale).coerceAtMost(340f))).coerceAtLeast(1)
        root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12f), dp(2f), dp(4f), dp(8f))
            background = GradientDrawable().apply {
                setColor(Color.rgb(18, 25, 33))
                cornerRadius = dp(16f).toFloat()
                setStroke(dp(1f), Color.rgb(56, 143, 158))
            }
            elevation = dp(6f).toFloat()
        }
        val header = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        heading = TextView(context).apply {
            setTextColor(ACCENT)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            minHeight = dp(40f)
            gravity = Gravity.CENTER_VERTICAL
            setOnClickListener { turnPage() }
        }
        header.addView(heading, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(closeButton(), LinearLayout.LayoutParams(dp(40f), dp(40f)))
        root.addView(header)
        root.addView(content, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(8f) })
        // 只有内容高度真的变化才重新约束位置，普通推送不触发窗口布局更新。
        root.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (bottom - top != oldBottom - oldTop) constrainPosition()
        }
        params = WindowManager.LayoutParams(
            width, WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            // 坐标按屏幕左上角计算，RTL 下也不能镜像为 START。
            gravity = Gravity.TOP or Gravity.LEFT
            x = start.x.coerceIn(safe.left, maxOf(safe.left, safe.right - width))
            y = start.y.coerceIn(safe.top, maxOf(safe.top, safe.bottom - dp(96f)))
            setTitle(title)
            // 使用屏幕坐标和系统安全区自行约束位置，旋转后也不进入挖孔或系统栏。
            setFitInsetsTypes(0)
        }
        attachDrag(heading)
    }

    /** 加入窗口；系统拒绝时抛出 RuntimeException，由调用方转换为可见反馈。 */
    fun show() { windows.addView(root, params) }

    /** 仅显示当前已认证投影，连接失效后立即恢复等待态，避免把旧用量当作实时值。 */
    fun render(view: TerminalLinkView?) {
        latest = view
        heading.text = OverlayPage.entries.joinToString("   ") { if (it == page) "● ${it.label}" else "○ ${it.label}" }
        heading.contentDescription = "当前${page.label}页，点击或左右滑动切换，拖动移动悬浮窗"
        content.render(page, view)
    }

    /** 立即移除，系统已先行移除时静默结束。 */
    fun remove() {
        root.visibility = View.GONE
        try { windows.removeViewImmediate(root) } catch (_: RuntimeException) { /* 已被系统移除。 */ }
    }

    private fun turnPage() {
        page = page.other
        preferences.edit().putString(PAGE_KEY, page.id).apply()
        render(latest)
    }

    private fun closeButton(): Button = Button(context).apply {
        text = "×"
        textSize = 20f
        setTextColor(ACCENT)
        contentDescription = "关闭悬浮窗，继续后台同步"
        minWidth = 0; minimumWidth = 0
        minHeight = 0; minimumHeight = 0
        setPadding(0, 0, 0, 0)
        background = GradientDrawable().apply { setColor(Color.TRANSPARENT); cornerRadius = dp(12f).toFloat() }
        setOnClickListener { onClose() }
    }

    /** 标题行拖动移动窗口；未超过触摸阈值视为点击，交给标题切页。 */
    private fun attachDrag(handle: View) {
        var downX = 0f; var downY = 0f; var startX = 0; var startY = 0; var dragging = false
        val slop = ViewConfiguration.get(context).scaledTouchSlop
        handle.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY; startX = params.x; startY = params.y; dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX; val dy = event.rawY - downY
                    if (abs(dx) > slop || abs(dy) > slop) dragging = true
                    if (dragging) { params.x = startX + dx.roundToInt(); params.y = startY + dy.roundToInt(); constrainPosition() }
                    true
                }
                MotionEvent.ACTION_UP -> { if (!dragging) view.performClick(); true }
                MotionEvent.ACTION_CANCEL -> true
                else -> false
            }
        }
    }

    /** 屏幕去掉系统栏、挖孔和 8dp 边距后的可放置区域。 */
    private fun safeBounds(): Rect {
        val metrics = windows.currentWindowMetrics
        val bounds = Rect(metrics.bounds)
        val insets = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        bounds.inset(insets.left + dp(8f), insets.top + dp(8f), insets.right + dp(8f), insets.bottom + dp(8f))
        return bounds
    }

    private fun constrainPosition() {
        val safe = safeBounds()
        params.x = params.x.coerceIn(safe.left, maxOf(safe.left, safe.right - root.width.coerceAtLeast(params.width)))
        params.y = params.y.coerceIn(safe.top, maxOf(safe.top, safe.bottom - root.height.coerceAtLeast(dp(64f))))
        if (!root.isAttachedToWindow) return
        try { windows.updateViewLayout(root, params) } catch (_: RuntimeException) { onLost() }
    }

    private fun dp(value: Float): Int = (value * context.resources.displayMetrics.density).roundToInt()

    private companion object {
        const val PREFERENCES = "overlay_presentation"
        const val PAGE_KEY = "page_id"
        val ACCENT = Color.rgb(131, 224, 229)
    }
}
