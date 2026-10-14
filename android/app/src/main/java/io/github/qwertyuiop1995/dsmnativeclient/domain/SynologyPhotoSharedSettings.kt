package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SynologyPhotoSharedSetting(val field: String) {
    PEOPLE("enable_person"), SUBJECTS("enable_concept"), SIMILAR("enable_similar"), PUBLIC_ROOT("allow_root_folder_public")
}

/** 管理员身份与完整条件随草稿固定；未知字段不作为关闭值。 */
@Serializable
data class SynologyPhotoSharedSettings(
    val profileId: String, val administratorId: Long, val enabled: Boolean, val personalEnabled: Boolean,
    val role: Role, val disabledBySharedFolder: Boolean?,
    val values: Map<SynologyPhotoSharedSetting, Boolean>, val global: Map<SynologyPhotoSharedSetting, Boolean>,
) : SynologyPhotoSettings() {
    override val kind: SynologyPhotoSettingsKind get() = SynologyPhotoSettingsKind.SHARED
    @Serializable enum class Role(val value: String) { NONE("none"), ENTRY("entry"), MANAGEMENT("management") }
    val canAccess: Boolean get() = enabled && role != Role.NONE
    val canToggle: Boolean get() = !enabled || personalEnabled
    val editable: Set<SynologyPhotoSharedSetting> get() = if (enabled) values.keys.filterTo(mutableSetOf()) {
        it == SynologyPhotoSharedSetting.PUBLIC_ROOT || global[it] == true
    } else emptySet()
}
