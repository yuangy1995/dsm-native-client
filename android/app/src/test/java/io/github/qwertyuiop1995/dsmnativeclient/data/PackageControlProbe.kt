package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.performControl
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.net.URLDecoder
import java.util.Locale
import java.util.UUID
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*

/** 两组协议回归直接记录当前安装管线检查点，不复制旧门面的结果转换。 */
internal data class PackageControlProbe(val stages: List<NasPackageWriteStage>, val failure: Throwable?)
internal suspend fun DsmRepository.probePackageControl(original: PackageInfo, action: String): PackageControlProbe {
    val stages = mutableListOf<NasPackageWriteStage>()
    val result = runCatching {
        packageCenter.performControl(UUID.randomUUID().toString(), original, PackageMutationOperation.valueOf(action.uppercase(Locale.ROOT))) { stages += it.stage }
    }
    return PackageControlProbe(stages, result.exceptionOrNull())
}
internal suspend fun DsmRepository.probePackageUninstall(original: PackageInfo) = probePackageControl(original, "uninstall")
internal fun assertPackageVerified(result: PackageControlProbe) {
    assertEquals(null, result.failure)
    assertEquals(NasPackageWriteStage.VERIFIED, result.stages.last())
    assertEquals(1, result.stages.count { it == NasPackageWriteStage.WILL_SUBMIT })
}
internal fun assertPackageNotSubmitted(result: PackageControlProbe) {
    assertTrue(result.failure != null)
    assertTrue(result.stages.isEmpty())
}
internal fun assertPackagePending(result: PackageControlProbe) {
    assertEquals(1, result.stages.count { it == NasPackageWriteStage.WILL_SUBMIT })
    assertFalse(NasPackageWriteStage.VERIFIED in result.stages)
    assertFalse(NasPackageWriteStage.REJECTED in result.stages)
}
internal fun packageMutationClient(interceptor: Interceptor) = DsmApiClient(OkHttpClient.Builder()
    .retryOnConnectionFailure(false).addInterceptor { chain ->
        val request = chain.request()
        if (request.packageMutationFields()["api"] == "SYNO.Core.System") {
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                .body("""{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}"""
                    .toResponseBody("application/json".toMediaType())).build()
        } else chain.proceed(request)
    }.addInterceptor(interceptor).build())
internal fun Request.packageMutationFields(): Map<String, String> {
    val encoded = Buffer().also { body?.writeTo(it) }.readUtf8()
    return encoded.split('&').associate { field ->
        val pair = field.split('=', limit = 2)
        URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
    }
}
