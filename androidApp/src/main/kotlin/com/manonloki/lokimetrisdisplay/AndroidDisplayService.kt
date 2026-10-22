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
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Display
import android.view.WindowManager
import java.util.concurrent.CopyOnWriteArraySet

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
    private var latest: TerminalLinkView? = null
    private var requested = false
    private var overlay: AndroidOverlayWindow? = null
    private var overlayPosition = Point()
    private var notifiedConnected: Boolean? = null
    private var receiverRegistered = false
    private var observingOps = false
    private var connectionOwned = false
    private var shuttingDown = false
    private var terminalError: String? = null
    private val projectionListener: (AndroidLinkProjection) -> Unit = { projection ->
        latest = projection.view
        overlay?.render(latest)
        // 通知只反映连接与否，逐次推送不重建通知，减少系统通知服务调用。
        if (state.running && connected() != notifiedConnected) updateNotification()
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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowContext = createWindowContext(
            getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null,
        )
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
            // 撤权仍由窗口操作异常、亮屏解锁广播和配置变化兜底，不轮询以免持续唤醒。
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
        if (overlay != null) return
        createOverlay()
    }

    private fun connected(): Boolean = latest?.let { it.connected && it.snapshot != null } == true

    private fun createOverlay() {
        val window = AndroidOverlayWindow(windowContext, "${getString(R.string.app_name)} 状态悬浮窗", overlayPosition,
            onClose = {
                requested = false
                removeOverlay()
                publish(state.copy(overlayRequested = false, overlayVisible = false, error = null))
                updateNotification()
            },
            onLost = { dropOverlay("悬浮窗已被系统关闭，后台同步继续运行。") },
        )
        overlay = window
        window.render(latest)
        try {
            // 权限、锁屏状态在创建前再检查一次，避免广播和绘制之间的窗口。
            if (!Settings.canDrawOverlays(this) || !mayShow()) { removeOverlay(); return }
            window.show()
            publish(state.copy(overlayRequested = requested, overlayVisible = true, error = null))
        } catch (_: RuntimeException) {
            dropOverlay("系统暂未允许显示悬浮窗，后台同步继续运行。")
        }
    }

    /** 系统拒绝或移除窗口时放弃显示意图，后台连接不受影响。 */
    private fun dropOverlay(message: String) {
        requested = false
        removeOverlay()
        publish(state.copy(overlayRequested = false, overlayVisible = false, error = message))
    }

    private fun removeOverlay() {
        overlay?.let { overlayPosition = it.position; it.remove() }
        overlay = null
        if (state.overlayVisible) publish(state.copy(overlayVisible = false))
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(this, 100, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 101, Intent(this, AndroidDisplayService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val connected = connected()
        notifiedConnected = connected
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

    companion object {
        private const val CHANNEL = "loki.background.realtime"
        private const val NOTIFICATION_ID = 7401
        private const val ACTION_START = "com.manonloki.lokimetrisdisplay.REALTIME_START"
        private const val ACTION_STOP = "com.manonloki.lokimetrisdisplay.REALTIME_STOP"
        private const val ACTION_HIDE = "com.manonloki.lokimetrisdisplay.OVERLAY_HIDE"
        private const val EXTRA_OVERLAY = "show_overlay"
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

        /** 停止服务；服务未在运行时也重置共享状态，避免界面停留在旧状态。 */
        fun stop(context: Context) {
            if (!context.stopService(Intent(context, AndroidDisplayService::class.java))) publish(AndroidDisplayServiceState())
        }

        /** 只向已运行服务发送指令，不会为了隐藏窗口启动新服务。 */
        fun hideOverlay(context: Context) {
            if (!state.running) return
            try { context.startService(Intent(context, AndroidDisplayService::class.java).setAction(ACTION_HIDE)) }
            catch (_: RuntimeException) { publish(state.copy(error = "暂时无法隐藏悬浮窗，请停止后台同步后重试。")) }
        }

        /** 订阅服务状态，注册时立即回放当前值。 */
        fun addStateListener(listener: (AndroidDisplayServiceState) -> Unit) {
            listeners.add(listener)
            listener(state)
        }

        /** 精确移除订阅，不影响其他界面。 */
        fun removeStateListener(listener: (AndroidDisplayServiceState) -> Unit) { listeners.remove(listener) }

        private fun publish(value: AndroidDisplayServiceState) {
            state = value
            for (listener in listeners) listener(value)
        }
    }
}
