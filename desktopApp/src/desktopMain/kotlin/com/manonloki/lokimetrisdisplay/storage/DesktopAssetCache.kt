package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.util.Base64
import java.io.FileOutputStream

/** 摘要寻址、有界分块与完整 Rust 校验；未验证资源不会进入桌面图像投影。 */
class DesktopAssetCache(root: Path) : AutoCloseable {
    private val directory = root.resolve("lan-assets-v1")
    private var temporary: Path? = null
    private var stream: FileOutputStream? = null
    private var descriptor: JSONObject? = null
    private var settledKeeping: Set<String>? = null
    init {
        desktopPrivateDirectory(directory)
        Files.newDirectoryStream(directory).use { files -> files.forEach { path ->
            val name = path.fileName.toString()
            if (name.startsWith(".asset-") && name.endsWith(".tmp") && Files.isRegularFile(path, NOFOLLOW_LINKS) &&
                System.currentTimeMillis() - Files.getLastModifiedTime(path, NOFOLLOW_LINKS).toMillis() > 86_400_000L) Files.deleteIfExists(path)
        } }
    }
    private fun file(value: JSONObject): Path {
        TerminalAsset(value.string("hash"), value.string("mime"), value.long("length")).validate()
        val path = directory.resolve(value.string("hash"))
        check(Files.isDirectory(directory, NOFOLLOW_LINKS) && (!Files.exists(path, NOFOLLOW_LINKS) || Files.isRegularFile(path, NOFOLLOW_LINKS)))
        return path
    }
    fun cached(value: JSONObject, bridge: NativeLinkBridge): ByteArray? {
        val path = file(value)
        if (!Files.isRegularFile(path, NOFOLLOW_LINKS) || Files.size(path) != value.long("length")) return null
        val bytes = Files.readAllBytes(path)
        return if (bridge.validAsset(value, bytes)) bytes.also { path.toFile().setLastModified(System.currentTimeMillis()) } else null
    }
    fun begin(value: JSONObject, bridge: NativeLinkBridge) {
        close(); file(value)
        bridge.call(JSONObject().put("op", "assetBegin").put("descriptor", value))
        val path = Files.createTempFile(directory, ".asset-", ".tmp")
        temporary = path
        try { desktopOwnerOnly(path, false); stream = FileOutputStream(path.toFile()); descriptor = value }
        catch (error: Exception) { close(); throw error }
    }
    fun accept(chunk: JSONObject, bridge: NativeLinkBridge): Pair<ByteArray?, Long> {
        val value = requireNotNull(descriptor)
        require(chunk.string("hash") == value.string("hash") && chunk.string("data").length <= 21848)
        val result = try { bridge.call(JSONObject().put("op", "assetChunk").put("chunk", chunk)) }
        catch (error: Exception) { close(); throw error }
        val output = requireNotNull(stream)
        try {
            val bytes = Base64.getDecoder().decode(chunk.string("data"))
            require(bytes.size <= 16384)
            output.write(bytes)
            val complete = if (result.bool("complete")) {
                output.fd.sync(); output.close(); stream = null
                val path = requireNotNull(temporary)
                check(Files.size(path) == value.long("length"))
                val body = Files.readAllBytes(path)
                check(bridge.validAsset(value, body))
                Files.move(path, file(value), ATOMIC_MOVE, REPLACE_EXISTING)
                temporary = null; descriptor = null; settledKeeping = null
                body
            } else null
            return complete to result.long("offset")
        } catch (error: Exception) { close(); throw error }
    }
    fun prune(keeping: Set<String>) {
        if (keeping == settledKeeping) return
        val entries = Files.newDirectoryStream(directory).use { files -> files.filter {
            desktopValidHash(it.fileName.toString()) && Files.isRegularFile(it, NOFOLLOW_LINKS)
        }.map { ImageCacheEntry(it.fileName.toString(), Files.size(it), Files.getLastModifiedTime(it).toMillis().toDouble()) } }
        val plan = ImageCachePolicy.plan(entries, keeping)
        var occupancy = plan.occupancy; var settled = true
        for (entry in plan.candidates) {
            if (!ImageCachePolicy.shouldEvict(occupancy, ImageCacheProfile.ANDROID)) break
            if (runCatching { Files.deleteIfExists(directory.resolve(entry.key)) }.getOrDefault(false)) occupancy = ImageCachePolicy.removed(occupancy, entry)
            else settled = false
        }
        settledKeeping = if (settled) keeping.toSet() else null
    }
    override fun close() {
        runCatching { stream?.close() }; stream = null
        temporary?.let { runCatching { Files.deleteIfExists(it) } }; temporary = null; descriptor = null
    }
}
