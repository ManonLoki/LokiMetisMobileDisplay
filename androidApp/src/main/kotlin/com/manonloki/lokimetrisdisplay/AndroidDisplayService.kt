package com.manonloki.lokimetrisdisplay

import android.app.AppOpsManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.Display
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.util.concurrent.CopyOnWriteArraySet
import kotlin.math.abs
import kotlin.math.roundToInt

/** 用户开启的常驻连接与悬浮窗状态；窗口隐藏不会关闭独立的后台连接。 */
data class AndroidDisplayServiceState(
    val running: Boolean = false,
    val overlayRequested: Boolean = false,
    val overlayVisible: Boolean = false,
    val error: String? = null,
)

/** 只由用户启动的前台服务。不持久化开启状态，也不在进程终止或重启后自动复活。 */
class AndroidDisplayService : Service() {
    private val owner: DisplayApplication get() = application as DisplayApplication
    private val main = Handler(Looper.getMainLooper())
    private lateinit var windowContext: Context
    private val windows: WindowManager get() = windowContext.getSystemService(WindowManager::class.java)
    private var latest: TerminalLinkView? = null
    private var requested = false
    private var collapsed = false
    private var root: LinearLayout? = null
    private var heading: TextView? = null
    private var content: OverlayPageContent? = null
    private var pageScroll: OverlaySwipeScrollView? = null
    private var pageButtons: Map<OverlayPage, Button> = emptyMap()
    private var page = OverlayPage.TOKEN
    private var windowParams: WindowManager.LayoutParams? = null
    private var receiverRegistered = false
    private var observingOps = false
    private var connectionOwned = false
    private var shuttingDown = false
    private var terminalError: String? = null
    private var windowX = 0
    private var windowY = 0
    private val projectionListener: (AndroidLinkProjection) -> Unit = { projection ->
        latest = projection.view
        renderContent()
        if (state.running) updateNotification()
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> removeOverlay()
                Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> reconcileOverlay()
            }
        }
    }
    private val overlayOpListener = AppOpsManager.OnOpChangedListener { operation, packageName ->
        if (operation == AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW && packageName == this.packageName) {
            main.post { if (!shuttingDown) reconcileOverlay() }
        }
    }
    private val overlayGuard = object : Runnable {
        override fun run() {
            if (shuttingDown || !state.running || !requested) return
            // OEM权限页不一定发送AppOps回调；也检查锁屏以覆盖非标准锁屏实现。
            reconcileOverlay()
            main.postDelayed(this, 1_500)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowContext = createWindowContext(
            getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null,
        )
        page = OverlayPage.restore(getSharedPreferences(PRESENTATION_PREFERENCES, MODE_PRIVATE).getString(PAGE_KEY, null))
        latest = owner.link?.state?.view
        val channel = NotificationChannel(CHANNEL, "后台实时同步", NotificationManager.IMPORTANCE_LOW).apply {
            description = "保持与已配对局域网桌面的连接，并接收桌面状态推送。"
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        registerReceiver(screenReceiver, filter)
        receiverRegistered = true
        try {
            getSystemService(AppOpsManager::class.java).startWatchingMode(
                AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW, packageName, overlayOpListener,
            )
            observingOps = true
        } catch (_: RuntimeException) {
            // 撤权仍由窗口操作与短周期guard检查，不能因厂商AppOps实现崩溃。
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopSelf(); return START_NOT_STICKY }
            ACTION_HIDE -> {
                requested = false
                removeOverlay()
                publish(state.copy(overlayRequested = false, overlayVisible = false, error = null))
                if (connectionOwned) updateNotification() else stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> Unit
            else -> { stopSelf(); return START_NOT_STICKY }
        }
        if (owner.link == null || !owner.permitted()) {
            failAndStop("请先在应用内允许本地网络并完成设备配对。")
            return START_NOT_STICKY
        }
        requested = intent.getBooleanExtra(EXTRA_OVERLAY, false)
        try {
            startForeground(NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } catch (_: RuntimeException) {
            failAndStop("系统未允许启动后台实时同步，请回到应用后重试。")
            return START_NOT_STICKY
        }
        publish(AndroidDisplayServiceState(running = true, overlayRequested = requested))
        if (!connectionOwned) {
            connectionOwned = true
            owner.setBackgroundConnection(true)
            owner.addProjectionListener(projectionListener)
        }
        reconcileOverlay()
        updateNotification()
        main.removeCallbacks(overlayGuard)
        if (requested) main.postDelayed(overlayGuard, 1_500)
        return START_NOT_STICKY
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        removeOverlay()
        reconcileOverlay()
    }

    override fun onDestroy() {
        shuttingDown = true
        main.removeCallbacksAndMessages(null)
        owner.removeProjectionListener(projectionListener)
        if (connectionOwned) owner.setBackgroundConnection(false)
        connectionOwned = false
        removeOverlay()
        if (receiverRegistered) unregisterReceiver(screenReceiver)
        if (observingOps) try { getSystemService(AppOpsManager::class.java).stopWatchingMode(overlayOpListener) } catch (_: RuntimeException) { /* OEM权限服务可能已结束订阅。 */ }
        stopForeground(STOP_FOREGROUND_REMOVE)
        publish(AndroidDisplayServiceState(error = terminalError))
        super.onDestroy()
    }

    private fun failAndStop(message: String) {
        terminalError = message
        publish(AndroidDisplayServiceState(error = message))
        stopSelf()
    }

    /** 锁屏期间立即移除窗口；保留用户意图，解锁后才重新显示。 */
    private fun mayShow(): Boolean =
        getSystemService(PowerManager::class.java).isInteractive &&
            !getSystemService(KeyguardManager::class.java).isKeyguardLocked

    private fun reconcileOverlay() {
        if (!requested || !state.running || shuttingDown) { removeOverlay(); return }
        if (!Settings.canDrawOverlays(this)) {
            requested = false
            removeOverlay()
            publish(state.copy(overlayRequested = false, overlayVisible = false, error = "悬浮窗权限已关闭，后台同步继续运行。"))
            return
        }
        if (!mayShow()) { removeOverlay(); return }
        if (root != null) return
        createOverlay()
    }

    /** 仅显示当前已认证投影，连接失效后立即恢复等待态，避免把旧用量当作实时值。 */
    private fun renderContent() {
        val view = latest
        val snapshot = view?.takeIf { it.connected && it.receivedAtMs != null }?.snapshot
        val tokens = snapshot?.displayTokens
        heading?.text = when {
            collapsed && page == OverlayPage.TOKEN && tokens != null -> "Token ${tokens.all.text}"
            collapsed -> page.label
            else -> "${page.label} · ${page.ordinal + 1}/${OverlayPage.entries.size}"
        }
        heading?.contentDescription = "${page.label}页，拖动移动悬浮窗"
        content?.render(page, view)
        pageButtons.forEach { (value, button) ->
            button.isSelected = value == page
            button.stateDescription = if (value == page) "当前页" else ""
            button.setTextColor(if (value == page) Color.rgb(100, 229, 227) else Color.rgb(155, 177, 188))
            button.typeface = if (value == page) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
        root?.post { constrainPosition() }
    }

    private fun turnPage(direction: Int): Boolean {
        val next = page.adjacent(direction) ?: return false
        selectPage(next)
        return true
    }

    private fun selectPage(next: OverlayPage) {
        if (next == page) return
        page = next
        getSharedPreferences(PRESENTATION_PREFERENCES, MODE_PRIVATE).edit().putString(PAGE_KEY, next.id).apply()
        renderContent()
        pageScroll?.post { pageScroll?.scrollTo(0, 0) }
    }

    private fun createOverlay() {
        val safe = safeBounds()
        val scale = resources.configuration.fontScale.coerceAtLeast(1f)
        val width = minOf(safe.width(), dp((304 * scale).coerceAtMost(420f))).coerceAtLeast(1)
        val container = BoundedLinearLayout(windowContext).apply {
            maximumHeight = safe.height()
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12f), dp(8f), dp(12f), dp(12f))
            background = GradientDrawable().apply {
                setColor(Color.rgb(18, 25, 33))
                cornerRadius = dp(18f).toFloat()
                setStroke(dp(1f), Color.rgb(56, 143, 158))
            }
            elevation = dp(8f).toFloat()
        }
        val header = LinearLayout(windowContext).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val title = TextView(windowContext).apply {
            setTextColor(Color.WHITE)
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            minHeight = dp(48f)
            gravity = Gravity.CENTER_VERTICAL
            contentDescription = "拖动移动悬浮窗"
        }
        header.addView(title, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val fold = button(if (collapsed) "+" else "−", if (collapsed) "展开悬浮窗" else "折叠悬浮窗") {
            collapsed = !collapsed
            removeOverlay()
            reconcileOverlay()
        }
        header.addView(fold, LinearLayout.LayoutParams(dp(48f), dp(48f)))
        header.addView(button("×", "关闭悬浮窗，继续后台同步") {
            requested = false
            removeOverlay()
            publish(state.copy(overlayRequested = false, overlayVisible = false, error = null))
            updateNotification()
        }, LinearLayout.LayoutParams(dp(48f), dp(48f)))
        container.addView(header)
        val text = OverlayPageContent(windowContext)
        val scroll = OverlaySwipeScrollView(windowContext, ::turnPage).apply {
            maximumHeight = (minOf(safe.height(), dp((420 * scale).coerceAtMost(580f))) - dp(140f * scale)).coerceAtLeast(dp(48f))
            minimumHeight = minOf(maximumHeight, dp(180f))
            addView(text, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
            visibility = if (collapsed) View.GONE else View.VISIBLE
        }
        container.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        val navigation = LinearLayout(windowContext).apply {
            orientation = LinearLayout.HORIZONTAL
            visibility = if (collapsed) View.GONE else View.VISIBLE
        }
        pageButtons = OverlayPage.entries.associateWith { value ->
            button(value.label, "切换到${value.label}页") { selectPage(value) }.apply {
                textSize = 13f
                navigation.addView(this, LinearLayout.LayoutParams(0, dp(48f), 1f))
            }
        }
        container.addView(navigation, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        val params = WindowManager.LayoutParams(
            width, WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.LEFT
            x = windowX.coerceIn(safe.left, maxOf(safe.left, safe.right - width))
            y = windowY.coerceIn(safe.top, maxOf(safe.top, safe.bottom - dp(96f)))
            setTitle("${getString(R.string.app_name)} 状态悬浮窗")
            // 使用屏幕坐标和系统安全区自行约束位置，旋转后也不进入挖孔或系统栏。
            setFitInsetsTypes(0)
        }
        root = container; heading = title; content = text; pageScroll = scroll; windowParams = params
        attachDrag(title)
        renderContent()
        try {
            // 权限、锁屏状态在创建前再检查一次，避免广播和绘制之间的窗口。
            if (!Settings.canDrawOverlays(this) || !mayShow()) { removeOverlay(); return }
            windows.addView(container, params)
            publish(state.copy(overlayRequested = requested, overlayVisible = true, error = null))
            container.post { constrainPosition() }
        } catch (_: RuntimeException) {
            removeOverlay()
            requested = false
            publish(state.copy(overlayRequested = false, overlayVisible = false, error = "系统暂未允许显示悬浮窗，后台同步继续运行。"))
        }
    }

    private fun button(label: String, description: String, click: () -> Unit): Button = Button(windowContext).apply {
        text = label
        textSize = 20f
        setTextColor(Color.rgb(131, 224, 229))
        contentDescription = description
        minWidth = 0; minimumWidth = 0
        minHeight = 0; minimumHeight = 0
        setPadding(0, 0, 0, 0)
        background = GradientDrawable().apply { setColor(Color.TRANSPARENT); cornerRadius = dp(12f).toFloat() }
        setOnClickListener { click() }
    }

    private fun attachDrag(handle: View) {
        var downX = 0f; var downY = 0f; var startX = 0; var startY = 0; var dragging = false
        val slop = ViewConfiguration.get(this).scaledTouchSlop
        handle.setOnTouchListener { view, event ->
            val params = windowParams ?: return@setOnTouchListener false
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

    private fun safeBounds(): Rect {
        val metrics = windows.currentWindowMetrics
        val bounds = Rect(metrics.bounds)
        val insets = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        bounds.inset(insets.left + dp(8f), insets.top + dp(8f), insets.right + dp(8f), insets.bottom + dp(8f))
        return bounds
    }

    private fun constrainPosition() {
        val view = root ?: return
        val params = windowParams ?: return
        val safe = safeBounds()
        params.x = params.x.coerceIn(safe.left, maxOf(safe.left, safe.right - view.width.coerceAtLeast(params.width)))
        params.y = params.y.coerceIn(safe.top, maxOf(safe.top, safe.bottom - view.height.coerceAtLeast(dp(64f))))
        windowX = params.x; windowY = params.y
        if (!view.isAttachedToWindow) return
        try { windows.updateViewLayout(view, params) }
        catch (_: RuntimeException) {
            requested = false
            removeOverlay()
            publish(state.copy(overlayRequested = false, overlayVisible = false, error = "悬浮窗已被系统关闭，后台同步继续运行。"))
        }
    }

    private fun removeOverlay() {
        val view = root
        root = null; heading = null; content = null; pageScroll = null; pageButtons = emptyMap(); windowParams = null
        if (view != null) {
            view.visibility = View.GONE
            try { windows.removeViewImmediate(view) } catch (_: RuntimeException) { /* 已被系统移除。 */ }
        }
        if (state.overlayVisible) publish(state.copy(overlayVisible = false))
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(this, 100, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 101, Intent(this, AndroidDisplayService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val connected = latest?.let { it.connected && it.snapshot != null } == true
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_sync_notification)
            .setContentTitle("${getString(R.string.app_name)} · 后台实时同步")
            .setContentText(if (connected) "已连接局域网桌面，等待状态推送" else "等待已配对局域网桌面连接")
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .addAction(Notification.Action.Builder(null, "打开应用", open).build())
            .addAction(Notification.Action.Builder(null, "停止同步", stop).build())
            .build()
    }

    private fun updateNotification() {
        try { getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification()) }
        catch (_: RuntimeException) { /* 通知权限变化不影响安全停止服务或隐藏窗口。 */ }
    }

    private fun dp(value: Float): Int = (value * resources.displayMetrics.density).roundToInt()

    private class BoundedLinearLayout(context: Context) : LinearLayout(context) {
        var maximumHeight = Int.MAX_VALUE
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val supplied = View.MeasureSpec.getSize(heightMeasureSpec)
            val limit = if (View.MeasureSpec.getMode(heightMeasureSpec) == View.MeasureSpec.UNSPECIFIED) maximumHeight else minOf(maximumHeight, supplied)
            super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(limit, View.MeasureSpec.AT_MOST))
        }
    }

    companion object {
        private const val CHANNEL = "loki.background.realtime"
        private const val NOTIFICATION_ID = 7401
        private const val ACTION_START = "com.manonloki.lokimetrisdisplay.REALTIME_START"
        private const val ACTION_STOP = "com.manonloki.lokimetrisdisplay.REALTIME_STOP"
        private const val ACTION_HIDE = "com.manonloki.lokimetrisdisplay.OVERLAY_HIDE"
        private const val EXTRA_OVERLAY = "show_overlay"
        private const val PRESENTATION_PREFERENCES = "overlay_presentation"
        private const val PAGE_KEY = "page_id"
        private val listeners = CopyOnWriteArraySet<(AndroidDisplayServiceState) -> Unit>()
        @Volatile var state = AndroidDisplayServiceState(); private set

        /** 必须由Activity中的用户点击调用，系统限制拒绝启动时转换成可显示反馈。 */
        fun start(context: Context, showOverlay: Boolean) {
            try {
                context.startForegroundService(Intent(context, AndroidDisplayService::class.java).setAction(ACTION_START).putExtra(EXTRA_OVERLAY, showOverlay))
            } catch (_: RuntimeException) {
                publish(state.copy(error = "系统未允许启动后台同步，请在应用内重试。"))
            }
        }

        fun stop(context: Context) {
            if (!context.stopService(Intent(context, AndroidDisplayService::class.java))) publish(AndroidDisplayServiceState())
        }

        /** 只向已运行服务发送指令，不会为了隐藏窗口启动新服务。 */
        fun hideOverlay(context: Context) {
            if (!state.running) return
            try { context.startService(Intent(context, AndroidDisplayService::class.java).setAction(ACTION_HIDE)) }
            catch (_: RuntimeException) { publish(state.copy(error = "暂时无法隐藏悬浮窗，请停止后台同步后重试。")) }
        }

        fun addStateListener(listener: (AndroidDisplayServiceState) -> Unit) {
            listeners.add(listener)
            listener(state)
        }

        fun removeStateListener(listener: (AndroidDisplayServiceState) -> Unit) { listeners.remove(listener) }

        private fun publish(value: AndroidDisplayServiceState) {
            state = value
            for (listener in listeners) listener(value)
        }
    }
}
