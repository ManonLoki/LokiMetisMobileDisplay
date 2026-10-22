package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import java.awt.Dimension
import java.nio.file.Path
import java.util.Locale
import org.jetbrains.skia.Image

/** 一个进程持有一个连接 owner；切页、缩放、失焦和最小化都不会重新开启配对。 */
fun main() = application {
    val startup = remember {
        runCatching {
            val directory = System.getProperty("loki.desktop.dataDir")?.let(Path::of) ?: desktopDataDirectory()
            val settings = DesktopDeviceSettings(directory)
            settings to DesktopLanEngine(settings)
        }
    }
    val windowState = rememberWindowState(width = 1280.dp, height = 800.dp)
    val icon = remember {
        object {}.javaClass.getResourceAsStream("/icons/app-icon.png")?.use { stream ->
            Image.makeFromEncoded(stream.readBytes()).use { BitmapPainter(it.toComposeImageBitmap()) }
        }
    }
    val applicationName = if (Locale.getDefault().language == "zh") "诡秘神谕 · 展示终端" else "LokiMetris Display"
    Window(onCloseRequest = ::exitApplication, state = windowState, title = applicationName, icon = icon) {
        SideEffect { window.minimumSize = Dimension(640, 480) }
        val owner = startup.getOrNull()
        if (owner != null) {
            val (settings, engine) = owner
            var projection by remember { mutableStateOf(engine.state) }
            var panel by remember { mutableStateOf(settings.panel) }
            DisposableEffect(engine) {
                engine.setListener { projection = it }
                onDispose { engine.close() }
            }
            App(
                state = projection.view,
                onSelect = engine::select, onForget = engine::forget,
                onSaveName = { name -> settings.saveName(name).also { if (it) engine.nameChanged() } },
                onRetry = engine::discover,
                panelConfiguration = panel,
                onSavePanel = { value -> settings.savePanel(value).also { if (it) panel = value } },
                imageHashes = projection.images.keys,
                applicationName = applicationName,
                motionEnabled = desktopMotionEnabled(window.isVisible, windowState.isMinimized),
                quotaTimestamp = ::quotaTimestamp,
                image = { hash, description, _ -> projection.images[hash]?.let { DesktopHookImage(it, description) } },
            )
        } else DesktopStartupError()
    }
}

/** 身份存储异常时不生成临时身份，也不把异常正文中的本机路径展示给用户。 */
@Composable
private fun DesktopStartupError() {
    MaterialTheme(colorScheme = darkColorScheme(background = Color(0xFF080D17))) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.padding(40.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("无法打开展示终端", style = MaterialTheme.typography.headlineMedium)
                Text("本机身份或数据目录暂不可用。请检查用户数据目录的读写权限后重新打开应用。")
                Text("已有配对数据会保留；应用不会自动重置设备身份。", style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}
