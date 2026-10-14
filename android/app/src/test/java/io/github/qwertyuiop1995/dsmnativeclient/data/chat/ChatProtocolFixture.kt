package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.io.ByteArrayInputStream
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

/** 原始合成HTTP经过正式认证、参数编码、解码与执行器；不映射旧MutationResult。 */
internal class ChatProtocolFixture(val channelId: String = "channel-1", maximumVersion: Int = 5, reminderVersion: Int = 1, scheduleVersion: Int = 1, voteVersion: Int = 1, anonymousVersion: Int = 2) : Interceptor {
    val requests = CopyOnWriteArrayList<Request>()
    var channels = """[{"channel_id":"$channelId","name":"Synthetic","type":"private","members":[1,2]}]"""
    var members = listOf("1", "2", "3")
    var posts = "[]"
    var reminders = "[]"
    var schedules = "[]"
    var reminderFailure: Exception? = null
    var scheduleFailure: Exception? = null
    var channelFailure: Exception? = null
    var readFailure: Exception? = null
    var write: (Request) -> String = { """{"success":true,"data":{"post_id":"post-1"}}""" }
    val owner = WorkspaceOwner("test", "synthetic-identity", "synthetic-generation")
    val preferences = MemoryPreferences()
    val store = ChatActionStore(preferences)
    val repository = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(this).build()),
        mapOf(
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1),
            "SYNO.Core.Package" to ApiCapability("SYNO.Core.Package", "entry.cgi", 1, 2),
            "SYNO.Chat.Post" to ApiCapability("SYNO.Chat.Post", "entry.cgi", 1, maximumVersion),
            "SYNO.Chat.User" to ApiCapability("SYNO.Chat.User", "entry.cgi", 1, 1),
            "SYNO.Chat.Channel" to ApiCapability("SYNO.Chat.Channel", "entry.cgi", 1, 5),
            "SYNO.Chat.Channel.Anonymous" to ApiCapability("SYNO.Chat.Channel.Anonymous", "entry.cgi", 1, anonymousVersion),
            "SYNO.Chat.Channel.Named" to ApiCapability("SYNO.Chat.Channel.Named", "entry.cgi", 1, 1),
            "SYNO.Chat.Channel.Member" to ApiCapability("SYNO.Chat.Channel.Member", "entry.cgi", 1, 1),
            "SYNO.Chat.Post.Reminder" to ApiCapability("SYNO.Chat.Post.Reminder", "entry.cgi", reminderVersion, reminderVersion),
            "SYNO.Chat.Post.Schedule" to ApiCapability("SYNO.Chat.Post.Schedule", "entry.cgi", scheduleVersion, scheduleVersion),
            "SYNO.Chat.Post.Vote" to ApiCapability("SYNO.Chat.Post.Vote", "entry.cgi", voteVersion, voteVersion),
        ),
    )
    val repo get() = repository.chatRepository
    val writes get() = requests.filter { it.chatFields()["method"] in setOf("create", "set", "delete", "initiate", "join", "invite") }
    val postReads get() = requests.filter { it.chatFields()["api"] == "SYNO.Chat.Post" && it.chatFields()["method"] == "list" }

    suspend fun prepare(draft: ChatActionDraft, id: String = "request-1"): ChatPreparedAction =
        repo.prepareAction(draft, id).also { store.begin(ChatActionRecord(owner = owner, checkpoint = it.checkpoint)) }

    suspend fun execute(action: ChatPreparedAction, onProgress: (Long, Long) -> Unit = { _, _ -> }): ChatActionOutcome =
        store.execute(action.checkpoint.id) {
            val checkpoint = store.get(owner, action.checkpoint.id).checkpoint
            store.requireNoConflict(ChatActionRecord(owner = owner, checkpoint = checkpoint))
            repo.executeAction(action, checkpoint, onProgress) { store.save(owner, it) }
        }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.chatFields()
        val body = when (fields["api"] to fields["method"]) {
            "SYNO.Core.System" to "info" -> """{"success":true,"data":{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}}"""
            "SYNO.Core.Package" to "list" -> """{"success":true,"data":{"total":1,"packages":[{"id":"Chat","name":"Chat","version":"2.4.1-22111","status":"running","startable":true,"available_operation":[],"dsm_apps":[]}]}}"""
            "SYNO.Chat.User" to "list" -> """{"success":true,"data":{"current_user_id":"1","users":[{"user_id":"1","username":"operator"},{"user_id":"2","username":"peer"},{"user_id":"3","username":"third"}]}}"""
            "SYNO.Chat.Channel" to "list" -> { channelFailure?.let { throw it }; """{"success":true,"data":{"channels":$channels}}""" }
            "SYNO.Chat.Channel.Member" to "get" -> """{"success":true,"data":{"user_ids":${JsonArray(members.map(::JsonPrimitive))},"broken_user_ids":[]}}"""
            "SYNO.Chat.Post" to "list" -> {
                readFailure?.let { throw it }
                """{"success":true,"data":{"posts":$posts}}"""
            }
            "SYNO.Chat.Post.Reminder" to "list" -> {
                reminderFailure?.let { throw it }
                """{"success":true,"data":{"reminders":$reminders}}"""
            }
            "SYNO.Chat.Post.Schedule" to "list" -> {
                scheduleFailure?.let { throw it }
                """{"success":true,"data":{"schedules":$schedules}}"""
            }
            "SYNO.Chat.Post" to "create", "SYNO.Chat.Post.Reminder" to "set", "SYNO.Chat.Post.Reminder" to "delete",
            "SYNO.Chat.Post.Schedule" to "create", "SYNO.Chat.Post.Schedule" to "delete", "SYNO.Chat.Post.Vote" to "create",
            "SYNO.Chat.Channel.Anonymous" to "initiate", "SYNO.Chat.Channel.Named" to "create",
            "SYNO.Chat.Channel.Named" to "join", "SYNO.Chat.Channel.Named" to "invite" -> {
                check(store.records(owner).any { it.checkpoint.phase == ChatActionPhase.SUBMITTED })
                check(request.body?.isOneShot() == true)
                if (request.fixtureBody() is MultipartBody) request.body!!.writeTo(Buffer())
                write(request)
            }
            else -> error("Unexpected synthetic Chat request: ${fields["api"]}/${fields["method"]}")
        }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(body.toResponseBody("application/json".toMediaType())).build()
    }

    fun post(text: String = "hello", attachment: Boolean = false, id: String = "post-1", name: String = "sample.txt", size: Long = 9): String = buildJsonObject {
        put("post_id", id); put("channel_id", channelId); put("creator_id", "1"); put("message", text)
        put("create_at", 1700000000000); put("thread_id", "0")
        if (attachment) putJsonArray("files") { add(buildJsonObject { put("file_id", "file-1"); put("file_name", name); put("size", size) }) }
    }.toString()

    fun directChannel() = """[{"channel_id":"27","type":"anonymous","members":[1,2],"member_count":2}]"""
    fun groupChannel(name: String = "Group") = buildJsonArray { add(buildJsonObject {
        put("channel_id", "42"); put("type", "private"); put("name", name)
        put("members", JsonArray(members.map(::JsonPrimitive))); put("member_count", members.size)
    }) }.toString()

    fun poll(text: String = "Question?", options: List<String> = listOf("First", "Second"), multiple: Boolean = true,
        anonymous: Boolean = false, id: String = "post-1"): String = JsonObject(
        (Json.parseToJsonElement(post(text, id = id)) as JsonObject) + ("props" to buildJsonObject {
            putJsonObject("vote") {
                put("vote_id", "vote-1"); put("state", "open")
                putJsonObject("options") { put("multiple", multiple); put("anonymous", anonymous); put("expire_at", 0) }
                putJsonArray("choices") { options.forEachIndexed { index, text ->
                    add(buildJsonObject { put("id", "choice-$index"); put("text", text); put("count", 0) })
                } }
            }
        })
    ).toString()

    fun reminder(time: Long, id: String = "post-1") =
        """{"reminder_id":"reminder-1","post_id":"$id","channel_id":"$channelId","remind_at":$time}"""

    fun schedule(time: Long, text: String = "Synthetic scheduled text", id: String = "schedule-1") = buildJsonObject {
        put("cronjob_id", id); put("channel_id", channelId); put("message", text); put("send_at", time)
    }.toString()

    fun source(name: String = "sample.txt", bytes: ByteArray = "synthetic".toByteArray()) =
        UploadSource(name, "text/plain", bytes.size.toLong(), openInputStream = { ByteArrayInputStream(bytes) })
}

internal fun Request.chatFields(): Map<String, String> = when (val body = fixtureBody()) {
    is FormBody -> (0 until body.size).associate { body.name(it) to body.value(it) }
    is MultipartBody -> buildMap {
        body.parts.forEach { part ->
            val disposition = part.headers?.get("Content-Disposition").orEmpty()
            val name = Regex("name=\"([^\"]+)\"").find(disposition)?.groupValues?.get(1) ?: return@forEach
            if ("filename=" !in disposition) put(name, Buffer().also { part.body.writeTo(it) }.readUtf8())
        }
    }
    else -> url.queryParameterNames.associateWith { url.queryParameter(it).orEmpty() }
}
