package com.manonloki.lokimetrisdisplay

import android.os.Bundle
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Activity只映射应用投影、系统权限与Compose，不拥有密码窗口或socket。 */
class MainActivity : ComponentActivity() {
    private val owner: DisplayApplication get() = application as DisplayApplication
    private var projection by mutableStateOf(AndroidLinkProjection(TerminalLinkView("", "Android 显示端", error = "设备身份暂不可用，请重新打开应用。")))
    private val listener: (AndroidLinkProjection) -> Unit = { projection = it }
    private var panel by mutableStateOf(PanelConfiguration())
    private var permissionPending = false
    private var permissionAttempted = false
    private var pendingRealtime: Boolean? = null
    private var notificationAttempted = false
    private var awaitingOverlay = false
    private var backgroundFeedback by mutableStateOf<String?>(null)
    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permissionPending = false; owner.permissionChanged()
        if (granted) { owner.link?.discover(); pendingRealtime?.let(::startRealtime) }
        else {
            pendingRealtime = null
            projection = projection.copy(view = projection.view.copy(error = "未获得本地网络权限。请在系统设置中允许后重试。"))
        }
    }
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) backgroundFeedback = "通知权限未开启，可在系统设置中开启后查看常驻通知。"
        pendingRealtime?.let { show -> pendingRealtime = null; launchRealtime(show) }
    }
    private val overlayPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val requested = awaitingOverlay; awaitingOverlay = false
        if (requested && Settings.canDrawOverlays(this)) startRealtime(true)
        else if (requested) backgroundFeedback = "尚未允许悬浮窗，请在系统设置中开启。"
    }
    /** 同一应用owner跨Activity复用，预览和设置保存不会触发网络。 */
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(); super.onCreate(savedInstanceState)
        permissionPending = savedInstanceState?.getBoolean("lan.permission_pending") ?: false
        permissionAttempted = savedInstanceState?.getBoolean("lan.permission_attempted") ?: false
        pendingRealtime = savedInstanceState?.takeIf { it.containsKey("background.pending") }?.getBoolean("background.pending")
        notificationAttempted = savedInstanceState?.getBoolean("background.notification_attempted") ?: false
        awaitingOverlay = savedInstanceState?.getBoolean("background.overlay_pending") ?: false
        panel = owner.settings?.panel ?: PanelConfiguration()
        owner.addProjectionListener(listener)
        setContent {
            App(state = projection.view, onSelect = { owner.link?.select(it) }, onForget = { owner.link?.forget(it) },
                onRetry = ::retryConnection, panelConfiguration = panel,
                onSavePanel = { value ->
                    val saved = owner.settings?.savePanel(value) == true
                    if (saved) panel = value
                    saved
                },
                onSaveName = { value ->
                    val saved = owner.settings?.saveName(value) == true
                    if (saved) owner.link?.nameChanged()
                    saved
                }, imageHashes = projection.images.keys, applicationName = getString(R.string.app_name),
                platformSettings = {
                    AndroidBackgroundSettings(owner, onRequestOverlay = ::requestOverlay,
                        onStartRealtime = ::startRealtime,
                        onStopRealtime = { AndroidDisplayService.stop(this); backgroundFeedback = "后台实时同步已关闭，小组件继续按系统周期刷新。" },
                        onPinWidget = {
                            backgroundFeedback = if (MetrisWidgetProvider.requestPin(this)) "请在桌面确认添加小组件。" else "请长按桌面，在“${getString(R.string.app_name)}”中添加小组件。"
                        }, onRefresh = {
                            backgroundFeedback = if (AndroidRefreshScheduler.requestNow(this)) "已申请刷新；桌面在线且局域网可达时更新。" else "刷新任务未能提交，请重试。"
                        }, feedback = backgroundFeedback)
                },
                image = { hash, description, slot ->
                    projection.images[hash]?.get(slot)?.let { hookImage ->
                        AndroidHookImage(hookImage, description)
                    }
                })
        }
    }
    private fun requestOverlay() {
        if (Settings.canDrawOverlays(this)) { startRealtime(true); return }
        awaitingOverlay = true
        try { overlayPermission.launch(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))) }
        catch (_: Exception) { awaitingOverlay = false; backgroundFeedback = "无法打开悬浮窗授权页，请在系统应用设置中允许显示在其他应用上层。" }
    }
    private fun startRealtime(showOverlay: Boolean) {
        if (owner.link == null) { backgroundFeedback = "设备身份暂不可用，请重新打开应用。"; return }
        if (showOverlay && !Settings.canDrawOverlays(this)) { requestOverlay(); return }
        if (!owner.permitted()) { pendingRealtime = showOverlay; retryConnection(); return }
        if (Build.VERSION.SDK_INT >= 33 && !notificationAttempted && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            notificationAttempted = true; pendingRealtime = showOverlay
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS); return
        }
        pendingRealtime = null; launchRealtime(showOverlay)
    }
    private fun launchRealtime(showOverlay: Boolean) {
        backgroundFeedback = null
        runCatching { AndroidDisplayService.start(this, showOverlay) }
            .onFailure { backgroundFeedback = "无法启动后台服务，请保持应用在前台后重试。" }
    }
    /** 首次进入前台完成系统权限，发现随应用生命周期自动运行。 */
    override fun onStart() {
        super.onStart()
        if (!permissionAttempted && !owner.permitted()) retryConnection()
    }
    /** 错误后的重试入口，不暴露开启或停止发现的开关。 */
    private fun retryConnection() {
        if (owner.link == null || permissionPending) return
        if (owner.permitted()) { owner.permissionChanged(); owner.link?.discover() }
        else { permissionAttempted = true; permissionPending = true; permission.launch(DisplayApplication.LOCAL_NETWORK_PERMISSION) }
    }
    /** 精确清除旧视图订阅，连接继续归Application持有。 */
    override fun onDestroy() { owner.removeProjectionListener(listener); super.onDestroy() }
    /** 系统权限对话框正在进行时旋转不再次申请。 */
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("lan.permission_pending", permissionPending)
        outState.putBoolean("lan.permission_attempted", permissionAttempted)
        pendingRealtime?.let { outState.putBoolean("background.pending", it) }
        outState.putBoolean("background.notification_attempted", notificationAttempted)
        outState.putBoolean("background.overlay_pending", awaitingOverlay)
        super.onSaveInstanceState(outState)
    }
}
