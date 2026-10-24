package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.presentation.ImageDecodePolicy
import com.manonloki.lokimetrisdisplay.presentation.ImageDecodeProfile
import com.manonloki.lokimetrisdisplay.presentation.ImageFrameBudget
import com.manonloki.lokimetrisdisplay.presentation.ImageTargetSize
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ImageDecodePolicyTest {
    @Test fun profilesPreservePlatformPixelAndAnimationBudgets() {
        assertEquals(512, ImageDecodePolicy.pixelEdge(ImageDecodeProfile.ANDROID))
        assertEquals(512, ImageDecodePolicy.pixelEdge(ImageDecodeProfile.IPHONE))
        assertEquals(256, ImageDecodePolicy.pixelEdge(ImageDecodeProfile.WATCH))
        assertEquals(0L, ImageDecodePolicy.decodedByteLimit(ImageDecodeProfile.ANDROID))
        assertEquals(8L * 1024 * 1024, ImageDecodePolicy.decodedByteLimit(ImageDecodeProfile.IPHONE))
        assertEquals(2L * 1024 * 1024, ImageDecodePolicy.decodedByteLimit(ImageDecodeProfile.WATCH))
        assertEquals(512, ImageDecodePolicy.APPLE_MAX_FRAMES)
    }

    @Test fun sourcePixelsAndAndroidAspectRatioAreBoundedWithoutUpscaling() {
        assertEquals(ImageTargetSize(512, 256), ImageDecodePolicy.androidTargetSize(2048, 1024))
        assertEquals(ImageTargetSize(1, 512), ImageDecodePolicy.androidTargetSize(1, 4096))
        assertEquals(ImageTargetSize(8, 4), ImageDecodePolicy.androidTargetSize(8, 4))
        assertNotNull(ImageDecodePolicy.androidTargetSize(4096, 4096))
        assertNull(ImageDecodePolicy.androidTargetSize(4097, 4096))
        assertNull(ImageDecodePolicy.androidTargetSize(0, 1))
        assertNull(ImageDecodePolicy.androidTargetSize(Int.MAX_VALUE, Int.MAX_VALUE))
        for (invalid in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0, 0.0)) {
            assertFalse(ImageDecodePolicy.validSourceDimensions(invalid, 1.0, ImageDecodePolicy.MAX_SOURCE_PIXELS))
        }
    }

    @Test fun allFramesShareOneBudgetAndBoundaryDoesNotDropAnimationFrames() {
        assertEquals(ImageFrameBudget(64, 4), ImageDecodePolicy.frameBudget(2, 512, 128, 512))
        assertEquals(ImageFrameBudget(4096, 32), ImageDecodePolicy.frameBudget(512, 512, 2L * 1024 * 1024, 256))
        assertNull(ImageDecodePolicy.frameBudget(513, 512, 8L * 1024 * 1024, 512))
        assertNull(ImageDecodePolicy.frameBudget(2, 512, 7, 512))
        assertNull(ImageDecodePolicy.frameBudget(0, 512, 128, 512))
        assertFalse(ImageDecodePolicy.validFrameLimits(0, 128, 512))
        assertFalse(ImageDecodePolicy.validFrameLimits(512, 3, 512))
        assertFalse(ImageDecodePolicy.validFrameLimits(512, 128, 0))
    }

    @Test fun measuredRowPaddingShrinksEdgeAndCannotLoopAtOnePixel() {
        assertEquals(2, ImageDecodePolicy.smallerFrameEdge(4, 128, 64))
        assertEquals(3, ImageDecodePolicy.smallerFrameEdge(4, 65, 64))
        assertEquals(1, ImageDecodePolicy.smallerFrameEdge(2, 128, 64))
        assertEquals(0, ImageDecodePolicy.smallerFrameEdge(1, 128, 64))
        assertEquals(0, ImageDecodePolicy.smallerFrameEdge(4, 0, 64))
    }

    @Test fun actualDecodedBytesMustFitRemainingBudgetWithoutOverflow() {
        assertTrue(ImageDecodePolicy.fitsDecodedFrame(64, 64, 128))
        assertFalse(ImageDecodePolicy.fitsDecodedFrame(65, 64, 128))
        assertFalse(ImageDecodePolicy.fitsDecodedFrame(Long.MAX_VALUE, 1, Long.MAX_VALUE))
        assertTrue(ImageDecodePolicy.fitsDecodedFrame(1, Long.MAX_VALUE - 1, Long.MAX_VALUE))
        assertFalse(ImageDecodePolicy.fitsDecodedFrame(1, Long.MAX_VALUE, 128))
        assertFalse(ImageDecodePolicy.fitsDecodedFrame(-1, 0, 128))
    }
}
