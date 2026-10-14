package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.net.URLDecoder
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 只拦截正式客户端请求；会话、账号与消息全部是独立的合成测试数据。 */
internal class ChatWorkspaceFixture {
    val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    val capabilities = listOf("User" to 2, "Channel" to 5, "Channel.Member" to 1, "Channel.Named" to 1,
        "Channel.Anonymous" to 2, "Post" to 8, "Post.Vote" to 1, "Post.Reminder" to 1,
        "Post.Schedule" to 1, "Post.Subscribe" to 2, "Admin.Setting" to 3)
        .map { (name, version) -> ApiCapability("SYNO.Chat.$name", "entry.cgi", 1, version) }.associateBy { it.name }
    private val now = System.currentTimeMillis() - 60_000
    private val posts = linkedMapOf("71" to post("71", "Synthetic root", now),
        "72" to post("72", "Synthetic reply", now + 1000, thread = "71"),
        "73" to post("73", "Synthetic second", now + 2000),
        "74" to post("74", "Synthetic poll", now + 3000, vote = true))
    private var serial = 100
    private var lastViewed = 0L
    private var voted = false
    private val closed = mutableSetOf<String>()
    @Volatile var omitReceipt = false
    @Volatile var failSearch = false
    @Volatile var failThreadRoot = false
    @Volatile var searchGate: CountDownLatch? = null
    @Volatile var ignoreDelete = false
    val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
        val request = chain.request()
        if (request.body == null) return@addInterceptor Response.Builder().request(request).protocol(Protocol.HTTP_1_1)
            .code(503).message("Synthetic realtime unavailable").body("".toResponseBody()).build()
        val buffer = Buffer(); request.body!!.writeTo(buffer)
        val fields = buffer.readUtf8().split('&').associate { field ->
            val parts = field.split('=', limit = 2)
            URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8")
        }
        calls += fields
        if (fields["method"] == "search") searchGate?.await(10, TimeUnit.SECONDS)
        val response = if (fields["method"] == "search" && failSearch ||
            fields["api"] == "SYNO.Chat.Post" && fields["method"] == "list" && fields["post_id"] == "71" && fields["prev_count"] == "0" && failThreadRoot) buildJsonObject {
            put("success", false); putJsonObject("error") { put("code", 105) }
        } else buildJsonObject { put("success", true); put("data", response(fields)) }
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(response.toString().toResponseBody("application/json".toMediaType())).build()
    }.build())

    fun writes(method: String) = synchronized(calls) { calls.filter { it["method"] == method } }
    private fun obj(vararg pairs: Pair<String, JsonElement>) = JsonObject(pairs.toMap())
    private fun array(name: String, rows: List<JsonElement>) = obj(name to JsonArray(rows))
    private fun voteChoices() = listOf("a", "b").map { id -> buildJsonObject {
        put("id", id); put("text", if (id == "a") "Synthetic choice A" else "Synthetic choice B")
        put("count", if (id == "b" && voted) 1 else 0)
        putJsonArray("voters") { if (id == "b" && voted) add(1) }
    } }
    private fun post(id: String, body: String, time: Long, channel: String = "11", thread: String = "0", vote: Boolean = false) = buildJsonObject {
        put("post_id", id); put("channel_id", channel); put("creator_id", "1"); put("message", body)
        put("create_at", time); put("thread_id", thread); put("type", "normal"); put("comment_count", if (id == "71") 1 else 0)
        if (vote) putJsonObject("props") { putJsonObject("vote") {
            put("id", "v1"); put("question", body); put("choices", JsonArray(voteChoices()))
            putJsonObject("options") { put("multiple", false); put("anonymous", false); put("expire_at", 0) }
        } }
    }
    @Synchronized private fun response(f: Map<String, String>): JsonObject {
        val method = f.getValue("method"); val id = f["post_id"]
        return when (f["api"]) {
            "SYNO.Chat.User" -> buildJsonObject { put("current_user_id", "1"); putJsonArray("users") {
                add(buildJsonObject { put("user_id", "1"); put("username", "synthetic"); put("nickname", "Synthetic self") })
                add(buildJsonObject { put("user_id", "2"); put("username", "peer"); put("nickname", "Synthetic peer") })
                add(buildJsonObject { put("user_id", "3"); put("username", "third"); put("nickname", "Synthetic third") })
            } }
            "SYNO.Chat.Channel" -> when (method) {
                "view" -> { lastViewed = f.getValue("last_view_at").toLong(); obj() }
                "close" -> { closed += f.getValue("channel_id"); obj() }
                else -> array("channels", listOf("11", "12").filterNot { it in closed }.map { channel -> buildJsonObject {
                    put("channel_id", channel); put("name", if (channel == "11") "Synthetic group" else "Synthetic peer")
                    put("type", if (channel == "11") "private" else "direct"); put("members", JsonArray(listOf(JsonPrimitive(1), JsonPrimitive(2))))
                    put("last_view_at", lastViewed); put("unread_count", if (lastViewed > 0) 0 else 3)
                } })
            }
            "SYNO.Chat.Channel.Member" -> array("user_ids", listOf(JsonPrimitive(1), JsonPrimitive(2)))
            "SYNO.Chat.Admin.Setting" -> buildJsonObject { put("allow_edit_message", true); put("allow_edit_message_time_within_min", 0) }
            "SYNO.Chat.Post.Subscribe" -> obj()
            "SYNO.Chat.Post.Reminder" -> array("reminders", emptyList())
            "SYNO.Chat.Post.Schedule" -> array("schedules", emptyList())
            "SYNO.Chat.Post.Vote" -> when (method) {
                "get_choices" -> array("choices", voteChoices())
                "vote" -> { voted = true; posts["74"] = post("74", "Synthetic poll", now + 3000, vote = true); obj() }
                else -> error("Unexpected synthetic poll method")
            }
            "SYNO.Chat.Post" -> when (method) {
                "list" -> {
                    val channel = f.getValue("channel_id"); val thread = f["thread_id"] ?: "0"
                    val rows = posts.values.filter { it["channel_id"]!!.jsonPrimitive.content == channel &&
                        (id != null || it["thread_id"]!!.jsonPrimitive.content == thread) }
                    val result = if (id != null && f["prev_count"] == "0") rows.filter { it["post_id"]!!.jsonPrimitive.content == id }
                        else rows.sortedByDescending { it["create_at"]!!.jsonPrimitive.long }.take(f["prev_count"]?.toInt() ?: 50)
                    array("posts", result)
                }
                "search" -> {
                    val pin = f["has"]?.contains("pin") == true
                    val rows = posts.values.filter { if (pin) (it["last_pin_at"] as? JsonPrimitive)?.longOrNull?.let { it > 0 } == true
                        else it["message"]!!.jsonPrimitive.content.contains(f["keyword"].orEmpty(), ignoreCase = true) }
                    obj("search_results" to JsonArray(rows), "total" to JsonPrimitive(rows.size))
                }
                "create" -> {
                    val created = (++serial).toString()
                    posts[created] = post(created, f.getValue("message"), System.currentTimeMillis(), f.getValue("channel_id"), f["thread_id"] ?: "0")
                    if (omitReceipt) obj() else obj("post_id" to JsonPrimitive(created))
                }
                "set" -> { posts[id!!] = JsonObject(posts.getValue(id) + ("message" to JsonPrimitive(f.getValue("message")))); obj() }
                "pin", "unpin" -> { posts[id!!] = JsonObject(posts.getValue(id) + ("last_pin_at" to JsonPrimitive(if (method == "pin") System.currentTimeMillis() else 0))); obj() }
                "delete" -> { if (!ignoreDelete) posts.remove(id); obj() }
                else -> error("Unexpected synthetic post method")
            }
            else -> error("Unexpected synthetic Chat API")
        }
    }
}
