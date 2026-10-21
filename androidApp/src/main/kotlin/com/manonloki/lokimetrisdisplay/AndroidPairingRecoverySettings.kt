package com.manonloki.lokimetrisdisplay

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/** SAF文件由用户选择；恢复码只存在本次界面内存，不写日志、首选项或应用备份。 */
class AndroidPairingRecoveryController(private val activity: ComponentActivity, private val owner: DisplayApplication) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "loki-recovery-file").apply { isDaemon = true } }
    private var exported: AndroidPairingRecovery.Exported? = null
    private var imported: ByteArray? = null
    private var payload: AndroidPairingRecovery.Payload? = null
    var busy by mutableStateOf(false); private set
    var feedback by mutableStateOf<String?>(null); private set
    var dialog by mutableStateOf<String?>(null); private set
    var code by mutableStateOf("")
    var preview by mutableStateOf(""); private set
    private val saveFile = activity.registerForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val value = exported
        if (uri == null || value == null) { busy = false; return@registerForActivityResult }
        busy = true
        worker.execute {
            val success = runCatching {
                activity.contentResolver.openOutputStream(uri, "wt")?.use { it.write(value.bytes); it.flush() }
                    ?: error("recovery_file_unavailable")
            }.isSuccess
            main.post {
                busy = false
                feedback = if (success) "配对恢复文件已保存。请另外妥善保存恢复码，恢复时两者缺一不可。" else "恢复文件保存失败，请重试。"
            }
        }
    }
    private val openFile = activity.registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) readFile(uri)
    }
    fun export() {
        if (busy) return
        val engine = owner.link ?: run { feedback = "设备身份暂不可用。"; return }
        busy = true; feedback = null
        engine.exportPairingRecovery { result ->
            busy = false
            result.onSuccess { exported = it; code = it.recoveryCode; dialog = "export" }
                .onFailure { feedback = "无法导出，请先完成配对并确认私有存储可用。" }
        }
    }
    fun selectFile() { if (!busy) { feedback = null; openFile.launch(arrayOf("application/json", "application/octet-stream", "text/plain")) } }
    private fun readFile(uri: Uri) {
        busy = true
        worker.execute {
            val result = runCatching {
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        check(output.size() + count <= 262144) { "recovery_file_too_large" }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: error("recovery_file_unavailable")
            }
            main.post {
                busy = false
                result.onSuccess { imported = it; code = ""; dialog = "open" }
                    .onFailure { feedback = "无法读取恢复文件，文件上限为256 KiB。" }
            }
        }
    }
    fun unlock() {
        val bytes = imported ?: return
        if (busy) return
        val recoveryCode = code
        busy = true
        worker.execute {
            val result = runCatching { AndroidPairingRecovery.open(bytes, recoveryCode) }
            main.post {
                busy = false
                result.onSuccess {
                    payload = it; preview = "设备 ID：${it.deviceId}\n桌面配对：${it.materials.size} 个\n\n仅能恢复到没有其他配对的安装。恢复旧备份可能包含后来忘记的配对；对端已撤销的授权仍需重新配对。"
                    dialog = "confirm"; code = ""; imported = null
                }.onFailure { feedback = "恢复码不正确，或文件已损坏／不受支持。" }
            }
        }
    }
    fun restore() {
        val value = payload ?: return
        if (busy) return
        busy = true
        owner.restorePairing(value) { success ->
            busy = false; payload = null; dialog = null
            feedback = if (success) "配对已恢复，正在查找原桌面。" else "恢复未完成：已有不同配对或存储不可用。请保留文件和恢复码，检查后重试。"
        }
    }
    fun save() { if (!busy) saveFile.launch("LokiMetris-mobile-pairing.json") }
    fun dismiss() {
        if (busy) return
        exported = null; imported?.fill(0); imported = null; payload = null; code = ""; dialog = null
    }
    fun close() { worker.shutdown(); exported = null; imported?.fill(0); imported = null; payload = null; code = "" }
}

@Composable
fun AndroidPairingRecoverySettings(controller: AndroidPairingRecoveryController) {
    Column(Modifier.fillMaxWidth().testTag("pairing-recovery"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("配对备份与恢复", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(shape = RoundedCornerShape(22.dp), border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.065f))) {
            Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("卸载前保存加密恢复文件和恢复码，重装后可恢复设备身份与配对。它们不包含 Token、Hooks 或图片。", style = MaterialTheme.typography.bodySmall)
                OutlinedButton(controller::export, enabled = !controller.busy, modifier = Modifier.fillMaxWidth()) { Text("导出配对恢复文件") }
                OutlinedButton(controller::selectFile, enabled = !controller.busy, modifier = Modifier.fillMaxWidth()) { Text("导入配对恢复文件") }
                controller.feedback?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }
    controller.dialog?.let { mode ->
        AlertDialog(onDismissRequest = controller::dismiss,
            title = { Text(when (mode) { "export" -> "保存恢复码"; "confirm" -> "确认恢复配对"; else -> "输入恢复码" }) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (mode == "confirm") Text(controller.preview)
                    else if (mode == "export") {
                        Text("请将恢复码与文件分开妥善保管。持有两者的人可以恢复这份配对。")
                        SelectionContainer { Text(controller.code) }
                    } else OutlinedTextField(controller.code, { controller.code = it }, label = { Text("恢复码") },
                        visualTransformation = PasswordVisualTransformation(), enabled = !controller.busy, modifier = Modifier.fillMaxWidth())
                    controller.feedback?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                }
            },
            confirmButton = {
                Button(onClick = { when (mode) { "export" -> controller.save(); "confirm" -> controller.restore(); else -> controller.unlock() } }, enabled = !controller.busy) {
                    Text(when (mode) { "export" -> "保存加密文件"; "confirm" -> "恢复此设备配对"; else -> "解密并预览" })
                }
            }, dismissButton = { TextButton(controller::dismiss, enabled = !controller.busy) { Text(if (mode == "export") "完成" else "取消") } })
    }
}
