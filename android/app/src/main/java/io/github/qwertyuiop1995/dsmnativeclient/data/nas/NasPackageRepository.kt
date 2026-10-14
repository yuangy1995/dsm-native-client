package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.*

internal interface NasManagementGateway {
    suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement> = emptyMap(), write: Boolean = false): JsonObject
    suspend fun requireWriteAccess()
}
internal interface NasPackageGateway : NasManagementGateway {
    suspend fun upload(source: UploadSource): JsonObject
}
internal data class PackageCandidate(val entry: NasPackageEntry, val raw: JsonObject) {
    val quick get() = entry.official && raw[if (entry.installedVersion == null) "qinst" else "qupgrade"].packageBoolean() != false &&
        (raw["info"] as? JsonObject)?.get("blqinst").packageBoolean() != false
}
internal data class PackageInstalled(val id: String, val version: String, val status: String, val upgrade: JsonObject?)
internal data class PackagePlan(val value: NasPackageInstallPlan, val requested: List<String>, val candidates: List<PackageCandidate>,
    val queue: JsonObject, val installed: Map<String, String>)
internal class PackageCheckpointFailure(val source: Exception) : RuntimeException(source)

/** 同一连接只有一条套件写入管线；所有提交检查点先落盘，未知结果不重放。 */
internal class NasPackageRepository(internal val gateway: NasPackageGateway,
    internal val controlSupports: (String, Int) -> Boolean = { _, _ -> false },
    internal val controlReader: suspend () -> List<PackageInfo> = { packageFailure() },
    internal val controlPause: suspend () -> Unit = { kotlinx.coroutines.delay(1_000) },
) {
    internal val lock = Mutex()
    internal var plan: PackagePlan? = null
    internal var job: PackageJob? = null
    internal var preferencePending = false
    internal var recoveryPending: () -> Boolean = { false }
    internal var candidates: Map<String, PackageCandidate> = emptyMap()
    internal suspend fun <T> exclusive(block: suspend () -> T): T {
        if (!lock.tryLock()) packageFailure(NasPackageProblem.BUSY)
        try { return block() } catch (failure: PackageCheckpointFailure) { throw failure.source } finally { lock.unlock() }
    }
    internal fun requireIdle() {
        if (preferencePending || recoveryPending() || job?.phase?.let { it !in setOf(NasPackageInstallPhase.COMPLETED, NasPackageInstallPhase.FAILED, NasPackageInstallPhase.CANCELLED) } == true) packageFailure(NasPackageProblem.BUSY)
    }
    internal suspend fun notify(event: NasPackageCheckpoint, observer: NasPackageObserver) {
        try { observer(event) } catch (error: Exception) { throw PackageCheckpointFailure(error) }
    }
    internal suspend fun write(api: String, method: String, parameters: Map<String, JsonElement>, event: NasPackageCheckpoint,
        observer: NasPackageObserver): JsonObject {
        currentCoroutineContext().ensureActive()
        gateway.requireWriteAccess()
        notify(event.copy(stage = NasPackageWriteStage.WILL_SUBMIT), observer)
        currentCoroutineContext().ensureActive()
        val value = gateway.call(api, method, 1, parameters, write = true)
        notify(event.copy(stage = NasPackageWriteStage.ACCEPTED), observer)
        return value
    }
    internal suspend fun installed(): List<PackageInstalled> {
        val data = gateway.call(PACKAGE_API, "list", 2, mapOf("offset" to JsonPrimitive(0), "limit" to JsonPrimitive(1000),
            "additional" to packageStrings(listOf("status", "description", "install_type", "startable", "dsm_apps", "available_operation", "ctl_uninstall"))))
        val seen = mutableSetOf<String>()
        return packageRows(data, "packages", bounded = true).map { row ->
            val id = row.packageText("id")
            if (!seen.add(id) || id.any(Char::isISOControl)) packageFailure()
            val info = row["additional"].packageObject()
            val operation = info["available_operation"] ?: row["available_operation"]
            if (operation != null && operation !is JsonNull && operation !is JsonObject && operation !is JsonArray && operation.packageString() == null) packageFailure()
            val upgrade = (operation as? JsonObject)?.get("upgrade") as? JsonObject
            PackageInstalled(id, row.packageText("version"), info["status"].packageString() ?: row["status"].packageString() ?: packageFailure(), upgrade)
        }
    }
    suspend fun catalog(): NasPackageCatalog = exclusive { readCatalog() }
    internal suspend fun readCatalog(): NasPackageCatalog {
        val installed = installed()
        val official = gateway.call("SYNO.Core.Package.Server", "list", 2,
            mapOf("blforcereload" to JsonPrimitive(false), "blloadothers" to JsonPrimitive(false)))
        val rows = (official["packages"].packageArray() + official["beta_packages"].packageArray()).toMutableList()
        var communityAvailable = true
        try {
            rows.addAll(gateway.call("SYNO.Core.Package.Server", "list", 2,
                mapOf("blforcereload" to JsonPrimitive(false), "blloadothers" to JsonPrimitive(true)))["packages"].packageArray())
        } catch (error: Exception) { if (error.packageTrustFailure()) throw error; communityAvailable = false }
        val next = mutableMapOf<String, PackageCandidate>()
        for (row in rows) {
            val candidate = candidate(row.packageObject(), installed)
            val previous = next[candidate.entry.id]
            if (previous == null || previous == candidate || !previous.entry.official) next[candidate.entry.id] = candidate
        }
        for (current in installed) current.upgrade?.let { raw ->
            val candidate = candidate(raw, installed, upgradeId = current.id)
            next[candidate.entry.id] = candidate
        }
        val categories = (official["categories"] as? JsonArray).orEmpty().map { row ->
            row.packageObject().let { NasPackageChoice(it.packageText("id"), it.packageText("dname")) }
        }
        if (categories.map { it.id }.distinct().size != categories.size) packageFailure()
        candidates = next
        return NasPackageCatalog(next.values.map { it.entry }.sortedBy { it.name.lowercase() }, categories, communityAvailable)
    }
    internal fun candidate(raw: JsonObject, installed: List<PackageInstalled>, upgradeId: String? = null): PackageCandidate {
        val id = raw.packageText("id"); val version = raw.packageText("version")
        if (id.any(Char::isISOControl) || upgradeId != null && id != upgradeId) packageFailure()
        for (key in listOf("beta", "qinst", "qupgrade")) if (raw[key] != null && raw[key] !is JsonNull && raw[key].packageBoolean() == null) packageFailure()
        val info = raw["info"]?.takeUnless { it is JsonNull }?.packageObject()
        if (info?.get("blqinst") != null && info["blqinst"] !is JsonNull && info["blqinst"].packageBoolean() == null) packageFailure()
        val current = installed.singleOrNull { it.id == id }
        val categories = raw["category"]?.takeUnless { it is JsonNull }?.packageArray()?.map { it.packageString() ?: packageFailure() }.orEmpty()
        return PackageCandidate(NasPackageEntry(id, raw["dname"].packageString() ?: raw.packageText("name"), version,
            raw["desc"].packageString() ?: raw["description"].packageString().orEmpty(), raw["changelog"].packageString().orEmpty(),
            raw["distributor"].packageString() ?: raw["maintainer"].packageString().orEmpty(), categories,
            raw["beta"].packageBoolean() == true, raw["source"].packageString() == "syno", raw["size"].packageLong(),
            current?.version, current != null && current.version != version && upgradeId != null), raw)
    }
    suspend fun prepare(ids: List<String>): NasPackageInstallPlan = exclusive {
        requireIdle(); plan = null
        readCatalog()
        if (ids.isEmpty() || ids.distinct().size != ids.size) packageFailure(NasPackageProblem.CHANGED)
        val requested = ids.map { id -> candidates[id]?.takeIf { it.entry.installedVersion == null || it.entry.updateAvailable }
            ?: packageFailure(NasPackageProblem.CHANGED) }
        val value = buildPlan(requested)
        currentCoroutineContext().ensureActive(); plan = value; value.value
    }
    internal suspend fun feasibility(ids: List<String>) {
        gateway.call(PACKAGE_API, "feasibility_check", 1, mapOf("type" to JsonPrimitive("install_check"), "packages" to packageStrings(ids)))
    }
    internal suspend fun buildPlan(requested: List<PackageCandidate>): PackagePlan {
        if (requested.any { it.entry.beta }) {
            val agreement = gateway.call("SYNO.Core.Package.Info", "get", 1)["prerelease"].packageObject()
            if (agreement["success"].packageBoolean() != true || agreement["agreed"].packageBoolean() != true) packageFailure(NasPackageProblem.BETA_AGREEMENT)
        }
        feasibility(requested.map { it.entry.packageId })
        val queue = gateway.call(PACKAGE_INSTALL, "get_queue", 1, mapOf("pkgs" to JsonArray(requested.map { candidate ->
            buildJsonObject { put("pkg", candidate.entry.packageId); put("operation", "install"); put("version", candidate.entry.version); put("beta", candidate.entry.beta) }
        })))
        if (queue["non_exist_pkgs"].packageArray().isNotEmpty() || queue["conflicted_pkgs"].packageArray().isNotEmpty()) packageFailure(NasPackageProblem.DEPENDENCIES)
        val affected = listOf("broken_pkgs", "replaced_pkgs", "paused_pkgs").flatMap { key -> queue[key].packageArray().map { it.packageString() ?: packageFailure() } }.distinct().sorted()
        val selected = queue["queue"].packageArray().map { raw ->
            val step = raw.packageObject(); val id = step.packageText("pkg"); val beta = step.packageFlag("beta")
            val candidate = candidates[id + if (beta) ":beta" else ":stable"] ?: packageFailure()
            if (step["version"] != null && step["version"].packageString() != candidate.entry.version) packageFailure(NasPackageProblem.CHANGED)
            candidate
        }
        if (selected.isEmpty() || selected.map { it.entry.packageId }.distinct().size != selected.size ||
            requested.any { requestedItem -> selected.none { it == requestedItem } }) packageFailure()
        val items = selected.map { environment(it) }
        val installed = installed().associate { it.id to it.version }
        return PackagePlan(NasPackageInstallPlan(UUID.randomUUID().toString(), items, affected), requested.map { it.entry.id }, selected, queue, installed)
    }
    internal suspend fun environment(candidate: PackageCandidate): NasPackageInstallItem {
        val parameters = mutableMapOf<String, JsonElement>("id" to JsonPrimitive(candidate.entry.packageId), "ver" to JsonPrimitive(candidate.entry.version),
            "blupgrade" to JsonPrimitive(candidate.entry.installedVersion != null), "blCheckDep" to JsonPrimitive(false))
        for (key in listOf("depsers", "deppkgs", "conflictpkgs", "breakpkgs", "replacepkgs", "size", "install_type", "install_on_cold_storage")) {
            candidate.raw[key]?.takeUnless { it is JsonNull }?.let { parameters[key] = it }
        }
        val data = gateway.call(PACKAGE_INSTALL, "check", 2, parameters)
        if (data["is_occupied"].packageBoolean() != false) packageFailure(NasPackageProblem.BUSY)
        val system = candidate.raw["install_type"].packageString() in setOf("system", "system_hidden")
        val volumes = if (system && (data["volume_list"] == null || data["volume_list"] is JsonNull)) emptyList() else packageVolumes(data["volume_list"])
        if (volumes.isEmpty() && !system) packageFailure(NasPackageProblem.VOLUME)
        return NasPackageInstallItem(candidate.entry, volumes, data["volume_path"].packageString() ?: volumes.singleOrNull()?.id.orEmpty())
    }
}
