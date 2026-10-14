package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SynologyPhotoGlobalSetting(val field: String) {
    PEOPLE("enable_person"), SUBJECTS("enable_concept"), SIMILAR("enable_similar"),
    USER_SHARING("enable_user_sharing"), GUEST_INFO("display_photo_info_to_guest"), ORIGINAL_JPEG("enable_converted_original_jpeg")
}

/** 全局选项与两来源识别保持完整原快照；关闭联动只修改已有字段。 */
@Serializable
data class SynologyPhotoGlobalSettings(
    val profileId: String, val administratorId: Long, val values: Map<SynologyPhotoGlobalSetting, Boolean>,
    val excludedExtensions: Set<String>?, val hasHEVC: Boolean?,
    val personalRecognition: Map<SynologyPhotoRecognition, Boolean>, val sharedRecognition: Map<SynologyPhotoRecognition, Boolean>,
    val personalEnabled: Boolean, val sharedEnabled: Boolean, val sharedRole: SynologyPhotoSharedSettings.Role,
) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.GLOBAL
    val editable: Set<SynologyPhotoGlobalSetting> get() = values.keys - if (hasHEVC == true) emptySet() else setOf(SynologyPhotoGlobalSetting.ORIGINAL_JPEG)
    val supportsOriginalJPEG: Boolean get() = values[SynologyPhotoGlobalSetting.ORIGINAL_JPEG] == true && hasHEVC == true
    fun applying(choices: Map<SynologyPhotoGlobalSetting, Boolean>, excluded: Set<String>? = excludedExtensions): SynologyPhotoGlobalSettings {
        fun linked(before: Map<SynologyPhotoRecognition, Boolean>) = before.mapValues { (key, value) ->
            if (choices[SynologyPhotoGlobalSetting.entries.first { it.field == key.field }] == false) false else value
        }
        return copy(values = choices, excludedExtensions = excluded, personalRecognition = linked(personalRecognition), sharedRecognition = linked(sharedRecognition))
    }
    fun recognition() = SynologyPhotoRecognitionSettings(personalEnabled, personalRecognition,
        SynologyPhotoRecognition.entries.mapNotNull { key -> values[SynologyPhotoGlobalSetting.entries.first { it.field == key.field }]?.let { key to it } }.toMap())
    companion object {
        val supportedExtensions = "JPG JPEG JPE WEBP BMP PNG GIF TIF TIFF HEIC HEIF HIF ARW SRF SR2 DCR K25 KDC CR2 CR3 CRW NEF MRW PTX PEF RAF 3FR ERF MEF MOS ORF RW2 DNG X3F RAW MPG MPEG AVI ASF WMV MOV FLV F4V MP4 DIVX XVID M2TS M2T MTS M4V 3GP 3G2 QT".split(" ").toSet()
    }
}

/** 清理意图不伪造目标大小；回执后可能已生成新缓存。 */
@Serializable
data class SynologyPhotoConversionCache(
    val profileId: String, val administratorId: Long, val sizeBytes: Long, val clearing: Boolean, val clearRequested: Boolean = false,
) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.CACHE
    val canClear: Boolean get() = sizeBytes > 0 && !clearing
}

@Serializable
enum class SynologyPhotoGlobalStep { CACHE, ADMIN, PERSONAL, SHARED }

@Serializable
data class SynologyPhotoGlobalProgress(
    val attempted: Set<SynologyPhotoGlobalStep> = emptySet(), val acknowledged: Set<SynologyPhotoGlobalStep> = emptySet(),
    val rejected: Set<SynologyPhotoGlobalStep> = emptySet(), val completed: Set<SynologyPhotoGlobalStep> = emptySet(),
)
