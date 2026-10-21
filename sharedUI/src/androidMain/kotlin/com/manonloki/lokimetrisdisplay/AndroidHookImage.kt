package com.manonloki.lokimetrisdisplay

import android.graphics.drawable.Animatable
import android.graphics.drawable.Drawable
import android.widget.ImageView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** 每个卡片拥有独立Drawable实例；离开面板或进入后台会暂停动画。 */
@Composable
fun AndroidHookImage(drawable: Drawable, description: String) {
    val image = drawable
    // 详情与卡片交接时先让旧 ImageView 完整释放，再绑定同一槽位的 Drawable。
    var ready by remember(image) { mutableStateOf(false) }
    LaunchedEffect(image) { withFrameNanos { }; ready = true }
    if (!ready) return
    val owner = LocalLifecycleOwner.current
    var visible by remember { mutableStateOf(false) }
    val playbackAllowed = LocalCyberMotion.current && visible
    DisposableEffect(image, owner, playbackAllowed) {
        if (playbackAllowed && owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) (image as? Animatable)?.start()
        else (image as? Animatable)?.stop()
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START && playbackAllowed) (image as? Animatable)?.start()
            if (event == Lifecycle.Event.ON_STOP) (image as? Animatable)?.stop()
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer); (image as? Animatable)?.stop() }
    }
    AndroidView(
        factory = { context -> ImageView(context).apply { scaleType = ImageView.ScaleType.FIT_CENTER } },
        modifier = Modifier.fillMaxSize().clipToBounds().onGloballyPositioned { visible = !it.boundsInWindow().isEmpty },
        onReset = null,
        onRelease = { view ->
            (view.drawable as? Animatable)?.stop()
            view.setImageDrawable(null)
        },
        update = { view ->
            view.contentDescription = description
            if (view.drawable !== image) view.setImageDrawable(image)
            if (playbackAllowed && owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) (image as? Animatable)?.start()
            else (image as? Animatable)?.stop()
        }
    )
}
