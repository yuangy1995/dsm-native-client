package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import kotlinx.serialization.json.*

/** 条件读取和校验共用同一相册写通道；所有请求仍使用统一 Foto 路由。 */
internal class SynologyPhotosConditionRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
) {
    private suspend fun source(owner: SynologyPhotosMutationAccess, space: SynologyPhotoSpace): Long {
        checkAccess(owner, space)
        if (space == SynologyPhotoSpace.SHARED && !owner.managesShared) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        return if (space == SynologyPhotoSpace.SHARED) 0 else owner.userId
    }

    suspend fun get(id: Long, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCondition {
        val list = read("Browse.ConditionAlbum", 3, "get", json("id" to array(id), "additional" to array("condition_object")), null).list()
        val item = list.singleOrNull()?.takeIf { it.positive("id") == id } ?: invalid()
        val raw = item.obj("additional").obj("condition_object")
        if (SynologyPhotoConditionCodec.number(raw["user_id"]) !in setOf(0L, owner.userId))
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        return SynologyPhotoConditionCodec.decode(raw).also {
            source(owner, it.space); SynologyPhotoConditionCodec.canonical(it, owner.userId)
        }
    }

    suspend fun suggestions(keyword: String, space: SynologyPhotoSpace): Map<String, List<SynologyPhotoConditionOption>> {
        val owner = identity(); val user = source(owner, space)
        val raw = read("Browse.ConditionAlbum", 3, "suggest", json("keyword" to keyword, "user_id" to user,
            "condition" to JsonArray(SynologyPhotoConditionField.entries.filter { it.canSuggest }.map { JsonPrimitive(it.key) }),
            "additional" to array("thumbnail")), null)
        source(owner, space)
        return SynologyPhotoConditionCodec.suggestions(raw)
    }

    suspend fun count(condition: SynologyPhotoAlbumCondition): Long {
        val owner = identity(); source(owner, condition.space)
        val raw = read("Browse.ConditionAlbum", 3, "peek_item_count",
            json("condition" to SynologyPhotoConditionCodec.canonical(condition, owner.userId)), null)
        source(owner, condition.space)
        return SynologyPhotoConditionCodec.number(raw["count"])?.takeIf { it >= 0 } ?: invalid()
    }

    suspend fun validate(condition: SynologyPhotoAlbumCondition, owner: SynologyPhotosMutationAccess) {
        source(owner, condition.space); SynologyPhotoConditionCodec.canonical(condition, owner.userId)
        for (value in condition.values("folder_filter")) {
            val id = SynologyPhotoConditionCodec.number(value) ?: invalid()
            val folder = read("Browse.Folder", 2, "get", json("id" to id, "additional" to array("access_permission")), condition.space).obj("folder")
            if (folder.positive("id") != id || folder.obj("additional").obj("access_permission").permission("view") != true)
                throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
        }
        source(owner, condition.space)
    }
}
