package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.MAX_VIRTUAL_MACHINE_DISKS
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable internal enum class VmmCreationPreset { GENERAL, LINUX, WINDOWS, OTHER }
@Serializable internal data class VmmCreationRef(val id: String, val name: String)
@Serializable internal data class VmmCreationStorage(val ref: VmmCreationRef, val host: String = "", val hostName: String = "",
    val allocated: Long = 0, val size: String = "0") {
    fun sameIdentity(other: VmmCreationStorage) = ref == other.ref && host == other.host && hostName == other.hostName
}
@Serializable internal data class VmmCreationImage(val ref: VmmCreationRef, val type: String, val storage: String = "", val host: String = "")
@Serializable internal data class VmmCreationDisk(val gib: Int = 20, val image: VmmCreationRef? = null)
internal data class VmmCreationResources(val source: VmmSource, val storages: List<VmmCreationStorage>,
    val networks: List<VmmCreationRef>, val images: List<VmmCreationImage>, val networksAvailable: Boolean, val imagesAvailable: Boolean)
@Serializable internal data class VmmCreationPlan(val preset: VmmCreationPreset, val configuration: VmmConfiguration,
    val storage: VmmCreationStorage, val disks: List<VmmCreationDisk>, val networks: List<VmmCreationRef?>,
    val uefi: Boolean = true, val iso: VmmCreationImage? = null, val powerOn: Boolean = false) {
    val source get() = if (preset == VmmCreationPreset.GENERAL) VmmSource.PUBLIC else VmmSource.INTERNAL
    fun valid() = validVmmSettingsName(configuration.name) && configuration.description != null && configuration.description.length <= 1024 &&
        configuration.cpu in 1..64 && configuration.memoryMiB in 128..1_048_576 && configuration.startup in 0..2 &&
        configuration.priority == (if (source == VmmSource.INTERNAL) 256 else null) && validVmmId(storage.ref.id) && storage.ref.name.isNotBlank() &&
        disks.size in 1..MAX_VIRTUAL_MACHINE_DISKS && networks.isNotEmpty() && networks.all { it == null || validVmmId(it.id) && it.name.isNotBlank() } &&
        disks.all { if (it.image == null) it.gib in (if (source == VmmSource.INTERNAL) 10 else 1)..1_048_576 else validVmmId(it.image.id) && it.image.name.isNotBlank() } &&
        (if (source == VmmSource.PUBLIC) iso == null else disks.size == 1 && disks.single().image == null && networks.size == 1 &&
            validVmmId(storage.host) && storage.hostName.isNotBlank() &&
            (iso == null || iso.type == "iso" && validVmmId(iso.ref.id) && iso.storage == storage.ref.id && iso.host == storage.host))
    override fun toString() = "VmmCreationPlan($preset)"
}

@Serializable internal enum class VmmCreationStage {
    PREPARED, CREATE_SENT, CREATING, CREATED, CONFIGURE_SENT, CONFIGURING, CONFIGURED, POWER_SENT, STARTING, COMPLETE, REJECTED, PARTIAL, CANCELLED;
    val pending get() = this !in setOf(COMPLETE, REJECTED, PARTIAL, CANCELLED)
    val canContinue get() = this in setOf(CREATED, CONFIGURED)
}
@Serializable internal data class VmmCreationSnapshot(val id: String, val plan: VmmCreationPlan, val existingIds: Set<String>,
    val parameters: String, val expected: String?) {
    override fun toString() = "VmmCreationSnapshot(${plan.source})"
}
@Serializable internal data class VmmCreationProgress(val stage: VmmCreationStage = VmmCreationStage.PREPARED,
    val task: String? = null, val guest: String? = null, val percent: Int? = null, val hardware: String? = null, val baseline: VmmConfiguration? = null) {
    override fun toString() = "VmmCreationProgress($stage)"
}

internal fun vmmJsonDigest(value: JsonElement): String {
    fun canonical(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.toSortedMap().mapValues { canonical(it.value) })
        is JsonArray -> JsonArray(element.map(::canonical))
        else -> element
    }
    return vmmDigest(canonical(value).toString())
}
