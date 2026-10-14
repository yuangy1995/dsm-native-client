package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientGroup

@Composable
internal fun FileThemeForm(feature: FileSettingsFeatureModel, state: FileSettingsState) {
    val value = state.themeDraft ?: return; val old = (state.theme as? Loadable.Ready)?.value ?: return
    val enabled = feature.canEdit(); val context = LocalContext.current
    val keyboard = LocalSoftwareKeyboardController.current; val focus = LocalFocusManager.current
    val finish = { focus.clearFocus(); keyboard?.hide(); Unit }
    val choose: (FileThemeImageKind) -> Unit = { kind ->
        finish(); feature.themePicker.open(kind, context.cacheDir, context.resources.displayMetrics.widthPixels)
    }
    ClientGroup {
        FileSettingsToggle(stringResource(R.string.file_theme_logo), value.customLogo,
            { checked -> feature.editTheme { it.copy(customLogo = checked, logoImage = if (checked) it.logoImage else null) } }, enabled, "theme_logo_enabled")
        if (value.customLogo) Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FileSettingsChoice(stringResource(R.string.file_theme_logo_position), value.logoPosition, FileThemeLogoPosition.entries,
                { stringResource(it.label()) }, { position -> feature.editTheme { it.copy(logoPosition = position) } }, enabled, "theme_logo_position")
            Text(value.logoImage?.let { themeImageName(it) } ?: stringResource(if (old.customLogo) R.string.file_theme_existing_image else R.string.file_theme_image_required))
            OutlinedButton({ choose(FileThemeImageKind.LOGO) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("theme_choose_logo"), enabled && feature.supportsThemeImages()) {
                Text(stringResource(R.string.file_theme_choose_logo))
            }
        }
    }
    ClientGroup {
        FileSettingsToggle(stringResource(R.string.file_theme_background), value.customBackground,
            { checked -> feature.editTheme { it.copy(customBackground = checked, backgroundImage = if (checked) it.backgroundImage else null) } }, enabled, "theme_background_enabled")
        if (value.customBackground) Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FileSettingsChoice(stringResource(R.string.file_theme_background_position), value.backgroundPosition, FileThemeBackgroundPosition.entries,
                { stringResource(it.label()) }, { position -> feature.editTheme { it.copy(backgroundPosition = position) } }, enabled, "theme_background_position")
            Text(value.backgroundImage?.let { themeImageName(it) } ?: stringResource(if (old.customBackground) R.string.file_theme_existing_image else R.string.file_theme_image_required))
            OutlinedButton({ choose(FileThemeImageKind.BACKGROUND) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("theme_choose_background"), enabled && feature.supportsThemeImages()) {
                Text(stringResource(R.string.file_theme_choose_background))
            }
        }
    }
    OutlinedTextField(value.backgroundColor, { text -> feature.editTheme { it.copy(backgroundColor = text) } },
        Modifier.fillMaxWidth().testTag("theme_color"), enabled, singleLine = true,
        label = { Text(stringResource(R.string.file_theme_color)) }, supportingText = { Text(stringResource(R.string.file_theme_color_hint)) },
        isError = !Regex("#[0-9a-fA-F]{6}").matches(value.backgroundColor), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { finish() }))
    OutlinedTextField(value.footer, { text -> feature.editTheme { it.copy(footer = text) } }, Modifier.fillMaxWidth().testTag("theme_footer"), enabled,
        label = { Text(stringResource(R.string.file_theme_footer)) }, supportingText = { Text(stringResource(R.string.file_theme_footer_hint)) },
        isError = value.footer.codePointCount(0, value.footer.length) > 512 || value.footer.any { it == '\r' || it == '\n' },
        singleLine = true, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { finish() }))
    ClientGroup { FileSettingsToggle(stringResource(R.string.file_theme_footer_html), value.footerUsesHtml,
        { checked -> feature.editTheme { it.copy(footerUsesHtml = checked) } }, enabled, "theme_footer_html") }
}
internal fun FileThemeLogoPosition.label() = when (this) {
    FileThemeLogoPosition.TOP_RIGHT -> R.string.file_theme_top_right; FileThemeLogoPosition.TOP_LEFT -> R.string.file_theme_top_left
    FileThemeLogoPosition.BOTTOM_RIGHT -> R.string.file_theme_bottom_right; FileThemeLogoPosition.BOTTOM_LEFT -> R.string.file_theme_bottom_left
}
internal fun FileThemeBackgroundPosition.label() = when (this) {
    FileThemeBackgroundPosition.CENTER -> R.string.file_theme_center; FileThemeBackgroundPosition.FILL -> R.string.file_theme_fill
    FileThemeBackgroundPosition.FIT -> R.string.file_theme_fit; FileThemeBackgroundPosition.STRETCH -> R.string.file_theme_stretch; FileThemeBackgroundPosition.TILE -> R.string.file_theme_tile
}
