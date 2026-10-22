package com.manonloki.lokimetrisdisplay

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowInsetsController
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** 只读系统动画设置；跟随当前界面生命周期，不持有连接 owner。 */
@Composable
internal fun rememberCyberMotionEnabled(): Boolean {
    if (LocalInspectionMode.current) return false
    val resolver = LocalContext.current.contentResolver
    val view = LocalView.current
    SideEffect {
        view.windowInsetsController?.setSystemBarsAppearance(0,
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    /** 系统“动画时长缩放”为 0 时视为关闭动画。 */
    fun animationsAllowed() = Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
    var allowed by remember(resolver) { mutableStateOf(animationsAllowed()) }
    var foreground by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    DisposableEffect(resolver, lifecycle) {
        val settingObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { allowed = animationsAllowed() }
        }
        val lifecycleObserver = LifecycleEventObserver { _, _ ->
            foreground = lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
            if (foreground) allowed = animationsAllowed()
        }
        resolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, settingObserver)
        lifecycle.addObserver(lifecycleObserver)
        onDispose {
            resolver.unregisterContentObserver(settingObserver)
            lifecycle.removeObserver(lifecycleObserver)
        }
    }
    return allowed && foreground
}
