package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileShareLink
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.floor

/** 只编码已有链接，不请求远端图片；保留四模块留白和中等纠错。 */
internal fun fileShareQrCode(value: String): BitMatrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 0, 0,
    mapOf(EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 4))

@Composable
internal fun FileShareQrDialog(link: FileShareLink, onClose: () -> Unit) {
    val result by produceState<Result<BitMatrix>?>(null, link.url) {
        value = withContext(Dispatchers.Default) { runCatching { fileShareQrCode(link.url) } }
    }
    val label = stringResource(R.string.file_share_qr)
    ClientSheet(label, onClose) {
        Text(link.name, style = MaterialTheme.typography.titleSmall)
        when {
            result == null -> CircularProgressIndicator()
            result?.isFailure == true -> Text(stringResource(R.string.file_share_qr_failed), color = MaterialTheme.colorScheme.error)
            else -> {
                val matrix = result!!.getOrThrow()
                Canvas(Modifier.fillMaxWidth().aspectRatio(1f).sizeIn(maxWidth = 360.dp, maxHeight = 360.dp)
                    .testTag("file_share_qr_image").semantics { contentDescription = label }) {
                    drawRect(Color.White)
                    val step = floor(minOf(size.width / matrix.width, size.height / matrix.height))
                    val left = floor((size.width - step * matrix.width) / 2)
                    val top = floor((size.height - step * matrix.height) / 2)
                    for (y in 0 until matrix.height) for (x in 0 until matrix.width) if (matrix[x, y]) {
                        drawRect(Color.Black, Offset(left + x * step, top + y * step), Size(step, step))
                    }
                }
            }
        }
        SelectionContainer { Text(link.url, style = MaterialTheme.typography.bodySmall) }
    }
}
