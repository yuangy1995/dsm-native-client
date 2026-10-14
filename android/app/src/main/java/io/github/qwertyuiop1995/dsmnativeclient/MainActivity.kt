package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspaceRoute
import io.github.qwertyuiop1995.dsmnativeclient.ui.LanStashApp
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.sharedInput
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.clearSharedInput
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.sources
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MainActivity : AppCompatActivity() {
    private val host: WorkspaceHostModel by viewModels()
    private val model: AppViewModel get() = host.active.value.model
    private var internalNavigation = InternalNavigationState()
    private var pendingNavigationIntent: Intent? = null
    private var internalNavigationJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        internalNavigation = savedInstanceState?.pendingInternalNavigationState()
            ?: InternalNavigationState()
        enableEdgeToEdge()
        setContent {
            LanStashTheme {
                LanStashApp(host)
            }
        }
        if (savedInstanceState?.getBoolean(STATE_TASK_HISTORY) == true && !host.taskHistoryVisible.value) {
            val token = savedInstanceState.getString(STATE_TASK_HISTORY_TOKEN)
            if (token == null || host.openLocalTransferTarget(token) != true) host.showTaskHistory()
        }
        val initialRequest = internalNavigation.currentRequest ?: intent.pendingNavigationRequest()
        handleIntent(intent)
        if (initialRequest == null || initialRequest is PendingNavigationRequest.Fixed &&
            initialRequest.request != InternalRouteRequest.OPEN_TRANSFERS) host.restoreInitialConnection()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_PENDING_ROUTE, internalNavigation.pendingRequest?.name)
        outState.putString(STATE_PENDING_OPAQUE_TOKEN, internalNavigation.pendingOpaqueToken)
        outState.putBoolean(STATE_TASK_HISTORY, host.taskHistoryVisible.value)
        outState.putString(STATE_TASK_HISTORY_TOKEN, host.taskHistoryToken.takeIf { host.taskHistoryVisible.value })
        super.onSaveInstanceState(outState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            try {
                val input = requireNotNull(intent).sharedInput(packageName)
                if (input != null) host.sharedInput.receive { input.sources(contentResolver, getString(R.string.shared_text_filename)) }
            } catch (_: Exception) { host.sharedInput.invalidInput() }
            intent?.clearSharedInput()
            return
        }
        val request = intent.pendingNavigationRequest()
        if (request is PendingNavigationRequest.Fixed) {
            model.cancelOpaqueExternalNavigation()
        }
        if (request == null && intent?.action == Intent.ACTION_VIEW) {
            intent.data = null
        }
        if (request != null && pendingNavigationIntent !== intent) {
            clearNavigationPayload(pendingNavigationIntent)
        }
        internalNavigation = internalNavigation.receive(request)
        if (request != null) {
            pendingNavigationIntent = intent
        }
        val pending = internalNavigation.currentRequest ?: return
        internalNavigationJob?.cancel()
        val handledLocalTask = if (pending is PendingNavigationRequest.OpaqueObject) host.openLocalTransferTarget(pending.token)
            else if (pending is PendingNavigationRequest.Fixed && pending.request == InternalRouteRequest.OPEN_TRANSFERS && model.workspace.value == null) host.showTaskHistory()
            else null
        if (handledLocalTask != null) {
            if (!handledLocalTask) host.closeTaskHistory()
            model.cancelOpaqueExternalNavigation()
            internalNavigation = internalNavigation.consume(pending)
            clearConsumedNavigationIntent(pendingNavigationIntent, pending)
            clearConsumedNavigationIntent(this.intent, pending)
            pendingNavigationIntent = null
            return
        }
        if (pending is PendingNavigationRequest.OpaqueObject && !host.selectForOpaqueTarget(pending.token)) {
            host.closeTaskHistory()
            internalNavigation = internalNavigation.consume(pending)
            clearConsumedNavigationIntent(pendingNavigationIntent, pending)
            pendingNavigationIntent = null
            return
        }
        host.closeTaskHistory()
        val job = lifecycleScope.launch {
            host.active.flatMapLatest { selection -> combine(
                selection.model.workspace.filterNotNull(), selection.model.opaqueExternalNavigationRevision,
            ) { _, _ -> Unit } }.first {
                if (internalNavigation.currentRequest != pending) return@first true
                navigatePendingRequest(pending) != WorkspaceNavigationResult.DEFERRED
            }
            if (internalNavigation.currentRequest == pending) {
                internalNavigation = internalNavigation.consume(pending)
                clearConsumedNavigationIntent(pendingNavigationIntent, pending)
                clearConsumedNavigationIntent(this@MainActivity.intent, pending)
                if (pending is PendingNavigationRequest.OpaqueObject) {
                    model.completeOpaqueExternalNavigation(pending.token)
                }
                pendingNavigationIntent = null
            }
        }
        internalNavigationJob = job
        job.invokeOnCompletion {
            if (internalNavigationJob === job) internalNavigationJob = null
        }
    }

    private fun navigatePendingRequest(
        pending: PendingNavigationRequest,
    ): WorkspaceNavigationResult {
        if (pending is PendingNavigationRequest.OpaqueObject) {
            return model.navigateToOpaqueExternalRoute(pending.token)
        }
        val request = (pending as PendingNavigationRequest.Fixed).request
        return model.navigateExternalRequest(request.module) {
            navigateFixedRequest(request)
        }
    }

    private fun navigateFixedRequest(request: InternalRouteRequest): WorkspaceNavigationResult {
        when (request) {
            InternalRouteRequest.OPEN_CONTAINER_REGISTRY -> return model.navigateToContainerRegistry()
            InternalRouteRequest.OPEN_VIRTUAL_MACHINE_TASKS -> {
                return model.navigateToVirtualMachineTasks()
            }
            InternalRouteRequest.OPEN_NAS_SETTINGS_PERFORMANCE -> {
                return model.navigateToNasSettingsPerformance()
            }
            else -> Unit
        }
        val moduleResult = model.navigateTo(WorkspaceRoute.ModuleRoot(request.module))
        if (moduleResult == WorkspaceNavigationResult.DEFERRED ||
            moduleResult == WorkspaceNavigationResult.REJECTED
        ) {
            return moduleResult
        }
        when (request) {
            InternalRouteRequest.OPEN_CONTAINERS -> model.closeContainerRegistry()
            InternalRouteRequest.OPEN_VIRTUAL_MACHINES -> model.closeVirtualMachineTasks()
            InternalRouteRequest.OPEN_NAS_SETTINGS -> model.closeNasSettingsPerformance()
            else -> Unit
        }
        return moduleResult
    }

    private fun clearConsumedNavigationIntent(
        intent: Intent?,
        request: PendingNavigationRequest,
    ) {
        if (intent.pendingNavigationRequest() != request) return
        clearNavigationPayload(intent)
    }

    private fun clearNavigationPayload(intent: Intent?) {
        intent?.removeExtra(TransferNotifications.EXTRA_OPEN_TRANSFERS)
        if (intent?.action == Intent.ACTION_VIEW) intent.data = null
    }

    private companion object {
        const val STATE_TASK_HISTORY = "task_history_visible"
        const val STATE_TASK_HISTORY_TOKEN = "task_history_token"
        const val STATE_PENDING_ROUTE = "pending_route"
        const val STATE_PENDING_OPAQUE_TOKEN = "pending_opaque_token"
    }
}

