package com.manonloki.lokimetrisdisplay

import java.awt.Color
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import javax.imageio.IIOImage
import javax.imageio.ImageIO
import javax.imageio.metadata.IIOMetadataNode
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Surface
import kotlin.test.*

class DesktopHookImageTest {
    @Test fun decodesPngJpegAndBmpWithSharedThumbnailBounds() {
        for (format in listOf("png", "jpeg", "bmp")) {
            val image = decodeDesktopHookImage(still(format, 1024, 256))
            assertEquals(1, image.frames.size, format)
            assertEquals(512, image.frames.single().width, format)
            assertEquals(128, image.frames.single().height, format)
            assertEquals(0, image.repetitionCount, format)
        }
    }

    @Test fun webpUsesTheBundledDesktopDecoder() {
        val bytes = Surface.makeRasterN32Premul(3, 2).use { surface ->
            surface.canvas.clear(0xffff0000.toInt())
            surface.makeImageSnapshot().use { image ->
                requireNotNull(image.encodeToData(EncodedImageFormat.WEBP, 100)).use { it.bytes }
            }
        }
        val decoded = decodeDesktopHookImage(bytes)
        assertEquals(3, decoded.frames.single().width)
        assertEquals(2, decoded.frames.single().height)
    }

    @Test fun gifKeepsFrameTimingColorsAndFiniteLoopCount() {
        val decoded = decodeDesktopHookImage(animatedGif(2))
        assertEquals(2, decoded.frames.size)
        assertEquals(listOf(70L, 130L), decoded.durationsMs)
        assertEquals(2, decoded.repetitionCount)
        val first = IntArray(4); val second = IntArray(4)
        decoded.frames[0].readPixels(first); decoded.frames[1].readPixels(second)
        assertNotEquals(first[0], second[0], "Each GIF frame must retain its own rendered pixels")
    }

    @Test fun excessiveFramesAndMalformedEncodedImagesAreRejected() {
        assertFails { decodeDesktopHookImage(animatedGif(ImageDecodePolicy.APPLE_MAX_FRAMES + 1)) }
        assertFails { decodeDesktopHookImage(byteArrayOf(1, 2, 3)) }
        assertFails { decodeDesktopHookImage(byteArrayOf()) }
    }

    private fun still(format: String, width: Int, height: Int): ByteArray {
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        image.createGraphics().let { graphics ->
            try { graphics.color = Color.RED; graphics.fillRect(0, 0, width, height) }
            finally { graphics.dispose() }
        }
        return ByteArrayOutputStream().use { output -> check(ImageIO.write(image, format, output)); output.toByteArray() }
    }

    private fun animatedGif(frameCount: Int): ByteArray {
        val writer = ImageIO.getImageWritersByFormatName("gif").next()
        val output = ByteArrayOutputStream()
        try {
            ImageIO.createImageOutputStream(output).use { stream ->
                writer.output = stream; writer.prepareWriteSequence(null)
                repeat(frameCount) { index ->
                    val image = BufferedImage(2, 2, BufferedImage.TYPE_INT_RGB)
                    repeat(2) { x -> repeat(2) { y -> image.setRGB(x, y, if (index % 2 == 0) Color.RED.rgb else Color.BLUE.rgb) } }
                    val metadata = writer.getDefaultImageMetadata(javax.imageio.ImageTypeSpecifier.createFromRenderedImage(image), writer.defaultWriteParam)
                    val root = metadata.getAsTree("javax_imageio_gif_image_1.0") as IIOMetadataNode
                    val control = (0 until root.length).map { root.item(it) }.filterIsInstance<IIOMetadataNode>().first { it.nodeName == "GraphicControlExtension" }
                    control.setAttribute("delayTime", if (index % 2 == 0) "7" else "13")
                    if (index == 0) {
                        val application = IIOMetadataNode("ApplicationExtension").apply {
                            setAttribute("applicationID", "NETSCAPE"); setAttribute("authenticationCode", "2.0")
                            userObject = byteArrayOf(1, 2, 0)
                        }
                        root.appendChild(IIOMetadataNode("ApplicationExtensions").apply { appendChild(application) })
                    }
                    metadata.setFromTree("javax_imageio_gif_image_1.0", root)
                    writer.writeToSequence(IIOImage(image, null, metadata), writer.defaultWriteParam)
                }
                writer.endWriteSequence()
            }
            return output.toByteArray()
        } finally { writer.dispose() }
    }
}
