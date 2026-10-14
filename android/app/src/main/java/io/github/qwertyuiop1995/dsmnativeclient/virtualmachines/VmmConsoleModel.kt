package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class VmmConsoleState(val target: VmmControlTarget? = null, val session: VmmConsoleSession? = null,
    val phase: VmmConsolePhase = VmmConsolePhase.DISCONNECTED, val failure: Exception? = null)

/** 生命周期仅在内存中；恢复前台不会自动恢复画面或重发输入。 */
internal class VmmConsoleModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val canStart: (VmmControlTarget) -> Boolean, private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val lock = Any(); private var job: Job? = null; private var bound: DsmRepository? = null; private var generation = 0
    private val mutable = MutableStateFlow(VmmConsoleState()); val state = mutable.asStateFlow()
    val supported get() = repository()?.supportsVirtualMachineConsole == true
    fun protects(id: String) = state.value.target?.id == id
    fun open(target: VmmControlTarget): Boolean = synchronized(lock) {
        if (state.value.target != null) return false
        start(target)
    }
    fun reconnect(): Boolean = synchronized(lock) {
        val target = state.value.target ?: return false
        if (state.value.phase !in setOf(VmmConsolePhase.DISCONNECTED, VmmConsolePhase.FAILED)) return false
        start(target)
    }
    private fun start(target: VmmControlTarget): Boolean {
        val repo = repository()?.takeIf { it.owner != null && it.supportsVirtualMachineConsole } ?: return false
        try { repo.requireCurrentOwner(); if (!canStart(target) || target.status != "running") return false }
        catch (error: Exception) { mutable.value = VmmConsoleState(target, phase = VmmConsolePhase.FAILED, failure = error); return false }
        disconnect(); bound = repo; val token = ++generation
        mutable.value = VmmConsoleState(target, phase = VmmConsolePhase.LOADING)
        job = scope.launch(dispatcher) {
            var prepared: VmmConsoleSession? = null
            try {
                VmmExecutionGate.execute(requireNotNull(repo.owner)) {
                    ensureCurrent(repo, token)
                    if (!canStart(target)) vmmConflict()
                    prepared = repo.prepareVirtualMachineConsole(target)
                    ensureCurrent(repo, token)
                    if (!canStart(target)) vmmConflict()
                    synchronized(lock) { ensureCurrent(repo, token); mutable.value = VmmConsoleState(target, prepared, VmmConsolePhase.LOADING) }
                }
                val session = checkNotNull(prepared)
                session.transport.phase.collect { phase ->
                    synchronized(lock) {
                        ensureCurrent(repo, token)
                        mutable.update { it.copy(phase = phase, session = session.takeIf { phase !in setOf(VmmConsolePhase.DISCONNECTED, VmmConsolePhase.FAILED) }) }
                    }
                }
            } catch (error: Exception) {
                prepared?.transport?.close(true)
                synchronized(lock) {
                    if (bound === repo && generation == token && repository() === repo) mutable.update {
                        it.copy(session = null, phase = if (error is CancellationException) VmmConsolePhase.DISCONNECTED else VmmConsolePhase.FAILED,
                            failure = error.takeUnless { it is CancellationException })
                    }
                }
            }
        }
        return true
    }
    private fun ensureCurrent(repo: DsmRepository, token: Int) {
        repo.requireCurrentOwner()
        if (bound !== repo || repository() !== repo || generation != token) throw CancellationException()
    }
    fun disconnect() = synchronized(lock) {
        generation++; job?.cancel(); job = null
        mutable.value.session?.transport?.close()
        mutable.update { it.copy(session = null, phase = VmmConsolePhase.DISCONNECTED, failure = null) }
    }
    fun clear() = synchronized(lock) { disconnect(); bound = null; mutable.value = VmmConsoleState() }
}
