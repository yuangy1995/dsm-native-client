package io.github.qwertyuiop1995.dsmnativeclient.data

import java.nio.file.Files
import java.nio.file.Path
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.FormBody
import okhttp3.MultipartBody
import okhttp3.Request
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue

/** 使用仓库公共请求 Fixture 校验 Android 实际发出的请求，避免平台契约悄然漂移。 */
internal object RequestFixtureAssertions {
    private val json = Json { ignoreUnknownKeys = false }
    private val placeholder = Regex("^<synthetic-[a-z0-9-]+>$")
    private val metadataNames = setOf("api", "method", "version")
    private val sessionNames = setOf("_sid")
    private val tokenNames = setOf("SynoToken", "synotoken")

    fun assertRequest(request: Request, relativePath: String) {
        val fixture = load(relativePath)
        val api = fixture.getValue("api").jsonObject
        val transport = fixture.getValue("transport").jsonObject
        val authentication = fixture.getValue("authentication").jsonObject
        val expectedParameters = fixture.getValue("parameters").jsonArray.associate { raw ->
            val parameter = raw.jsonObject
            parameter.getValue("name").jsonPrimitive.content to parameter
        }

        assertEquals(transport.string("httpMethod"), request.method)
        assertEquals(api.string("resolvedPath").normalizedCgiPath(), request.url.encodedPath.normalizedCgiPath())

        val format = transport.string("requestFormat")
        val bodyFields = when (format) {
            "form", "json" -> if (request.method == "GET") emptyMap() else formFields(request)
            "multipart" -> multipartFields(request)
            else -> error("Android 请求 Fixture 断言暂不支持 $format")
        }
        val fields = if (request.method == "GET") request.queryFields() else bodyFields
        val metadata = if (request.method == "GET" || format == "multipart") {
            request.queryFields() + bodyFields
        } else {
            bodyFields
        }
        assertEquals(api.string("name"), metadata["api"])
        assertEquals(api.string("method"), metadata["method"])
        assertEquals(api.getValue("resolvedVersion").jsonPrimitive.int.toString(), metadata["version"])

        val actualParameters = fields.filterKeys {
            it !in metadataNames && it !in sessionNames && it !in tokenNames
        }
        assertEquals(expectedParameters.keys, actualParameters.keys)
        expectedParameters.forEach { (name, parameter) ->
            val actual = actualParameters[name]
            assertNotNull("参数 $name 缺失", actual)
            val expected = parameter["encodedValue"]?.jsonPrimitive?.contentOrNull
            if (expected != null) {
                assertEncodedValue(
                    name,
                    parameter.string("valueType"),
                    expected,
                    checkNotNull(actual),
                    jsonEncoded = format == "json",
                )
            } else if (parameter["redacted"]?.jsonPrimitive?.booleanOrNull == true) {
                assertTrue("脱敏参数 $name 不应为空", checkNotNull(actual).isNotEmpty())
            }
        }

        val actualAuthentication = authenticationLocations(request, bodyFields)
        assertEquals(authentication.stringSet("sessionLocations"), actualAuthentication.first)
        assertEquals(authentication.stringSet("synoTokenLocations"), actualAuthentication.second)
        if (authentication.getValue("required").jsonPrimitive.booleanOrNull == true) {
            assertTrue("请求必须携带会话", actualAuthentication.first.isNotEmpty())
        }
        if (authentication.getValue("synoTokenRequired").jsonPrimitive.booleanOrNull == true) {
            assertTrue("请求必须携带 SynoToken", actualAuthentication.second.isNotEmpty())
        }
    }

    private fun assertEncodedValue(
        name: String,
        type: String,
        expected: String,
        actual: String,
        jsonEncoded: Boolean,
    ) {
        if (jsonEncoded || type in setOf("object", "objectArray", "stringArray", "integerArray")) {
            assertJsonMatches(name, json.parseToJsonElement(expected), json.parseToJsonElement(actual))
        } else if (placeholder.matches(expected)) {
            assertTrue("参数 $name 不应为空", actual.isNotEmpty())
        } else {
            assertEquals("参数 $name 不一致", expected, actual)
        }
    }

