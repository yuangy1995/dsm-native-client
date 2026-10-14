package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable enum class ContainerAction { START, STOP, RESTART, DELETE }

/** 原生状态和稳定身份独立于展示状态；缺失布尔值不能补成允许。 */
data class ContainerControlTarget(
    val id: String,
    val name: String,
    val running: Boolean?,
    val paused: Boolean?,
    val restarting: Boolean?,
    val startedAt: Long?,
    val managed: Boolean?,
) {
    fun supports(action: ContainerAction): Boolean {
        if (managed != false || paused != false || running == null || restarting == null) return false
        return when (action) {
            ContainerAction.START, ContainerAction.DELETE -> !running && !restarting
            ContainerAction.STOP -> running || restarting
            ContainerAction.RESTART -> (running || restarting) && startedAt != null
        }
    }
    fun matches(action: ContainerAction, previousStartedAt: Long?): Boolean {
        if (managed != false || paused != false || restarting != false) return false
        return when (action) {
            ContainerAction.START -> running == true
            ContainerAction.STOP -> running == false
            ContainerAction.RESTART -> running == true && startedAt != null && previousStartedAt != null && startedAt > previousStartedAt
            ContainerAction.DELETE -> false
        }
    }
    val resource get() = ManagedResource(id, name, "", when {
        paused == true -> ResourceState.PAUSED
        restarting == true -> ResourceState.WAITING
        running == true -> ResourceState.RUNNING
        running == false -> ResourceState.STOPPED
        else -> ResourceState.UNKNOWN
    })
}
