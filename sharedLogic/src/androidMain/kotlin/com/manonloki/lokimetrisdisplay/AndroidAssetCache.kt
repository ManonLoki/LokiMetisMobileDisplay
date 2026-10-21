package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.graphics.ImageDecoder
import android.graphics.drawable.Drawable
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files

/** 应用私有内容缓存；核心验证块顺序、完整摘要和魔数，磁盘结果还需提交后复核。 */
class AndroidAssetCache(context: Context) : AutoCloseable {
    private val directory = File(context.filesDir, "lan-assets-v1").apply { check(mkdirs() || isDirectory); check(!Files.isSymbolicLink(toPath())) }
    private var pending: AtomicFile? = null
    private var stream: FileOutputStream? = null
    private var descriptor: JSONObject? = null
    init {
        // 仅回收本缓存确切hash的AtomicFile临时文件，不扫描或删除其它私有目录。
        directory.listFiles()?.filter { it.name.endsWith(".new") && validHash(it.name.removeSuffix(".new")) && !Files.isSymbolicLink(it.toPath()) && it.isFile }?.forEach { it.delete() }
    }
    /** 摘要只可作为固定单层文件名，AtomicFile辅助文件也拒绝链接。 */
    private fun file(value: JSONObject): File {
        val hash = value.string("hash"); val length = value.long("length")
        require(validHash(hash) && length in 1..33_554_432L)
        val path = File(directory, hash)
        listOf(directory, path, File(directory, "$hash.new"), File(directory, "$hash.bak")).forEach { check(!Files.isSymbolicLink(it.toPath())) }
        check(!path.exists() || path.isFile) { "asset_storage_conflict" }
        return path
    }
    /** 命中必须验证实际正文，缓存损坏按缺失补取，不删除仍有效旧文件。 */
    fun cached(value: JSONObject, bridge: NativeLinkBridge): File? {
        val path = file(value)
        if (!path.isFile || path.length() != value.long("length")) return null
        return path.takeIf { bridge.validAsset(value, path.readBytes()) }?.also { it.setLastModified(System.currentTimeMillis()) }
    }
    /** 新资源前取消旧部分文件；调用方保证一次只请求一个资源。 */
    fun begin(value: JSONObject, bridge: NativeLinkBridge) {
        close(); val path = file(value)
        bridge.call(JSONObject().put("op", "assetBegin").put("descriptor", value))
        val atomic = AtomicFile(path); val output = atomic.startWrite()
        pending = atomic; stream = output; descriptor = value
    }
    /** 共享核心校验先于磁盘写，最终落盘字节再次验证后才能被UI复用。 */
    fun accept(chunk: JSONObject, bridge: NativeLinkBridge): Pair<Boolean, Long> {
        val value = checkNotNull(descriptor)
        check(chunk.string("hash") == value.string("hash") && chunk.string("data").length <= 21848)
        val result = try { bridge.call(JSONObject().put("op", "assetChunk").put("chunk", chunk)) }
            catch (error: Exception) { close(); throw error }
        val output = checkNotNull(stream)
        try {
            output.write(Base64.decode(chunk.string("data"), Base64.NO_WRAP))
            if (result.bool("complete")) {
                checkNotNull(pending).finishWrite(output)
                check(cached(value, bridge) != null) { "asset_storage_unavailable" }
                pending = null; stream = null; descriptor = null
            }
        } catch (error: Exception) { close(); throw error }
        return result.bool("complete") to result.long("offset")
    }
    /** 系统解码器保留GIF/WebP动画，目标像素有界且不在UI重组时读盘。 */
    fun thumbnail(path: File): Drawable? = try {
        ImageDecoder.decodeDrawable(ImageDecoder.createSource(path)) { decoder, info, _ ->
            val width = info.size.width; val height = info.size.height
            require(width > 0 && height > 0 && width.toLong() * height <= 16_777_216L)
            val scale = minOf(1.0, 512.0 / maxOf(width, height))
            decoder.setTargetSize(maxOf(1, (width * scale).toInt()), maxOf(1, (height * scale).toInt()))
        }
    } catch (_: Exception) { null }
    /** 当前引用优先保留，其余按最近复用时间限制到512MiB及512个文件。 */
    fun prune(keeping: Set<String>) {
        val files = directory.listFiles()?.filter { validHash(it.name) && it.isFile && !Files.isSymbolicLink(it.toPath()) } ?: return
        var bytes = files.sumOf { it.length() }; var count = files.size
        for (path in files.sortedBy { it.lastModified() }) {
            if (bytes <= 512L * 1024 * 1024 && count <= 512) break
            if (path.name !in keeping) { val size = path.length(); if (path.delete()) { bytes -= size; count-- } }
        }
    }
    /** 网络失败只撤销未完成AtomicFile，已经完成的缓存继续可离线显示。 */
    override fun close() { stream?.let { pending?.failWrite(it) }; pending = null; stream = null; descriptor = null }
}
