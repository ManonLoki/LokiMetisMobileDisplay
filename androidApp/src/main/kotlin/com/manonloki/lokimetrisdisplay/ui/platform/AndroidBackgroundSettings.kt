package com.manonloki.lokimetrisdisplay

import android.provider.Settings
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** 基础设置下方的整行分组；三张卡片按可用宽度和字号排为一至三列。 */
@Composable
fun AndroidBackgroundSettings(
    owner: DisplayApplication,
    onRequestOverlay: () -> Unit,
    onStartRealtime: (Boolean) -> Unit,
    onStopRealtime: () -> Unit,
    onPinWidget: () -> Unit,
    onRefresh: () -> Unit,
    feedback: String? = null,
) {
    var service by remember { mutableStateOf(AndroidDisplayService.state) }
    var overlayAllowed by remember { mutableStateOf(Settings.canDrawOverlays(owner)) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(owner, lifecycle) {
        val listener: (AndroidDisplayServiceState) -> Unit = {
            service = it
            overlayAllowed = Settings.canDrawOverlays(owner)
        }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                overlayAllowed = Settings.canDrawOverlays(owner)
                service = AndroidDisplayService.state
            }
        }
        AndroidDisplayService.addStateListener(listener)
        lifecycle.addObserver(observer)
        onDispose {
            AndroidDisplayService.removeStateListener(listener)
            lifecycle.removeObserver(observer)
        }
    }
    val fontScale = LocalDensity.current.fontScale.coerceAtLeast(1f)
    Column(Modifier.fillMaxWidth().testTag("android-background-settings"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("小组件与后台", fontSize = 13.sp, lineHeight = 19.sp, fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp))
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val gap = 16.dp
            val columns = ((maxWidth + gap) / (300.dp * fontScale + gap)).toInt().coerceIn(1, 3)
            val cards = listOf<@Composable (Modifier) -> Unit>(
                { modifier -> BackgroundSettingsCard("桌面小组件", modifier) {
                    Detail("在主屏幕查看 Token 和 Hooks。每次同步会更新小组件，并显示上次同步时间；也可点击小组件打开应用。")
                    Detail("普通后台刷新建议间隔为 15 分钟。实际时机会受系统省电、网络与厂商限制，无法保证每 15 分钟执行；桌面需在同一局域网并保持可连接。")
                    Spacer(Modifier.weight(1f))
                    OutlinedButton(onClick = onPinWidget, modifier = actionModifier("android-pin-widget")) {
                        Text("添加小组件", textAlign = TextAlign.Center)
                    }
                    OutlinedButton(onClick = onRefresh, modifier = actionModifier("android-refresh-widget")) {
                        Text("立即同步", textAlign = TextAlign.Center)
                    }
                } },
                { modifier -> BackgroundSettingsCard("后台实时同步", modifier) {
                    Detail(if (service.running) "已开启 · 持续通知中可停止。等待已配对桌面的局域网推送，断线后自动等待重连。"
                        else "开启后通过持续通知保持局域网连接，接收桌面推送。仅连接已配对桌面，系统结束进程或重启后需手动开启。")
                    Detail("比普通后台刷新更耗电；系统休眠或厂商省电仍可能暂停网络。")
                    Spacer(Modifier.weight(1f))
                    if (service.running) {
                        OutlinedButton(onClick = onStopRealtime, modifier = actionModifier("android-stop-realtime")) {
                            Text("停止后台实时同步", textAlign = TextAlign.Center)
                        }
                    } else {
                        Button(onClick = { onStartRealtime(false) }, modifier = actionModifier("android-start-realtime")) {
                            Text("开启后台实时同步", textAlign = TextAlign.Center)
                        }
                    }
                } },
                { modifier -> BackgroundSettingsCard("悬浮窗", modifier) {
                    Detail(when {
                        !overlayAllowed -> "需要系统的“显示在其他应用上层”权限。授权后可在其他应用上方查看实时状态。"
                        service.overlayVisible -> "正在显示 · 左右滑动或点击切换 Token 与 Hooks，拖动标题可移动，× 关闭窗口并继续后台同步。"
                        service.overlayRequested -> "锁屏期间已隐藏，解锁后恢复。"
                        else -> "已授权 · 显示时同步开启后台实时连接。锁屏隐藏，关闭窗口后可继续后台同步。"
                    })
                    Spacer(Modifier.weight(1f))
                    when {
                        !overlayAllowed -> OutlinedButton(onClick = onRequestOverlay, modifier = actionModifier("android-overlay-permission")) {
                            Text("授权悬浮窗", textAlign = TextAlign.Center)
                        }
                        service.overlayRequested -> OutlinedButton(onClick = { AndroidDisplayService.hideOverlay(owner) }, modifier = actionModifier("android-hide-overlay")) {
                            Text("隐藏悬浮窗", textAlign = TextAlign.Center)
                        }
                        else -> Button(onClick = { onStartRealtime(true) }, modifier = actionModifier("android-show-overlay")) {
                            Text("显示悬浮窗", textAlign = TextAlign.Center)
                        }
                    }
                } },
            )
            Column(verticalArrangement = Arrangement.spacedBy(gap)) {
                cards.chunked(columns).forEach { row ->
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(gap)) {
                        row.forEach { card -> card(Modifier.weight(1f).fillMaxHeight()) }
                    }
                }
            }
        }
        (service.error ?: feedback)?.let {
            Text(it, fontSize = 12.sp, lineHeight = 18.sp,
                color = if (service.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp).testTag("android-background-feedback"))
        }
    }
}

/** 同行卡片等高，内容和按钮随字号增长，不给卡片设固定高度。 */
@Composable
private fun BackgroundSettingsCard(title: String, modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(modifier, shape = RoundedCornerShape(22.dp), color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.065f))) {
        Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 22.sp)
            content()
        }
    }
}

private fun actionModifier(tag: String): Modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag)

@Composable
private fun Detail(value: String) {
    Text(value, fontSize = 12.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
