package com.manonloki.lokimetrisdisplay

import kotlin.math.sqrt

enum class ImageDecodeProfile { ANDROID, IPHONE, WATCH }
data class ImageTargetSize(val width: Int, val height: Int)
data class ImageFrameBudget(val byteLimit: Long, val pixelEdge: Int)

/** 解码前后的纯预算与缩放规则；系统解码器、帧元信息及真实行字节由宿主提供。 */
object ImageDecodePolicy {
    const val MAX_SOURCE_PIXELS = 16_777_216L
    const val APPLE_MAX_FRAMES = 512

    fun pixelEdge(profile: ImageDecodeProfile): Int = if (profile == ImageDecodeProfile.WATCH) 256 else 512

    /** Android 系统动画解码不具备当前 Apple 的逐帧核算入口，0 表示不施加这项预算。 */
    fun decodedByteLimit(profile: ImageDecodeProfile): Long = when (profile) {
        ImageDecodeProfile.ANDROID -> 0L
        ImageDecodeProfile.IPHONE -> 8L * 1024 * 1024
        ImageDecodeProfile.WATCH -> 2L * 1024 * 1024
    }

    fun validSourceDimensions(width: Double, height: Double, maxPixels: Long): Boolean =
        width.isFinite() && height.isFinite() && width > 0 && height > 0 && maxPixels > 0 &&
            width * height <= maxPixels.toDouble()

    /** Android 的原尺寸不放大，长边限制为 512，向下取整且每边至少一个像素。 */
    fun androidTargetSize(width: Int, height: Int): ImageTargetSize? {
        if (!validSourceDimensions(width.toDouble(), height.toDouble(), MAX_SOURCE_PIXELS)) return null
        val scale = minOf(1.0, pixelEdge(ImageDecodeProfile.ANDROID).toDouble() / maxOf(width, height))
        return ImageTargetSize(maxOf(1, (width * scale).toInt()), maxOf(1, (height * scale).toInt()))
    }

    /** 保留全部动画帧；先均分字节预算，再按每像素四字节决定共同初始边长。 */
    fun frameBudget(frameCount: Int, maxFrames: Int, maxDecodedBytes: Long, maxPixelSize: Int): ImageFrameBudget? {
        if (!validFrameLimits(maxFrames, maxDecodedBytes, maxPixelSize) || frameCount <= 0 || frameCount > maxFrames) return null
        val perFrame = maxDecodedBytes / frameCount
        val edge = minOf(maxPixelSize, sqrt((perFrame / 4).toDouble()).toInt())
        return if (edge >= 1) ImageFrameBudget(perFrame, edge) else null
    }

    fun validFrameLimits(maxFrames: Int, maxDecodedBytes: Long, maxPixelSize: Int): Boolean =
        maxFrames > 0 && maxDecodedBytes >= 4 && maxPixelSize > 0

    /** ImageIO 行对齐超出初始估计时继续缩边；返回 0 表示已无法缩小。 */
    fun smallerFrameEdge(currentEdge: Int, decodedBytes: Long, frameByteLimit: Long): Int {
        if (currentEdge <= 1 || decodedBytes <= 0 || frameByteLimit < 0) return 0
        val ratio = frameByteLimit.toDouble() / decodedBytes.toDouble()
        return maxOf(1, minOf(currentEdge - 1, (currentEdge * sqrt(ratio)).toInt()))
    }

    fun fitsDecodedFrame(decodedBytes: Long, usedBytes: Long, maxDecodedBytes: Long): Boolean =
        decodedBytes >= 0 && usedBytes >= 0 && maxDecodedBytes >= usedBytes && decodedBytes <= maxDecodedBytes - usedBytes
}
