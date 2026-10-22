package com.manonloki.lokimetrisdisplay

import java.io.ByteArrayOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.PosixFilePermissions
import java.util.Properties
import java.util.UUID

/** 本机身份与面板偏好保存在用户私有目录；构造参数允许测试使用独立临时目录。 */
class DesktopDeviceSettings(val directory: Path = desktopDataDirectory()) {
    private val file = directory.resolve("settings.properties")
    val deviceId: String
    @Volatile var name: String; private set
    @Volatile var panel: PanelConfiguration; private set

    init {
        prepareDirectory()
        val values = Properties()
        if (Files.exists(file, NOFOLLOW_LINKS)) {
            check(Files.isRegularFile(file, NOFOLLOW_LINKS) && Files.size(file) <= MAX_BYTES) { "desktop_settings_invalid" }
            try { Files.newInputStream(file, NOFOLLOW_LINKS).use(values::load) }
            catch (_: Exception) { error("desktop_settings_invalid") }
            // 既有身份损坏时显式失败，不能生成新 UUID 隐瞒已配对设备的身份丢失。
            check(MdnsProtocol.isCanonicalDeviceId(values.getProperty("device_id", ""))) { "device_identity_invalid" }
        }
        deviceId = values.getProperty("device_id") ?: UUID.randomUUID().toString()
        name = values.getProperty("device_name")?.takeIf { MdnsProtocol.nameError(it) == null } ?: "Desktop 显示端"
        panel = PanelConfiguration.restore(
            values.getProperty("panel.show_usage")?.toBooleanStrictOrNull() ?: true,
            values.getProperty("panel.show_hooks")?.toBooleanStrictOrNull() ?: true,
            values.getProperty("panel.usage_detail"), values.getProperty("panel.hook_layout"),
        )
        check(persist(name, panel)) { "desktop_settings_unavailable" }
    }

    /** 完整原子提交成功后才发布新名称，失败保持原内存值。 */
    @Synchronized fun saveName(value: String): Boolean {
        if (MdnsProtocol.nameError(value) != null || !persist(value, panel)) return false
        name = value
        return true
    }

    /** 布局与身份一起提交，窗口重建不会改变设备身份。 */
    @Synchronized fun savePanel(value: PanelConfiguration): Boolean {
        if (!persist(name, value)) return false
        panel = value
        return true
    }

    private fun prepareDirectory() {
        Files.createDirectories(directory)
        check(Files.isDirectory(directory, NOFOLLOW_LINKS) && !Files.isSymbolicLink(directory)) { "desktop_settings_directory_invalid" }
        ownerOnly(directory, directory = true)
    }

    private fun persist(nextName: String, nextPanel: PanelConfiguration): Boolean {
        var temporary: Path? = null
        return try {
            prepareDirectory()
            check(!Files.exists(file, NOFOLLOW_LINKS) || Files.isRegularFile(file, NOFOLLOW_LINKS))
            val values = Properties().apply {
                setProperty("device_id", deviceId)
                setProperty("device_name", nextName)
                setProperty("panel.show_usage", nextPanel.showUsage.toString())
                setProperty("panel.show_hooks", nextPanel.showHooks.toString())
                setProperty("panel.usage_detail", nextPanel.usageDetail.key)
                setProperty("panel.hook_layout", nextPanel.hookLayout.key)
            }
            val bytes = ByteArrayOutputStream().use { output ->
                values.store(output, "LokiMetris Desktop display settings")
                output.toByteArray()
            }
            check(bytes.size <= MAX_BYTES)
            temporary = Files.createTempFile(directory, ".settings-", ".tmp")
            ownerOnly(temporary, directory = false)
            FileChannel.open(temporary, WRITE).use { output ->
                val buffer = java.nio.ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) output.write(buffer)
                output.force(true)
            }
            // 不支持同目录原子替换时失败并保留旧文件，避免留下半份身份记录。
            Files.move(temporary, file, ATOMIC_MOVE, REPLACE_EXISTING)
            temporary = null
            true
        } catch (_: Exception) { false }
        finally { temporary?.let { runCatching { Files.deleteIfExists(it) } } }
    }

    private fun ownerOnly(path: Path, directory: Boolean) {
        if (Files.getFileAttributeView(path, java.nio.file.attribute.PosixFileAttributeView::class.java, NOFOLLOW_LINKS) != null) {
            Files.setPosixFilePermissions(path, PosixFilePermissions.fromString(if (directory) "rwx------" else "rw-------"))
        }
    }

    private companion object { const val MAX_BYTES = 65_536L }
}

/** 遵循各桌面系统的用户数据目录，不依赖当前工作目录。 */
fun desktopDataDirectory(): Path {
    val home = Path.of(System.getProperty("user.home"))
    val os = System.getProperty("os.name").lowercase()
    return when {
        os.contains("mac") -> home.resolve("Library/Application Support/LokiMetrisDisplay")
        os.contains("win") -> System.getenv("LOCALAPPDATA")?.takeIf { it.isNotBlank() }?.let(Path::of)
            ?.resolve("LokiMetrisDisplay") ?: home.resolve("AppData/Local/LokiMetrisDisplay")
        else -> System.getenv("XDG_DATA_HOME")?.takeIf { it.isNotBlank() }?.let(Path::of)?.takeIf { it.isAbsolute }
            ?.resolve("LokiMetrisDisplay") ?: home.resolve(".local/share/LokiMetrisDisplay")
    }
}