/** Activity 与 ViewModel 之间只传固定枚举或不透明令牌，解密后的业务目标永不进入 Bundle。 */
internal sealed interface PendingNavigationRequest {
    data class Fixed(val request: InternalRouteRequest) : PendingNavigationRequest
    data class OpaqueObject(val token: String) : PendingNavigationRequest
}

internal fun Bundle.pendingInternalNavigationState(): InternalNavigationState {
    val opaqueToken = getString("pending_opaque_token")
        ?.let(ExternalWorkspaceRoute.OpaqueObject::fromTokenOrNull)
        ?.token
    return if (opaqueToken != null) {
        InternalNavigationState(pendingOpaqueToken = opaqueToken)
    } else {
        pendingInternalRouteRequest()
            ?.let { request -> InternalNavigationState().receive(request) }
            ?: InternalNavigationState()
    }
}

/** 兼容第 81 批 Activity 已保存但尚未消费的固定模块状态。 */
internal fun Bundle.pendingInternalRouteRequest(): InternalRouteRequest? =
    getString("pending_route")
        ?.let { value -> runCatching { InternalRouteRequest.valueOf(value) }.getOrNull() }
        ?: if (getBoolean("pending_open_transfers")) {
            InternalRouteRequest.OPEN_TRANSFERS
        } else {
            getString("pending_module")
                ?.let { value -> runCatching { Module.valueOf(value) }.getOrNull() }
                ?.let(InternalRouteRequest::openModule)
        }

