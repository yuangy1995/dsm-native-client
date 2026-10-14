package io.github.qwertyuiop1995.dsmnativeclient.ui

import com.google.zxing.BinaryBitmap
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import org.junit.Assert.*
import org.junit.Test

class FileShareQrCodeTest {
    @Test fun emptyAndOversizedValuesFailInsteadOfReturningAnUnusableCode() {
        assertThrows(IllegalArgumentException::class.java) { fileShareQrCode("") }
        assertThrows(com.google.zxing.WriterException::class.java) { fileShareQrCode("https://share.example.invalid/" + "x".repeat(10_000)) }
    }
    @Test fun encodedLinksDecodeExactlyIncludingUnicodeAndLongValues() {
        listOf("https://share.example.invalid/a", "https://share.example.invalid/中文?value=%20&part=二",
            "https://share.example.invalid/" + "synthetic".repeat(120)).forEach { link ->
            val matrix = fileShareQrCode(link)
            val scale = 6
            val width = matrix.width * scale
            val pixels = IntArray(width * width) { index -> if (matrix[(index % width) / scale, (index / width) / scale]) 0xff000000.toInt() else 0xffffffff.toInt() }
            val decoded = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(width, width, pixels))))
            assertEquals(link, decoded.text)
            for (i in 0 until matrix.width) for (margin in 0..3) {
                assertFalse(matrix[i, margin]); assertFalse(matrix[margin, i])
                assertFalse(matrix[i, matrix.height - 1 - margin]); assertFalse(matrix[matrix.width - 1 - margin, i])
            }
        }
    }
}
