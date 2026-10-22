package com.manonloki.lokimetrisdisplay

import android.content.Context
import java.io.File
import java.nio.file.Files

/** 清理旧版完整 Token/Hooks 快照；前台完整展示仅驻内存，小组件裁剪摘要、图片及配对分别存储。 */
class AndroidDisplayStore(context: Context) {
    private val directory = context.filesDir
    /** 精确删除旧快照及AtomicFile遗留文件，不遍历目录、不跟随链接或删除图片。 */
    fun discardLegacy() {
        for (name in listOf("lan-display-v1.json", "lan-display-v1.json.new", "lan-display-v1.json.bak")) {
            val file = File(directory, name)
            check(!file.isDirectory || Files.isSymbolicLink(file.toPath()))
            Files.deleteIfExists(file.toPath())
        }
    }
}