/** 只保存固定目标枚举，不能携带 URI、NAS、路径或业务对象标识。 */
internal enum class InternalRouteRequest(
    val module: Module,
) {
    OPEN_FILES(Module.FILES),
    OPEN_PHOTOS(Module.PHOTOS),
    OPEN_CHAT(Module.CHAT),
    OPEN_DOWNLOADS(Module.DOWNLOADS),
    OPEN_CONTAINERS(Module.CONTAINERS),
    OPEN_VIRTUAL_MACHINES(Module.VIRTUAL_MACHINES),
    OPEN_NAS_SETTINGS(Module.NAS_SETTINGS),
    OPEN_TRANSFERS(Module.TRANSFERS),
    OPEN_SETTINGS(Module.SETTINGS),
    OPEN_CONTAINER_REGISTRY(Module.CONTAINERS),
    OPEN_VIRTUAL_MACHINE_TASKS(Module.VIRTUAL_MACHINES),
    OPEN_NAS_SETTINGS_PERFORMANCE(Module.NAS_SETTINGS),
    ;

    companion object {
        fun openModule(module: Module): InternalRouteRequest = when (module) {
            Module.FILES -> OPEN_FILES
            Module.PHOTOS -> OPEN_PHOTOS
            Module.CHAT -> OPEN_CHAT
            Module.DOWNLOADS -> OPEN_DOWNLOADS
            Module.CONTAINERS -> OPEN_CONTAINERS
            Module.VIRTUAL_MACHINES -> OPEN_VIRTUAL_MACHINES
            Module.NAS_SETTINGS -> OPEN_NAS_SETTINGS
            Module.TRANSFERS -> OPEN_TRANSFERS
            Module.SETTINGS -> OPEN_SETTINGS
        }
    }
}

internal data class InternalNavigationState(
    val pendingRequest: InternalRouteRequest? = null,
    val pendingOpaqueToken: String? = null,
) {
    init {
        require(pendingRequest == null || pendingOpaqueToken == null) {
            "Only one pending navigation request may be retained"
        }
    }

    val currentRequest: PendingNavigationRequest?
        get() = pendingOpaqueToken?.let(PendingNavigationRequest::OpaqueObject)
            ?: pendingRequest?.let(PendingNavigationRequest::Fixed)

    val pendingOpenTransfers: Boolean
        get() = pendingRequest == InternalRouteRequest.OPEN_TRANSFERS

    val pendingModule: Module?
        get() = pendingRequest?.module

    fun receive(request: InternalRouteRequest?): InternalNavigationState =
        if (request != null) copy(pendingRequest = request, pendingOpaqueToken = null) else this

    fun receive(request: PendingNavigationRequest?): InternalNavigationState = when (request) {
        is PendingNavigationRequest.Fixed -> receive(request.request)
        is PendingNavigationRequest.OpaqueObject -> copy(
            pendingRequest = null,
            pendingOpaqueToken = request.token,
        )
        null -> this
    }

    fun consume(request: InternalRouteRequest): InternalNavigationState =
        if (pendingRequest == request) copy(pendingRequest = null) else this

    fun consume(request: PendingNavigationRequest): InternalNavigationState = when (request) {
        is PendingNavigationRequest.Fixed -> consume(request.request)
        is PendingNavigationRequest.OpaqueObject -> if (pendingOpaqueToken == request.token) {
            copy(pendingOpaqueToken = null)
        } else {
            this
        }
    }
}

internal fun Intent?.pendingNavigationRequest(): PendingNavigationRequest? = when {
    this?.action == Intent.ACTION_VIEW ->
        when (val route = dataString.externalWorkspaceRoute()) {
            is ExternalWorkspaceRoute.ModuleRoot -> PendingNavigationRequest.Fixed(
                InternalRouteRequest.openModule(route.module),
            )
            ExternalWorkspaceRoute.ContainerRegistry -> PendingNavigationRequest.Fixed(
                InternalRouteRequest.OPEN_CONTAINER_REGISTRY,
            )
            ExternalWorkspaceRoute.VirtualMachineTasks -> PendingNavigationRequest.Fixed(
                InternalRouteRequest.OPEN_VIRTUAL_MACHINE_TASKS,
            )
            ExternalWorkspaceRoute.NasSettingsPerformance ->
                PendingNavigationRequest.Fixed(InternalRouteRequest.OPEN_NAS_SETTINGS_PERFORMANCE)
            is ExternalWorkspaceRoute.OpaqueObject -> PendingNavigationRequest.OpaqueObject(route.token)
            null -> null
        }
    this?.getBooleanExtra(TransferNotifications.EXTRA_OPEN_TRANSFERS, false) == true ->
        PendingNavigationRequest.Fixed(InternalRouteRequest.OPEN_TRANSFERS)
    else -> null
}

/** 保留固定路由测试和旧调用方语义；动态对象必须使用 [pendingNavigationRequest]。 */
internal fun Intent?.internalRouteRequest(): InternalRouteRequest? =
    (pendingNavigationRequest() as? PendingNavigationRequest.Fixed)?.request
