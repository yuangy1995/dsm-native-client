package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure

/**
 * 统一解析 DSM 能力。它不做网络请求，也不以能力发现结果开放未验证的写操作。
 */
internal class DsmRepositoryCapabilityResolver(
    private val capabilities: Map<String, ApiCapability>,
) {
    fun supports(apiName: String): Boolean = capabilities.containsKey(apiName)

    fun supportsVersion(apiName: String, version: Int): Boolean =
        capabilities[apiName]?.let { version in it.minVersion..it.maxVersion } == true

    fun preferred(vararg names: String): String =
        names.firstOrNull(::supports)
            ?: throw DsmFailure(
                102,
                "Feature unsupported",
                "Update DSM or the related package.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )

    fun preferredOrNull(vararg names: String): String? = names.firstOrNull(::supports)

    fun requireCapability(apiName: String): ApiCapability = capabilities[apiName]
        ?: throw DsmFailure(
            102,
            "Feature unsupported",
            "Update DSM or use File Station in a browser.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
}
