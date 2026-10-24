package com.manonloki.lokimetrisdisplay.protocol

/** 只比较完整元信息；宿主以规范 u64 十进制传递长度，不经有符号或浮点数截断。 */
data class AssetTransferDescriptor(val hash: String, val mime: String, val byteLength: String)
data class AssetTransferManifest(val assets: List<AssetTransferDescriptor>, val referencedHashes: Set<String>)

/** 已验证清单的引用资格与候选位置；格式验证、缓存命中、解码和传输 owner 仍归宿主。 */
object AssetTransferRules {
    /** null 表示没有图片负载，原 Watch 快照传输可继续提交。 */
    fun keepInFlight(asset: AssetTransferDescriptor?, latest: AssetTransferManifest): Boolean =
        asset == null || asset.hash in latest.referencedHashes && asset in latest.assets

    /** 保持原清单顺序和位置；不排序、不去重，也不替代协议入口的语义校验。 */
    fun pendingIndices(manifest: AssetTransferManifest, excludedHashes: Set<String>): List<Int> =
        manifest.assets.indices.filter { index ->
            val hash = manifest.assets[index].hash
            hash in manifest.referencedHashes && hash !in excludedHashes
        }
}
