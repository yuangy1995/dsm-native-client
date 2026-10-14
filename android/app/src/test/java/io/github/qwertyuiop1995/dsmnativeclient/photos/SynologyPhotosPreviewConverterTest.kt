package io.github.qwertyuiop1995.dsmnativeclient.photos

import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosPreviewConverterTest {
    @Test fun `三档按短边等比缩小且小图不放大`() {
        assertEquals(1920 to 1280, SynologyPhotosPreviewConverter.dimensions(6000, 4000, 1280))
        assertEquals(360 to 240, SynologyPhotosPreviewConverter.dimensions(6000, 4000, 240))
        assertEquals(480 to 320, SynologyPhotosPreviewConverter.dimensions(6000, 4000, 320))
        assertEquals(1280 to 1920, SynologyPhotosPreviewConverter.dimensions(4000, 6000, 1280))
        assertEquals(120 to 80, SynologyPhotosPreviewConverter.dimensions(120, 80, 1280))
    }
    @Test fun `视频按时长取一秒或三秒且不越过短片末尾`() {
        assertEquals(3_000_000L, SynologyPhotosPreviewConverter.frameTimeMicros(5_000))
        assertEquals(1_000_000L, SynologyPhotosPreviewConverter.frameTimeMicros(3_000))
        assertEquals(1_000_000L, SynologyPhotosPreviewConverter.frameTimeMicros(2_000))
        assertEquals(466_667L, SynologyPhotosPreviewConverter.frameTimeMicros(500))
        assertEquals(0L, SynologyPhotosPreviewConverter.frameTimeMicros(20))
    }
    @Test fun `空尺寸无效时长及不能有界解码的长图拒绝`() {
        assertThrows(PhotoPreviewConversionFailure::class.java) { SynologyPhotosPreviewConverter.dimensions(0, 1, 1280) }
        assertThrows(PhotoPreviewConversionFailure::class.java) { SynologyPhotosPreviewConverter.dimensions(Int.MAX_VALUE, 1, 1280) }
        assertThrows(PhotoPreviewConversionFailure::class.java) { SynologyPhotosPreviewConverter.frameTimeMicros(0) }
        assertThrows(PhotoPreviewConversionFailure::class.java) { SynologyPhotosPreviewConverter.frameTimeMicros(Long.MAX_VALUE) }
    }
}
