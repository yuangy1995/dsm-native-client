package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SynologyPhotoSettingsKind { DISPLAY, DUPLICATES, RECOGNITION, SHARED, GLOBAL, CACHE, ALBUM_SORT, LIST_SORT, LIST_DISPLAY, AUTOMATIC_PREVIEWS;
    val userSetting: Boolean get() = this in setOf(DISPLAY, DUPLICATES, RECOGNITION, AUTOMATIC_PREVIEWS)
}

@Serializable
sealed class SynologyPhotoSettings {
    abstract val kind: SynologyPhotoSettingsKind
}

@Serializable
data class SynologyPhotoAutomaticPreviewSettings(val enabled: Boolean) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.AUTOMATIC_PREVIEWS
}

@Serializable
data class SynologyPhotoDisplaySettings(
    val grouping: Grouping, val date: Date, val clock: Clock, val sort: SynologyPhotoSort, val showInfo: Boolean,
) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.DISPLAY
    @Serializable enum class Grouping(val value: String) { DAY("day"), MONTH("month") }
    @Serializable enum class Clock(val value: String) { TWELVE("12"), TWENTY_FOUR("24") }
    @Serializable enum class Date(val value: String, val pattern: String, val monthPattern: String) {
        YEAR_DASH("yyyy-mm-dd", "yyyy-MM-dd", "yyyy-MM"), YEAR_SLASH("yyyy/mm/dd", "yyyy/MM/dd", "yyyy/MM"),
        YEAR_DOT("yyyy.mm.dd", "yyyy.MM.dd", "yyyy.MM"), DAY_DASH("dd-mm-yyyy", "dd-MM-yyyy", "MM-yyyy"),
        DAY_SLASH("dd/mm/yyyy", "dd/MM/yyyy", "MM/yyyy"), DAY_DOT("dd.mm.yyyy", "dd.MM.yyyy", "MM.yyyy"),
        MONTH_DASH("mm-dd-yyyy", "MM-dd-yyyy", "MM-yyyy"), MONTH_SLASH("mm/dd/yyyy", "MM/dd/yyyy", "MM/yyyy"),
        MONTH_DOT("mm.dd.yyyy", "MM.dd.yyyy", "MM.yyyy")
    }
}

@Serializable
data class SynologyPhotoDuplicateSettings(val upload: SynologyPhotoUploadDuplicate, val transfer: SynologyPhotoTransferDuplicate) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.DUPLICATES
}

@Serializable
enum class SynologyPhotoRecognition(val field: String) { PEOPLE("enable_person"), SUBJECTS("enable_concept"), SIMILAR("enable_similar") }

/** 缺字段与关闭分离；保留两侧已知值，不能把未知项写成 false。 */
@Serializable
data class SynologyPhotoRecognitionSettings(
    val personalEnabled: Boolean, val personal: Map<SynologyPhotoRecognition, Boolean>, val global: Map<SynologyPhotoRecognition, Boolean>,
) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.RECOGNITION
    val known: Set<SynologyPhotoRecognition> get() = personal.keys.intersect(global.keys)
    val editable: Set<SynologyPhotoRecognition> get() = if (personalEnabled) known.filterTo(mutableSetOf()) { global[it] == true } else emptySet()
}

/** 复用管理操作存储，只保存本用户非秘密的设置值与提交事实。 */
@Serializable
data class SynologyPhotoSettingsCheckpoint(
    val original: SynologyPhotoSettings, val desired: SynologyPhotoSettings,
    val attempted: Boolean = false, val rejected: Boolean = false,
    val globalProgress: SynologyPhotoGlobalProgress? = if (original.kind in setOf(SynologyPhotoSettingsKind.GLOBAL, SynologyPhotoSettingsKind.CACHE)) SynologyPhotoGlobalProgress() else null,
) {
    val needsConfirmation: Boolean get() = when {
        original is SynologyPhotoGlobalSettings || original is SynologyPhotoConversionCache -> true
        original is SynologyPhotoDuplicateSettings && desired is SynologyPhotoDuplicateSettings ->
            original.transfer != desired.transfer && desired.transfer == SynologyPhotoTransferDuplicate.OVERWRITE
        original is SynologyPhotoSharedSettings && desired is SynologyPhotoSharedSettings ->
            original.enabled != desired.enabled || original.values[SynologyPhotoSharedSetting.PUBLIC_ROOT] != desired.values[SynologyPhotoSharedSetting.PUBLIC_ROOT]
        else -> false
    }
}
