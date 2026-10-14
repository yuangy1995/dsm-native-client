package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspacePage
import java.net.URI
import java.util.Base64

/**
 * 外部入口只允许打开固定模块根页面或白名单中的无载荷固定页面，
 * 不接受 NAS、路径、会话、任务、查询或凭据。
 *
 * 公共形式固定为 `lanstash://open/<module>`、三个无载荷固定深页，以及
 * `lanstash://open/object/<opaque-token>`。对象链接只允许固定长度、无填充且规范编码的 Base64URL
 * 不透明令牌；令牌本身不承载 NAS、路径、会话或业务对象资料。任何未白名单的路径、查询、片段、
 * 端口、用户信息或编码后的路径变体都会被拒绝，避免把业务载荷引入导航状态。
 */
internal sealed interface ExternalWorkspaceRoute {
    data class ModuleRoot(val module: Module) : ExternalWorkspaceRoute

    data object ContainerRegistry : ExternalWorkspaceRoute {
        val module: Module = Module.CONTAINERS
    }

    data object VirtualMachineTasks : ExternalWorkspaceRoute {
        val module: Module = Module.VIRTUAL_MACHINES
    }

    data object NasSettingsPerformance : ExternalWorkspaceRoute {
        val module: Module = Module.NAS_SETTINGS
    }

    /**
     * 已校验的不透明对象令牌。
     *
     * 构造器保持私有，调用方只能通过 [fromTokenOrNull] 或 URI 解析获得实例，不能把任意字符串
     * 伪装成可公开的对象链接。
     */
    data class OpaqueObject private constructor(val token: String) : ExternalWorkspaceRoute {
        companion object {
            internal fun fromTokenOrNull(token: String): OpaqueObject? =
                token.takeIf(::isOpaqueObjectToken)?.let(::OpaqueObject)
        }
    }
}

internal fun String?.externalWorkspaceRoute(): ExternalWorkspaceRoute? {
    val uri = this?.let { runCatching { URI(it) }.getOrNull() } ?: return null
    if (uri.isOpaque || uri.scheme != EXTERNAL_ROUTE_SCHEME ||
        uri.host != EXTERNAL_ROUTE_HOST || uri.rawAuthority != EXTERNAL_ROUTE_HOST ||
        uri.userInfo != null || uri.port != -1 || uri.rawQuery != null || uri.rawFragment != null
    ) return null
    val rawPath = uri.rawPath ?: return null
    if ('%' in rawPath) return null
    when (rawPath) {
        CONTAINER_REGISTRY_PATH -> return ExternalWorkspaceRoute.ContainerRegistry
        VIRTUAL_MACHINE_TASKS_PATH -> return ExternalWorkspaceRoute.VirtualMachineTasks
        NAS_SETTINGS_PERFORMANCE_PATH -> return ExternalWorkspaceRoute.NasSettingsPerformance
    }
    if (rawPath.startsWith("$OPAQUE_OBJECT_PATH_PREFIX/")) {
        return ExternalWorkspaceRoute.OpaqueObject.fromTokenOrNull(
            rawPath.removePrefix("$OPAQUE_OBJECT_PATH_PREFIX/"),
        )
    }
    val slug = rawPath.removePrefix("/")
        .takeIf { it.isNotEmpty() && '/' !in it && '%' !in it }
        ?: return null
    return EXTERNAL_MODULES[slug]?.let(ExternalWorkspaceRoute::ModuleRoot)
}

/** 保持模块根页调用方的既有语义；固定子页面不会降级为模块根页。 */
internal fun String?.externalWorkspaceModule(): Module? =
    (externalWorkspaceRoute() as? ExternalWorkspaceRoute.ModuleRoot)?.module

/**
 * 由已校验的令牌生成唯一规范的对象外链。
 *
 * 非法令牌返回 `null`，因此调用方不能通过字符串拼接绕过对象外链的格式约束。
 */
internal fun opaqueObjectExternalWorkspaceUri(token: String): String? =
    ExternalWorkspaceRoute.OpaqueObject.fromTokenOrNull(token)?.externalWorkspaceUri()

/** 已校验令牌不含需要 URI 编码的字符，直接拼接即可保持唯一规范形式。 */
internal fun ExternalWorkspaceRoute.OpaqueObject.externalWorkspaceUri(): String =
    "$EXTERNAL_ROUTE_SCHEME://$EXTERNAL_ROUTE_HOST$OPAQUE_OBJECT_PATH_PREFIX/$token"

internal fun Module.externalWorkspaceSlug(): String = when (this) {
    Module.FILES -> "files"
    Module.PHOTOS -> "photos"
    Module.CHAT -> "chat"
    Module.DOWNLOADS -> "downloads"
    Module.CONTAINERS -> "containers"
    Module.VIRTUAL_MACHINES -> "virtual-machines"
    Module.NAS_SETTINGS -> "nas-settings"
    Module.TRANSFERS -> "transfers"
    Module.SETTINGS -> "settings"
}

internal fun String.workspacePageOrNull(): WorkspacePage? = when (val route = externalWorkspaceRoute()) {
    is ExternalWorkspaceRoute.ModuleRoot -> WorkspacePage.entries.first { it.name == route.module.name }
    ExternalWorkspaceRoute.ContainerRegistry -> WorkspacePage.CONTAINER_REGISTRY
    ExternalWorkspaceRoute.VirtualMachineTasks -> WorkspacePage.VIRTUAL_MACHINE_TASKS
    ExternalWorkspaceRoute.NasSettingsPerformance -> WorkspacePage.NAS_PERFORMANCE
    else -> null
}

private const val EXTERNAL_ROUTE_SCHEME = "lanstash"
private const val EXTERNAL_ROUTE_HOST = "open"
private const val CONTAINER_REGISTRY_PATH = "/containers/registry"
private const val VIRTUAL_MACHINE_TASKS_PATH = "/virtual-machines/tasks"
private const val NAS_SETTINGS_PERFORMANCE_PATH = "/nas-settings/performance"
private const val OPAQUE_OBJECT_PATH_PREFIX = "/object"
private const val OPAQUE_OBJECT_TOKEN_BYTE_LENGTH = 32
private const val OPAQUE_OBJECT_TOKEN_LENGTH = 43

private val OPAQUE_OBJECT_TOKEN_REGEX = Regex("[A-Za-z0-9_-]{$OPAQUE_OBJECT_TOKEN_LENGTH}")
private val OPAQUE_OBJECT_TOKEN_DECODER = Base64.getUrlDecoder()
private val OPAQUE_OBJECT_TOKEN_ENCODER = Base64.getUrlEncoder().withoutPadding()

private fun isOpaqueObjectToken(token: String): Boolean {
    if (!OPAQUE_OBJECT_TOKEN_REGEX.matches(token)) return false
    val decoded = runCatching { OPAQUE_OBJECT_TOKEN_DECODER.decode(token) }.getOrNull() ?: return false
    return decoded.size == OPAQUE_OBJECT_TOKEN_BYTE_LENGTH &&
        OPAQUE_OBJECT_TOKEN_ENCODER.encodeToString(decoded) == token
}

private val EXTERNAL_MODULES: Map<String, Module> =
    Module.entries.associateBy(Module::externalWorkspaceSlug)
