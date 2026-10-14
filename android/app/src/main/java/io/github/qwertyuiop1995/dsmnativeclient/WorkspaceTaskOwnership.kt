package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmConnectionResolver
import io.github.qwertyuiop1995.dsmnativeclient.storage.*

/** 新记录必须由发起任务的 Repository 绑定；恢复不能根据当前选中的账号补猜归属。 */
internal class WorkspaceTaskOwnership(private val store: SecureProfileStore) {
    fun canUse(kind: WorkspaceRecordKind, id: String, repo: DsmRepository?): Boolean =
        repo != null && runCatching { require(kind, id, repo) }.isSuccess
    fun bind(kind: WorkspaceRecordKind, id: String, repo: DsmRepository) {
        val owner = repo.owner ?: throw workspaceChangedFailure()
        repo.requireCurrentOwner()
        store.bindRecord(kind, id, owner)
    }

    fun require(kind: WorkspaceRecordKind, id: String, repo: DsmRepository) {
        val owner = repo.owner ?: throw workspaceChangedFailure()
        repo.requireCurrentOwner()
        store.requireRecordOwner(kind, id, owner)
    }
}

internal suspend fun restoreTaskRepository(
    context: Context, kind: WorkspaceRecordKind, id: String, profileId: String,
): DsmRepository {
    val store = SecureProfileStore(context)
    val connection = store.savedConnectionForRecord(kind, id)
    if (connection.profile.id != profileId) throw workspaceChangedFailure()
    val lease = store.lease(connection.owner)
    val api = DsmApiClient(io.github.qwertyuiop1995.dsmnativeclient.network.LocalNetworkAccess(context).httpClient())
        .authorized({ lease.requireCurrent() })
    val discovered = DsmConnectionResolver(api).discover(connection.profile)
    val repo = DsmRepository(discovered.profile, connection.session, api, discovered.capabilities)
    repo.bindOwner(connection.owner, lease::requireCurrent)
    repo.refreshAccess(true)
    return repo
}