    private fun assertJsonMatches(name: String, expected: JsonElement, actual: JsonElement) {
        when {
            expected is JsonPrimitive && expected.isString && placeholder.matches(expected.content) -> {
                assertTrue("参数 $name 的脱敏占位值不应为空", actual.jsonPrimitive.content.isNotEmpty())
            }
            expected is JsonObject -> {
                val actualObject = actual as? JsonObject ?: error("参数 $name 应为对象")
                assertEquals("参数 $name 的对象字段不一致", expected.keys, actualObject.keys)
                expected.forEach { (key, value) ->
                    assertJsonMatches("$name.$key", value, actualObject.getValue(key))
                }
            }
            expected is JsonArray -> {
                val actualArray = actual as? JsonArray ?: error("参数 $name 应为数组")
                assertEquals("参数 $name 的数组长度不一致", expected.size, actualArray.size)
                expected.indices.forEach { index ->
                    assertJsonMatches("$name[$index]", expected[index], actualArray[index])
                }
            }
            else -> assertEquals("参数 $name 不一致", expected, actual)
        }
    }

    private fun formFields(request: Request): Map<String, String> {
        val form = request.fixtureBody() as? FormBody ?: error("请求正文不是 form")
        return (0 until form.size).associate { form.name(it) to form.value(it) }
    }

    private fun multipartFields(request: Request): Map<String, String> {
        val multipart = ((request.body as? io.github.qwertyuiop1995.dsmnativeclient.network.OneShotRequestBody)?.delegate ?: request.body) as? MultipartBody ?: error("请求正文不是 multipart")
        return multipart.parts.associate { part ->
            val disposition = part.headers?.get("Content-Disposition").orEmpty()
            val name = Regex("name=\"([^\"]+)\"").find(disposition)?.groupValues?.get(1)
                ?: error("multipart part 缺少名称")
            val value = if (disposition.contains("filename=")) {
                "<synthetic-binary>"
            } else {
                Buffer().use { buffer ->
                    part.body.writeTo(buffer)
                    buffer.readUtf8()
                }
            }
            name to value
        }
    }

    private fun Request.queryFields(): Map<String, String> =
        url.queryParameterNames.associateWith { name -> url.queryParameter(name).orEmpty() }

    private fun authenticationLocations(
        request: Request,
        fields: Map<String, String>,
    ): Pair<Set<String>, Set<String>> {
        val session = mutableSetOf<String>()
        val token = mutableSetOf<String>()
        if (request.header("Cookie") != null) session += "cookie"
        if (request.url.queryParameter("_sid") != null) session += "query"
        if (fields["_sid"] != null) session += if (request.body?.contentType()?.type == "multipart") "multipart" else "form"
        if (request.header("X-SYNO-TOKEN") != null) token += "header"
        if (request.url.queryParameter("SynoToken") != null || request.url.queryParameter("synotoken") != null) {
            token += "query"
        }
        if (fields.keys.any { it in tokenNames }) {
            token += if (request.body?.contentType()?.type == "multipart") "multipart" else "form"
        }
        return session to token
    }

    private fun load(relativePath: String): JsonObject {
        var current = Path.of(System.getProperty("user.dir")).toAbsolutePath()
        repeat(8) {
            val candidate = current.resolve("contracts/request-fixtures").resolve(relativePath)
            if (Files.isRegularFile(candidate)) {
                return json.parseToJsonElement(candidate.toFile().readText()).jsonObject
            }
            current = current.parent ?: return@repeat
        }
        error("找不到请求 Fixture：$relativePath")
    }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.stringSet(key: String): Set<String> =
        getValue(key).jsonArray.map { it.jsonPrimitive.content }.toSet()

    private fun String.normalizedCgiPath(): String =
        removePrefix("/").removePrefix("webapi/")
}

/** 断言实际正文，同时保留外层禁止自动重放的生产保护。 */
internal fun Request.fixtureBody(): okhttp3.RequestBody? =
    (body as? io.github.qwertyuiop1995.dsmnativeclient.network.OneShotRequestBody)?.delegate ?: body
