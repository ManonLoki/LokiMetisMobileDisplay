package com.manonloki.lokimetrisdisplay

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.Codec
import org.jetbrains.skia.Data
import org.jetbrains.skia.Image as SkiaImage
import org.jetbrains.skia.Rect
import org.jetbrains.skia.Surface

/** 所有帧共享 8 MiB 缩略图预算；Skia 处理 GIF/WebP 帧合成和恢复，保留原帧时长与循环数。 */
internal data class DesktopDecodedImage(
    val frames: List<ImageBitmap>, val durationsMs: List<Long>, val repetitionCount: Int,
)

/** 编码正文已由连接层验证；这里再次限制源像素与帧数，避免界面分配无界图片。 */
internal fun decodeDesktopHookImage(bytes: ByteArray): DesktopDecodedImage {
    require(bytes.isNotEmpty() && bytes.size.toLong() <= TerminalAsset.MAX_LENGTH)
    return Data.makeFromBytes(bytes).use { data ->
        Codec.makeFromData(data).use { codec ->
            val width = codec.width; val height = codec.height
            require(ImageDecodePolicy.validSourceDimensions(width.toDouble(), height.toDouble(), ImageDecodePolicy.MAX_SOURCE_PIXELS))
            val frameCount = codec.frameCount.coerceAtLeast(1)
            val budget = requireNotNull(ImageDecodePolicy.frameBudget(frameCount, ImageDecodePolicy.APPLE_MAX_FRAMES,
                ImageDecodePolicy.decodedByteLimit(ImageDecodeProfile.IPHONE), ImageDecodePolicy.pixelEdge(ImageDecodeProfile.IPHONE)))
            val scale = minOf(1.0, budget.pixelEdge.toDouble() / maxOf(width, height))
            val targetWidth = maxOf(1, (width * scale).toInt()); val targetHeight = maxOf(1, (height * scale).toInt())
            val frames = mutableListOf<ImageBitmap>(); val durations = mutableListOf<Long>()
            Bitmap().use { source ->
                check(source.allocPixels(codec.imageInfo))
                repeat(frameCount) { index ->
                    // priorFrame=-1 要求编解码器处理依赖和 disposal，不能直接叠加上一张缩略图。
                    codec.readPixels(source, index)
                    SkiaImage.makeFromBitmap(source).use { image ->
                        Surface.makeRasterN32Premul(targetWidth, targetHeight).use { surface ->
                            surface.canvas.clear(0)
                            surface.canvas.drawImageRect(image, Rect.makeWH(targetWidth.toFloat(), targetHeight.toFloat()))
                            surface.makeImageSnapshot().use { thumbnail -> frames += thumbnail.toComposeImageBitmap() }
                        }
                    }
                    durations += if (frameCount > 1) codec.getFrameInfo(index).duration.toLong().coerceAtLeast(10L) else 0L
                }
            }
            DesktopDecodedImage(frames, durations, codec.repetitionCount)
        }
    }
}

/** 页面、分页、详情与窗口统一控制播放；隐藏后取消计时，静态帧仍可显示。 */
@Composable
fun DesktopHookImage(bytes: ByteArray, description: String) {
    val decoded by produceState<DesktopDecodedImage?>(null, bytes) {
        value = withContext(Dispatchers.Default) { runCatching { decodeDesktopHookImage(bytes) }.getOrNull() }
    }
    var visible by remember { mutableStateOf(false) }
    var frame by remember(bytes) { mutableIntStateOf(0) }
    val playbackAllowed = LocalCyberMotion.current && visible
    LaunchedEffect(decoded, playbackAllowed) {
        val image = decoded ?: return@LaunchedEffect
        if (!playbackAllowed || image.frames.size < 2) return@LaunchedEffect
        var repeats = 0
        while (true) {
            delay(image.durationsMs[frame])
            if (frame + 1 < image.frames.size) frame++
            else {
                if (image.repetitionCount >= 0 && repeats >= image.repetitionCount) break
                repeats++; frame = 0
            }
        }
    }
    val image = decoded
    if (image == null) Text("图片暂不可用")
    else Image(image.frames[frame.coerceIn(image.frames.indices)], description,
        Modifier.fillMaxSize().clipToBounds().onGloballyPositioned { visible = !it.boundsInWindow().isEmpty },
        contentScale = ContentScale.Fit)
}
