package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import kotlinx.serialization.json.*

internal fun VmmManagementRepository.creationSources(): List<VmmSource> = VmmSource.entries.filter { source ->
    supports(source.guestApi, source.readVersion) && supports(source.guestApi, 1) &&
        (if (source == VmmSource.PUBLIC) supports("SYNO.Virtualization.API.Storage", 1) && supports("SYNO.Virtualization.API.Task.Info", 1)
        else supports("SYNO.Virtualization.Repo", 2) && supports("SYNO.Virtualization.Cluster", 1))
}
internal fun VmmManagementRepository.creationCanPowerOn(source: VmmSource) = supports("${source.guestApi}.Action", 1)
private fun JsonObject.ref(id: String, name: String) = VmmCreationRef(vmmRequiredText(id).also { if (!validVmmId(it)) vmmInvalid() }, vmmRequiredText(name))
private fun <T> unique(values: List<T>, key: (T) -> Any): List<T> = values.also { if (it.map(key).distinct().size != it.size) vmmInvalid() }

/** 资源读取失败仅关闭对应选项；认证、证书、归属和取消异常不得降级。 */
internal suspend fun VmmManagementRepository.creationResources(source: VmmSource): VmmCreationResources {
    if (source !in creationSources()) vmmUnsupported()
    val public = source == VmmSource.PUBLIC
    val storageData = call(if (public) "SYNO.Virtualization.API.Storage" else "SYNO.Virtualization.Repo", "list", source.readVersion)
    val storageRows = vmmRows(storageData, if (public) "storages" else "repos")
    val storageFrozen = !public && storageData.vmmBool("is_freeze")
    val storages = unique(storageRows.map { row ->
        val value = if (public) VmmCreationStorage(row.ref("storage_id", "storage_name")) else {
            val allocated = row["allocated_size"] as? JsonPrimitive ?: vmmInvalid()
            val bytes = allocated.longOrNull?.takeIf { !allocated.isString && it >= 0 } ?: vmmInvalid()
            val size = row.vmmString("size").also { if (it.toLongOrNull()?.let { n -> n >= 0 } != true) vmmInvalid() }
            VmmCreationStorage(row.ref("repo_id", "name"), row.vmmRequiredText("host_id"), row.vmmRequiredText("host_name"), bytes, size)
        }
        value to (if (public) row.vmmRequiredText("status") in setOf("normal", "healthy", "online", "running")
            else row.vmmRequiredText("status") == "online" && row.vmmRequiredText("status_type") == "healthy")
    }) { it.first.ref.id }.filter { it.second && !storageFrozen }.map { it.first }
    var networksAvailable = false; var imagesAvailable = false
    val networks = try {
        val data = call(if (public) "SYNO.Virtualization.API.Network" else "SYNO.Virtualization.Network", "list", source.readVersion)
        val values = unique(vmmRows(data, "networks").map { it.ref("network_id", if (public) "network_name" else "name") }) { it.id }
        networksAvailable = public || !data.vmmBool("is_freeze")
        if (networksAvailable) values else emptyList()
    } catch (error: Exception) { vmmRethrowCritical(error); emptyList() }
    val images = try {
        val data = call("${source.guestApi}.Image", "list", source.readVersion)
        val values = unique(vmmRows(data, "images").map { row ->
            val value = VmmCreationImage(row.ref(if (public) "image_id" else "id", if (public) "image_name" else "name"),
                row.vmmRequiredText("type"), if (public) "" else row.vmmRequiredText("repo_id"), if (public) "" else row.vmmRequiredText("host_id"))
            value to (public || row.vmmRequiredText("status") == "online" && row.vmmRequiredText("status_type") == "healthy")
        }) { Triple(it.first.ref.id, it.first.storage, it.first.host) }
        imagesAvailable = public || !data.vmmBool("is_freeze")
        if (imagesAvailable) values.filter { it.second && it.first.type == if (public) "disk" else "iso" }.map { it.first } else emptyList()
    } catch (error: Exception) { vmmRethrowCritical(error); emptyList() }
    return VmmCreationResources(source, storages, networks, images, networksAvailable, imagesAvailable)
}

internal suspend fun VmmManagementRepository.validateCreationResources(plan: VmmCreationPlan): VmmCreationStorage {
    val resources = creationResources(plan.source)
    val storage = resources.storages.singleOrNull { it.sameIdentity(plan.storage) } ?: vmmConflict()
    if (plan.networks.filterNotNull().any { it !in resources.networks } ||
        plan.disks.mapNotNull { it.image }.any { image -> resources.images.none { it.ref == image && it.type == "disk" } } ||
        plan.iso?.let { it !in resources.images } == true) vmmConflict()
    return storage
}
