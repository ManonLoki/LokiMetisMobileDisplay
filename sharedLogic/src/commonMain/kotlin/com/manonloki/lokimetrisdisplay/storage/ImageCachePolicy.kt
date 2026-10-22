package com.manonloki.lokimetrisdisplay

enum class ImageCacheProfile { ANDROID, IPHONE, WATCH }

/** key 只标识宿主已枚举的文件；lastUsed 在同一次扫描内使用宿主原有精度和时间单位。 */
data class ImageCacheEntry(val key: String, val byteLength: Long, val lastUsed: Double)
/** 内部双字累计不受 Swift Int 宽度或异常文件长度求和溢出影响；平台只持有不可变结果。 */
class ImageCacheOccupancy internal constructor(internal val byteHigh: ULong, internal val byteLow: ULong, val fileCount: Int)
data class ImageCachePlan(val candidates: List<ImageCacheEntry>, val occupancy: ImageCacheOccupancy)

/** 共享淘汰资格、顺序和预算；目录、链接检查、真实删除及失败重试仍归平台。 */
object ImageCachePolicy {
    const val MAX_BYTES = 512L * 1024 * 1024
    const val MAX_FILES = 512

    fun plan(entries: List<ImageCacheEntry>, keeping: Set<String>): ImageCachePlan {
        var high = 0UL
        var low = 0UL
        for (entry in entries) {
            val next = low + entry.byteLength.coerceAtLeast(0).toULong()
            if (next < low) high++
            low = next
        }
        return ImageCachePlan(entries.filter { it.key !in keeping }.sortedBy { it.lastUsed },
            ImageCacheOccupancy(high, low, entries.size))
    }

    /** iPhone 保留原有的纯字节预算；Android 与 Watch 同时限制文件数。 */
    fun shouldEvict(occupancy: ImageCacheOccupancy, profile: ImageCacheProfile): Boolean =
        occupancy.byteHigh > 0UL || occupancy.byteLow > MAX_BYTES.toULong() ||
            profile != ImageCacheProfile.IPHONE && occupancy.fileCount > MAX_FILES

    /** 只在系统确认删除成功后提交；失败时沿用原 occupancy，不能假定已释放空间。 */
    fun removed(occupancy: ImageCacheOccupancy, entry: ImageCacheEntry): ImageCacheOccupancy {
        val size = entry.byteLength.coerceAtLeast(0).toULong()
        val underflow = occupancy.byteHigh == 0UL && size > occupancy.byteLow
        val high = if (underflow) 0UL else occupancy.byteHigh - if (size > occupancy.byteLow) 1UL else 0UL
        val low = if (underflow) 0UL else occupancy.byteLow - size
        return ImageCacheOccupancy(high, low, (occupancy.fileCount - 1).coerceAtLeast(0))
    }
}
