package com.manonloki.lokimetrisdisplay

import android.os.Bundle
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
    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permissionPending = false; owner.permissionChanged()
        if (granted) owner.link?.discover()
        else projection = projection.copy(view = projection.view.copy(error = "未获得本地网络权限。请在系统设置中允许后重试。"))
    }
    /** 同一应用owner跨Activity复用，预览和设置保存不会触发网络。 */
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(); super.onCreate(savedInstanceState)
        permissionPending = savedInstanceState?.getBoolean("lan.permission_pending") ?: false
        permissionAttempted = savedInstanceState?.getBoolean("lan.permission_attempted") ?: false
        panel = owner.settings?.panel ?: PanelConfiguration()
        owner.link?.setListener(listener)
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
                }, imageHashes = projection.images.keys,
                image = { hash, description, slot ->
                    projection.images[hash]?.get(slot)?.let { hookImage ->
                        AndroidHookImage(hookImage, description)
                    }
                })
        }
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
    override fun onDestroy() { owner.link?.clearListener(listener); super.onDestroy() }
    /** 系统权限对话框正在进行时旋转不再次申请。 */
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("lan.permission_pending", permissionPending)
        outState.putBoolean("lan.permission_attempted", permissionAttempted)
        super.onSaveInstanceState(outState)
    }
}
