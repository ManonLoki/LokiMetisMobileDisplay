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
    /** 上次完整收敛时保留的引用集；引用不变且没有新文件落盘时无需重新扫描目录。 */
    private var settledKeeping: Set<String>? = null
    init {
        // 仅回收本缓存确切hash的AtomicFile临时文件，不扫描或删除其它私有目录。
        directory.listFiles()?.filter { it.name.endsWith(".new") && validHash(it.name.removeSuffix(".new")) && !Files.isSymbolicLink(it.toPath()) && it.isFile }?.forEach { it.delete() }
    }
    /** 摘要只可作为固定单层文件名，AtomicFile辅助文件也拒绝链接。 */
    private fun file(value: JSONObject): File {
        val hash = value.string("hash")
        TerminalAsset(hash, value.string("mime"), value.long("length")).validate()
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
    /** 共享核心校验先于磁盘写，最终落盘字节再次验证后才能被UI复用；完成时返回已核验路径，调用方无需再读盘复核。 */
    fun accept(chunk: JSONObject, bridge: NativeLinkBridge): Pair<File?, Long> {
        val value = checkNotNull(descriptor)
        check(chunk.string("hash") == value.string("hash") && chunk.string("data").length <= 21848)
        val result = try { bridge.call(JSONObject().put("op", "assetChunk").put("chunk", chunk)) }
            catch (error: Exception) { close(); throw error }
        val output = checkNotNull(stream)
        val verified = try {
            output.write(Base64.decode(chunk.string("data"), Base64.NO_WRAP))
            if (result.bool("complete")) {
                checkNotNull(pending).finishWrite(output)
                checkNotNull(cached(value, bridge)) { "asset_storage_unavailable" }
                    .also { pending = null; stream = null; descriptor = null; settledKeeping = null }
            } else null
        } catch (error: Exception) { close(); throw error }
        return verified to result.long("offset")
    }
    /** 系统解码器保留GIF/WebP动画，目标像素有界且不在UI重组时读盘。 */
    fun thumbnail(path: File): Drawable? = try {
        ImageDecoder.decodeDrawable(ImageDecoder.createSource(path)) { decoder, info, _ ->
            val target = requireNotNull(ImageDecodePolicy.androidTargetSize(info.size.width, info.size.height))
            decoder.setTargetSize(target.width, target.height)
        }
    } catch (_: Exception) { null }
    /** 当前引用优先保留，其余按最近复用时间限制到512MiB及512个文件。 */
    fun prune(keeping: Set<String>) {
        if (keeping == settledKeeping) return
        val files = directory.listFiles()?.filter { validHash(it.name) && it.isFile && !Files.isSymbolicLink(it.toPath()) } ?: return
        val plan = ImageCachePolicy.plan(files.map { ImageCacheEntry(it.name, it.length(), it.lastModified().toDouble()) }, keeping)
        var occupancy = plan.occupancy; var settled = true
        for (entry in plan.candidates) {
            if (!ImageCachePolicy.shouldEvict(occupancy, ImageCacheProfile.ANDROID)) break
            if (File(directory, entry.key).delete()) occupancy = ImageCachePolicy.removed(occupancy, entry)
            else settled = false
        }
        settledKeeping = if (settled) keeping else null
    }
    /** 网络失败只撤销未完成AtomicFile，已经完成的缓存继续可离线显示。 */
    override fun close() { stream?.let { pending?.failWrite(it) }; pending = null; stream = null; descriptor = null }
}
