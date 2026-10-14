package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

internal fun FileSharingTheme.settingsValue(includeSequences: Boolean = false) = buildJsonObject {
    put("enable_logo_customize", customLogo); put("enable_background_customize", customBackground)
    put("logo_position", logoPosition.value); put("background_position", backgroundPosition.value)
    put("background_color", backgroundColor); put("footer_msg", footer); put("enable_footer_html", footerUsesHtml)
    if (includeSequences) { put("logo_seq", logoSequence?.let(::JsonPrimitive) ?: JsonNull); put("background_seq", backgroundSequence?.let(::JsonPrimitive) ?: JsonNull) }
}
internal fun FileSettingsChange.Theme.themeParameters(): Map<String, String> {
    val old = baseline; val new = updated
    if (old.owner != new.owner || old == new || new.footer.codePointCount(0, new.footer.length) > 512 || new.footer.any { it == '\r' || it == '\n' } ||
        !Regex("#[0-9a-fA-F]{6}").matches(new.backgroundColor) ||
        !old.customLogo && new.customLogo && new.logoImage == null || !old.customBackground && new.customBackground && new.backgroundImage == null ||
        old.logoSequence != new.logoSequence || old.backgroundSequence != new.backgroundSequence) throw settingsInvalid()
    return buildMap {
        new.settingsValue().forEach { (key, value) -> put(key, value.jsonPrimitive.content) }
        for ((kind, image, enabled) in listOf(Triple(FileThemeImageKind.LOGO, new.logoImage, new.customLogo),
                Triple(FileThemeImageKind.BACKGROUND, new.backgroundImage, new.customBackground))) {
            if (image == null) continue
            if (image.kind != kind || !enabled || !image.validPath) throw settingsInvalid()
            put("${kind.value}_type", image.source.value); put("${kind.value}_path", image.requestPath)
        }
    }
}
internal fun themeSequenceDigest(value: String?) = settingsDigest(value?.let(::JsonPrimitive) ?: JsonNull)
internal fun FileSettingsPending.themeImagesMatch(current: FileSharingTheme): Boolean {
    fun changed(before: String?, after: String?) = before == null || acknowledged && after != null && themeSequenceDigest(after) != before
    return changed(logoBefore, current.logoSequence) && changed(backgroundBefore, current.backgroundSequence)
}
