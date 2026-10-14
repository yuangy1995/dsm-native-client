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

class FileISOMountFeatureModelTest {
    private val profile = NasProfile("iso-model", "NAS", "https://synthetic.example.invalid", "synthetic")
    private val connection = FileMountConnection(FileMountKind.ISO, "/synthetic/disc.iso", "/synthetic/mount", false)
    private val owner = WorkspaceOwner(profile.id, "identity", "session")
    @Volatile private var source = connection.source
    @Volatile private var canRead = true
    @Volatile private var gate: CountDownLatch? = null
    @Volatile private var entered: CountDownLatch? = null
    private var opened: FileItem? = null
    private val repository = authorizedRepository(profile, DsmSession(profile.id, "synthetic"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request(); val form = request.body as FormBody
            val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
            val data = when (fields["api"]) {
                MOUNT_LIST_API -> buildJsonObject {
                    putJsonObject("mountConfig") { put("enable_iso_mount", true); put("enable_remote_mount", true) }
                    putJsonArray("remoteList") {}; putJsonArray("isoList") { add(buildJsonObject {
                        put("type", "iso"); put("source", source); put("mount_point", connection.mountPoint); put("auto_mount", false)
                    }) }
                }
                "SYNO.FileStation.List" -> {
                    entered?.countDown(); gate?.await(5, TimeUnit.SECONDS)
                    buildJsonObject { putJsonArray("files") { add(buildJsonObject {
                        put("path", connection.mountPoint); put("name", "mount"); put("isdir", true)
                        putJsonObject("additional") { put("mount_point_type", "iso"); putJsonObject("perm") { putJsonObject("acl") { put("read", canRead) } } }
                    }) } }
                }
                else -> error("Unexpected request")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()), listOf(ApiCapability(MOUNT_LIST_API, "entry.cgi", 1, 1), ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2)).associateBy(ApiCapability::name)).also {
        it.bindOwner(owner) {}; it.fileMounts.bindRecovery(FileISOMountRecoveryStore(MemoryPreferences()))
        it.fileMounts.remote.bindRecovery(FileRemoteMountRecoveryStore(MemoryPreferences()))
    }
    private var active: DsmRepository? = repository
    private var workspace = WorkspaceState(profile, availability = repository.availability(), selectedModule = Module.FILES)
    private fun model(scope: CoroutineScope) = FileISOMountFeatureModel(scope, { active }, { workspace }, {}, {}, { opened = it })
    private suspend fun ready(model: FileISOMountFeatureModel) = withTimeout(5_000) {
        while (model.state.value.inventory !is Loadable.Ready) delay(10)
    }
    @Test fun newMountOpensFromFreshServerItemWithoutRecentLocationMembership() = runBlocking {
        val model = model(this); assertTrue(model.openManager()); ready(model); model.browse(connection)
        withTimeout(5_000) { while (opened == null) delay(10) }
        assertEquals(connection.mountPoint, opened!!.path); assertTrue(opened!!.canRead)
        assertNull(model.state.value.screen)
    }
    @Test fun changedConnectionOrRevokedReadAccessCannotOpenOldMount() = runBlocking {
        for (replaceIdentity in listOf(true, false)) {
            source = connection.source; canRead = true
            val model = model(this); assertTrue(model.openManager()); ready(model)
            if (replaceIdentity) source = "/synthetic/other.iso" else canRead = false
            model.browse(connection)
            withTimeout(5_000) { while (model.state.value.inventory !is Loadable.Failed) delay(10) }
            assertNull(opened); model.close()
        }
    }
    @Test fun lateDirectoryReadAfterLeavingFilesDoesNotNavigate() = runBlocking {
        val model = model(this); assertTrue(model.openManager()); ready(model)
        gate = CountDownLatch(1); entered = CountDownLatch(1); model.browse(connection)
        withContext(Dispatchers.IO) { assertTrue(entered!!.await(5, TimeUnit.SECONDS)) }
        workspace = workspace.copy(selectedModule = Module.SETTINGS)
        gate!!.countDown()
        coroutineContext[Job]!!.children.toList().forEach { it.join() }
        assertNull(opened); model.invalidate()
    }
}
