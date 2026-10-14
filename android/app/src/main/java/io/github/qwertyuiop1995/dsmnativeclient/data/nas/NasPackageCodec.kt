package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.net.URI
import java.net.URLDecoder
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal const val PACKAGE_API = "SYNO.Core.Package"
internal const val PACKAGE_INSTALL = "SYNO.Core.Package.Installation"
internal const val PACKAGE_SETTINGS = "SYNO.Core.Package.Setting"
internal const val PACKAGE_FEED = "SYNO.Core.Package.Feed"
internal fun packageFailure(problem: NasPackageProblem = NasPackageProblem.INCOMPLETE): Nothing = throw NasPackageFailure(problem)
internal fun JsonElement?.packageObject(): JsonObject = this as? JsonObject ?: packageFailure()
internal fun JsonElement?.packageArray(): JsonArray = this as? JsonArray ?: packageFailure()
internal fun JsonElement?.packageString(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonElement?.packageBoolean(): Boolean? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
internal fun JsonElement?.packageLong(): Long? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull?.takeIf { it >= 0 }
internal fun JsonElement?.packageNumber(): Double? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf(Double::isFinite)
internal fun JsonObject.packageText(key: String): String = get(key).packageString()?.takeIf { it.isNotBlank() } ?: packageFailure()
internal fun JsonObject.packageFlag(key: String): Boolean = get(key).packageBoolean() ?: packageFailure()
internal fun JsonObject.packageMetadata(key: String): JsonElement? = (get("additional") as? JsonObject)?.get(key) ?: get(key)
internal fun packageStrings(values: List<String>) = JsonArray(values.map(::JsonPrimitive))
internal fun packageVolumes(raw: JsonElement?): List<NasPackageChoice> {
    val values = raw.packageArray().map { row -> row.packageObject().let { NasPackageChoice(it.packageText("mount_point"), it.packageText("display")) } }
    if (values.map { it.id }.distinct().size != values.size) packageFailure()
    return values
}
internal fun packageRows(data: JsonObject, key: String, bounded: Boolean = false): List<JsonObject> {
    val rows = data[key].packageArray().map { it.packageObject() }
    if (bounded && rows.size >= 1_000 || data["total"]?.takeUnless { it is JsonNull }?.let { it.packageLong() != rows.size.toLong() } == true) packageFailure()
    return rows
}
internal fun Throwable.packageTrustFailure() = this is CancellationException || this is DsmFailure &&
    kind in setOf(DsmErrorKind.TLS_UNTRUSTED, DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH,
        DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.WORKSPACE_CHANGED)
internal fun Throwable.packageRejection() = this is DsmFailure && (isExplicitApiRejection || code != null ||
    kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.FEATURE_UNSUPPORTED))
internal fun normalizedPackageSource(source: NasPackageSource): NasPackageSource {
    val value = source.copy(name = source.name.trim(), url = source.url.trim())
    val uri = runCatching { URI(value.url) }.getOrNull() ?: packageFailure(NasPackageProblem.INVALID_SOURCE)
    if (value.name.isEmpty() || value.name.any(Char::isISOControl) || uri.scheme?.lowercase() !in setOf("http", "https") ||
        uri.host.isNullOrBlank() || uri.rawUserInfo != null || uri.rawFragment != null) packageFailure(NasPackageProblem.INVALID_SOURCE)
    return value
}

