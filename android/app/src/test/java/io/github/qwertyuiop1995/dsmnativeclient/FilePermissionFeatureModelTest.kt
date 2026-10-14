package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class FilePermissionFeatureModelTest {
    private val profile = NasProfile("permission-model", "NAS", "https://synthetic.example.invalid", "synthetic")
    private val item = FileItem("/synthetic/item", "item", true, mountPointType = "normal")
    private val owner = WorkspaceOwner(profile.id, "identity", "generation")
    private val rule = FileACLRule("user", "synthetic-user", 1000, null, FileACLEffect.ALLOW,
        setOf(FileACLRight.READ_DATA), setOf(FileACLInheritance.THIS_FOLDER))
    private val preferences = MemoryPreferences()
    @Volatile private var gate: CountDownLatch? = null
    @Volatile private var reads = 0
    @Volatile private var writes = 0
    private val repository = authorizedRepository(profile, DsmSession(profile.id, "synthetic"), DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
        val request = chain.request(); val form = request.body as FormBody
        val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
        val data = when (fields["api"]) {
            "SYNO.FileStation.List" -> {
                reads++; gate?.await(5, TimeUnit.SECONDS)
                buildJsonObject { putJsonArray("files") { add(buildJsonObject {
                    put("path", item.path); put("name", item.name); put("isdir", true)
                    putJsonObject("additional") { put("real_path", "/volume-synthetic/item"); put("mount_point_type", "normal")
                        putJsonObject("perm") { put("is_acl_mode", true) } }
                }) } }
            }
            "SYNO.FileStation.Property.ACLOwner" -> buildJsonObject { put("name", rule.ownerName); put("type", "user"); put("value", "1000"); put("hasPrivilege", true) }
            PERMISSION_ACL_API -> when (fields["method"]) {
                "get" -> buildJsonObject { put("is_acl", true); put("change_permission", true); put("is_inherited", false)
                    putJsonArray("acl") { add(JsonObject(permissionRulePayload(rule) + ("level" to JsonPrimitive(0)))) } }
                "set" -> { writes++; buildJsonObject {} }
                else -> buildJsonObject { put("is_denied", false) }
            }
            else -> error("Unexpected synthetic request")
        }
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
    }.build()), listOf(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2), ApiCapability(PERMISSION_ACL_API, "entry.cgi", 1, 1),
        ApiCapability("SYNO.FileStation.Property.ACLOwner", "entry.cgi", 1, 1)).associateBy(ApiCapability::name)).also {
        it.bindOwner(owner) {}; it.filePermissions.bindRecovery(FilePermissionRecoveryStore(preferences))
        it.fileMounts.bindRecovery(FileISOMountRecoveryStore(MemoryPreferences()))
        it.fileMounts.remote.bindRecovery(FileRemoteMountRecoveryStore(MemoryPreferences()))
    }
    private var active: DsmRepository? = repository
    private var workspace = WorkspaceState(profile, availability = repository.availability(), selectedModule = Module.FILES)
    private fun feature(scope: CoroutineScope) = FilePermissionFeatureModel(scope, { active }, { workspace },
        { busy -> workspace = workspace.copy(isPerformingAction = busy) }, {})
    private suspend fun loaded(model: FilePermissionFeatureModel) = withTimeout(5_000) {
        while (model.state.value.snapshot !is Loadable.Ready || !model.state.value.recoveryReadable) delay(10)
    }

    @Test fun changingDraftRevokesPriorRiskConfirmation() = runBlocking {
        val feature = feature(this); assertTrue(feature.open(item)); loaded(feature)
        feature.edit { it.copy(rules = emptyList()) }; feature.submit(); assertTrue(feature.state.value.confirmation)
        feature.edit { it.copy(recursive = true) }; assertFalse(feature.state.value.confirmation)
        feature.submit(confirmed = true); assertEquals(0, writes); assertFalse(feature.state.value.busy)
    }

    @Test fun moduleExitOrAnotherWorkspaceRejectsStaleConfirmationBeforeAnyWrite() = runBlocking {
        val feature = feature(this); feature.open(item); loaded(feature)
        feature.edit { it.copy(rules = emptyList()) }; feature.submit()
        workspace = workspace.copy(selectedModule = Module.SETTINGS); feature.submit(true)
        assertEquals(0, writes)
        workspace = workspace.copy(selectedModule = Module.FILES); active = null; feature.submit(true)
        assertEquals(0, writes)
    }

    @Test fun lateReadFromPreviousRepositoryCannotPopulateCurrentEditor() = runBlocking {
        val feature = feature(this); gate = CountDownLatch(1); feature.open(item)
        withTimeout(5_000) { while (reads == 0) delay(10) }
        active = null; feature.invalidate(); gate?.countDown(); gate = null
        delay(100)
        assertNull(feature.state.value.path); assertEquals(Loadable.Idle, feature.state.value.snapshot)
        assertEquals(0, writes)
    }

    @Test fun unreadableRecoveryKeepsCurrentPermissionsVisibleButBlocksEditing() = runBlocking {
        val key = "permissions_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
            .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray())
        preferences.edit().putString(key, "synthetic-invalid-json").commit()
        val feature = feature(this); feature.open(item)
        withTimeout(5_000) { while (feature.state.value.snapshot !is Loadable.Ready) delay(10) }
        assertFalse(feature.state.value.recoveryReadable); assertNotNull(feature.state.value.failure)
        feature.edit { it.copy(rules = emptyList()) }; feature.submit(true)
        assertFalse(feature.canSubmit()); assertEquals(listOf(rule), feature.state.value.draft.rules); assertEquals(0, writes)
    }
}