/** 只接受已有契约中的原生字段，不执行套件提供的脚本、正则或远程选项。 */
internal fun packageFields(value: JsonElement?): List<NasPackageField> {
    if (value == null || value is JsonNull || value == JsonPrimitive("")) return emptyList()
    val raw = if (value is JsonPrimitive && value.isString) {
        runCatching { Json.parseToJsonElement(URLDecoder.decode(value.content.replace("+", "%2B"), "UTF-8")) }
            .getOrElse { packageFailure(NasPackageProblem.CUSTOM_OPTIONS) }
    } else value
    val fields = mutableListOf<NasPackageField>(); val keys = mutableSetOf<String>()
    fun invalid(): Nothing = packageFailure(NasPackageProblem.CUSTOM_OPTIONS)
    for ((pageIndex, page) in (raw as? JsonArray ?: invalid()).withIndex()) {
        for ((itemIndex, rawItem) in ((page as? JsonObject)?.get("items") as? JsonArray ?: invalid()).withIndex()) {
            val item = rawItem as? JsonObject ?: invalid(); val prefix = "page-$pageIndex-item-$itemIndex"
            item["desc"].packageString()?.takeIf { it.isNotEmpty() }?.let { fields += NasPackageField(prefix, it, NasPackageFieldKind.DESCRIPTION) }
            val type = item["type"].packageString() ?: run { if (item["subitems"] != null) invalid(); continue }
            val kind = when (type) { "textfield" -> NasPackageFieldKind.TEXT; "password" -> NasPackageFieldKind.PASSWORD
                "multiselect" -> NasPackageFieldKind.TOGGLE; "singleselect" -> NasPackageFieldKind.RADIO
                "combobox" -> NasPackageFieldKind.CHOICE; else -> invalid() }
            for (rawSub in (item["subitems"] as? JsonArray ?: invalid())) {
                val sub = rawSub as? JsonObject ?: invalid(); val key = sub["key"].packageString()?.takeIf { it.isNotEmpty() } ?: invalid()
                if (!keys.add(key)) invalid()
                val validator = sub["validator"]?.takeUnless { it is JsonNull }?.let { it as? JsonObject ?: invalid() }
                for (key in listOf("hidden", "disabled")) if (sub[key] != null && sub[key] !is JsonNull && sub[key].packageBoolean() == null) invalid()
                if (validator?.get("allowBlank") != null && validator["allowBlank"] !is JsonNull && validator["allowBlank"].packageBoolean() == null) invalid()
                if (listOf("fn", "regex", "vtype").any { validator?.get(it) != null } || listOf("api_store", "listeners").any { sub[it] != null } ||
                    sub["hidden"].packageBoolean() == true || sub["disabled"].packageBoolean() == true) invalid()
                val choices = if (kind == NasPackageFieldKind.CHOICE) (sub["store"] as? JsonArray ?: invalid()).map { row ->
                    if (row is JsonArray && row.size == 2) NasPackageChoice(row[0].packageString() ?: invalid(), row[1].packageString() ?: invalid())
                    else row.packageString()?.let { NasPackageChoice(it, it) } ?: invalid()
                } else emptyList()
                val flag = kind in setOf(NasPackageFieldKind.TOGGLE, NasPackageFieldKind.RADIO)
                val default = sub["defaultValue"] ?: sub["value"]
                if (default != null && default !is JsonNull && (if (flag) default.packageBoolean() == null else default.packageString() == null)) invalid()
                fun length(key: String): Int? = validator?.get(key)?.let { rawLength -> rawLength.packageLong()?.takeIf { it <= Int.MAX_VALUE }?.toInt() ?: invalid() }
                fields += NasPackageField(key, sub["desc"].packageString() ?: key, kind,
                    if (flag) JsonPrimitive(default.packageBoolean() == true) else JsonPrimitive(default.packageString().orEmpty()), choices,
                    if (kind == NasPackageFieldKind.RADIO) prefix else null, validator?.get("allowBlank").packageBoolean() == false,
                    length("minLength"), length("maxLength"))
            }
        }
    }
    return fields
}
internal fun NasPackageConfiguration.checkedValues(values: Map<String, JsonPrimitive>): JsonObject {
    val editable = fields.filter { it.kind != NasPackageFieldKind.DESCRIPTION }
    if (values.keys.any { key -> editable.none { it.id == key } }) packageFailure(NasPackageProblem.OPTIONS_REQUIRED)
    val result = editable.associate { field ->
        val value = values[field.id] ?: field.defaultValue
        val flag = field.kind in setOf(NasPackageFieldKind.TOGGLE, NasPackageFieldKind.RADIO)
        if (flag) {
            if (value.packageBoolean() == null || field.required && field.kind == NasPackageFieldKind.TOGGLE && value.packageBoolean() != true) packageFailure(NasPackageProblem.OPTIONS_REQUIRED)
        } else {
            val text = value.packageString() ?: packageFailure(NasPackageProblem.OPTIONS_REQUIRED)
            if (field.required && text.isEmpty() || field.minimumLength?.let { text.length < it } == true ||
                field.maximumLength?.let { text.length > it } == true || field.kind == NasPackageFieldKind.CHOICE && field.choices.none { it.id == text }) packageFailure(NasPackageProblem.OPTIONS_REQUIRED)
        }
        field.id to value
    }
    for (group in editable.filter { it.kind == NasPackageFieldKind.RADIO }.groupBy { it.group }.values) {
        val selected = group.count { result[it.id].packageBoolean() == true }
        if (selected > 1 || group.any { it.required } && selected != 1) packageFailure(NasPackageProblem.OPTIONS_REQUIRED)
    }
    return JsonObject(result)
}
