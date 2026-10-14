package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import java.text.NumberFormat
import kotlinx.serialization.json.*

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ColumnScope.PhotoConditionForm(album: SynologyPhotoAlbumState, albums: SynologyPhotoAlbumModel) {
    val model = albums.conditions
    val state by model.state.collectAsState()
    val draft = album.draft ?: return
    val condition = state.condition
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    var field by rememberSaveable(draft.id) { mutableStateOf(SynologyPhotoConditionField.KEYWORD) }
    var fieldsOpen by remember { mutableStateOf(false) }
    val enabled = !album.working
    val submitRule: () -> Unit = {
        if (enabled && !state.searching && (field != SynologyPhotoConditionField.KEYWORD || state.search.isNotBlank())) {
            focus.clearFocus(); keyboard?.hide()
            if (field == SynologyPhotoConditionField.KEYWORD) {
                val value = state.search.trim(); model.add(field.key, SynologyPhotoConditionOption(JsonPrimitive(value), value)); model.searchText("")
            } else model.search()
        }
    }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_condition_form"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (draft.action == SynologyPhotoAlbumAction.REBUILD_FROZEN) item { PhotoFrozenRebuildNotice(draft.frozen) }
        if (draft.action.createsAlbum) item {
            OutlinedTextField(draft.name, albums::setName, Modifier.fillMaxWidth().testTag("photos_album_name"),
                label = { Text(stringResource(R.string.sp_album_name)) }, singleLine = true, enabled = enabled,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() }))
        } else draft.album?.let { item { Text(it.name, style = MaterialTheme.typography.titleMedium) } }
        if (condition == null) item { Button(onClick = albums::retryAccess, enabled = enabled) { Text(stringResource(R.string.sp_retry)) } }
        else {
            if (state.spaces.size > 1) item {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.spaces.forEach { space -> FilterChip(condition.space == space, onClick = { model.selectSource(space) }, enabled = enabled,
                        label = { Text(stringResource(if (space == SynologyPhotoSpace.PERSONAL) R.string.sp_source_personal else R.string.sp_source_shared)) }) }
                }
            }
            item {
                Text(stringResource(R.string.sp_condition_media), style = MaterialTheme.typography.titleMedium)
                if (condition.values("item_type") !in listOf(emptyList(), listOf(JsonPrimitive(-1)), listOf(JsonPrimitive(-2))))
                    Text(stringResource(R.string.sp_condition_existing_media), color = MaterialTheme.colorScheme.onSurfaceVariant)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(0 to R.string.sp_condition_all_media, -1 to R.string.sp_condition_photos, -2 to R.string.sp_condition_videos).forEach { (value, title) ->
                        val values = if (value == 0) emptyList() else listOf(JsonPrimitive(value))
                        FilterChip(condition.values("item_type") == values, onClick = { model.values("item_type", values) }, enabled = enabled, label = { Text(stringResource(title)) })
                    }
                }
            }
            conditionDates(condition, model, enabled)
            conditionFolders(state, model, enabled)
            item {
                Text(stringResource(R.string.sp_detail_rating), style = MaterialTheme.typography.titleMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    (0..5).forEach { value ->
                        val choice = JsonPrimitive(value); val selected = choice in condition.values("rating")
                        FilterChip(selected, onClick = { if (selected) model.remove("rating", choice) else model.add("rating", SynologyPhotoConditionOption(choice)) }, enabled = enabled,
                            label = { Text(if (value == 0) stringResource(R.string.sp_edit_unrated) else pluralStringResource(R.plurals.sp_condition_rating_value, value, value)) })
                    }
                }
            }
            SynologyPhotoConditionField.entries.forEach { key ->
                val values = condition.values(key.key)
                if (values.isNotEmpty()) {
                    item {
                        Text(stringResource(key.title()), style = MaterialTheme.typography.titleMedium)
                        if (key.supportsPolicy) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(true to R.string.sp_condition_all_rules, false to R.string.sp_condition_any_rule).forEach { (all, title) ->
                                FilterChip((condition.fields["${key.key}_policy"] as? JsonPrimitive)?.content == if (all) "and" else "or",
                                    onClick = { model.policy(key, all) }, enabled = enabled, label = { Text(stringResource(title)) })
                            }
                        }
                    }
                    selectedConditionValues(condition, key.key, model, enabled)
                }
            }
            item { HorizontalDivider() }
            item {
                Box {
                    OutlinedButton(onClick = { fieldsOpen = true }, enabled = enabled, modifier = Modifier.fillMaxWidth().testTag("photos_condition_field")) {
                        Text(stringResource(R.string.sp_condition_add_field, stringResource(field.title())))
                    }
                    DropdownMenu(fieldsOpen, { fieldsOpen = false }) {
                        SynologyPhotoConditionField.entries.filter { it != SynologyPhotoConditionField.FLASH }.forEach { next ->
                            DropdownMenuItem(text = { Text(stringResource(next.title())) }, onClick = { field = next; fieldsOpen = false })
                        }
                    }
                }
                OutlinedTextField(state.search, model::searchText, Modifier.fillMaxWidth().testTag("photos_condition_search"),
                    label = { Text(stringResource(if (field == SynologyPhotoConditionField.KEYWORD) R.string.sp_condition_keyword else R.string.sp_condition_search)) },
                    singleLine = true, enabled = enabled,
                    keyboardOptions = KeyboardOptions(imeAction = if (field == SynologyPhotoConditionField.KEYWORD) ImeAction.Done else ImeAction.Search),
                    keyboardActions = KeyboardActions(onDone = { submitRule() }, onSearch = { submitRule() }))
                TextButton(onClick = submitRule, enabled = enabled && !state.searching && (field != SynologyPhotoConditionField.KEYWORD || state.search.isNotBlank()), modifier = Modifier.testTag("photos_condition_find")) {
                    Text(stringResource(if (field == SynologyPhotoConditionField.KEYWORD) R.string.sp_condition_add else R.string.sp_condition_find))
                }
                if (state.searching) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.searchError?.let { Text(stringResource(R.string.sp_condition_search_failed), color = MaterialTheme.colorScheme.error) }
            }
            if (field.canSuggest && state.suggestions != null && !state.searching && state.searchError == null) {
                val choices = state.suggestions!![field.key].orEmpty()
                if (choices.isEmpty()) item { Text(stringResource(R.string.sp_condition_no_suggestions), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(choices, key = { "suggest:${field.key}:${it.value}" }) { choice ->
                    val selected = choice.value in condition.values(field.key)
                    OutlinedButton(onClick = { if (selected) model.remove(field.key, choice.value) else model.add(field.key, choice) }, enabled = enabled,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        Text(stringResource(if (selected) R.string.sp_condition_selected_option else R.string.sp_condition_add_option, conditionOptionName(choice)), Modifier.weight(1f))
                    }
                }
            }
            if (condition.fields.keys.any { it !in conditionKnownKeys }) item { Text(stringResource(R.string.sp_condition_preserve_other), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            item {
                OutlinedButton(onClick = { model.preview() }, enabled = enabled && state.valid && !state.counting, modifier = Modifier.fillMaxWidth().testTag("photos_condition_preview")) {
                    Text(stringResource(R.string.sp_condition_preview))
                }
                if (state.counting) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.count?.let { Text(pluralStringResource(R.plurals.sp_condition_count, it.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), it), Modifier.testTag("photos_condition_count")) }
                if (state.countError != null) Text(stringResource(R.string.sp_condition_count_failed), color = MaterialTheme.colorScheme.error)
                if (!state.valid) Text(stringResource(R.string.sp_condition_invalid), color = MaterialTheme.colorScheme.error)
            }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(onClick = { albums.save() }, enabled = enabled && state.valid &&
            (if (draft.action == SynologyPhotoAlbumAction.REBUILD_FROZEN) draft.name.isNotBlank() && album.access?.canManage == true && draft.frozen?.canRebuild == true
                else if (draft.action.creates) draft.name.isNotBlank() else album.access?.canManage == true && draft.originalCondition != null),
            modifier = Modifier.testTag("photos_album_save")) {
            Text(stringResource(if (draft.action == SynologyPhotoAlbumAction.REBUILD_FROZEN) R.string.sp_frozen_replace
                else if (draft.action.creates) R.string.sp_condition_create else R.string.save_changes))
        }
    }
}

private fun LazyListScope.selectedConditionValues(condition: SynologyPhotoAlbumCondition, key: String, model: SynologyPhotoConditionModel, enabled: Boolean) {
    items(condition.values(key).distinct(), key = { "selected:$key:$it" }) { value ->
        val option = condition.names[key]?.firstOrNull { it.value == value } ?: SynologyPhotoConditionOption(value)
        Row(Modifier.fillMaxWidth().testTag("condition_selected:$key:$value"), verticalAlignment = Alignment.CenterVertically) {
            Text(conditionOptionName(option), Modifier.weight(1f))
            IconButton(onClick = { model.remove(key, value) }, enabled = enabled) { Icon(Icons.Outlined.Close, stringResource(R.string.sp_condition_remove)) }
        }
    }
}

private fun LazyListScope.conditionFolders(state: SynologyPhotoConditionState, model: SynologyPhotoConditionModel, enabled: Boolean) {
    val condition = state.condition ?: return
    item { Text(stringResource(R.string.sp_condition_folders), style = MaterialTheme.typography.titleMedium) }
    selectedConditionValues(condition, "folder_filter", model, enabled)
    item {
        val folder = state.path.lastOrNull()
        if (folder == null) OutlinedButton(onClick = { model.loadFolders() }, enabled = enabled && !state.foldersLoading) { Text(stringResource(R.string.sp_condition_browse_folders)) }
        else {
            if (state.path.size > 1) TextButton(onClick = model::up, enabled = enabled && !state.foldersLoading) { Text(stringResource(R.string.sp_condition_parent)) }
            Text(folder.name, style = MaterialTheme.typography.titleSmall)
            OutlinedButton(onClick = { model.add("folder_filter", SynologyPhotoConditionOption(JsonPrimitive(folder.id), folder.name)) }, enabled = enabled) { Text(stringResource(R.string.sp_condition_add_folder)) }
        }
        if (state.folderError != null) Text(stringResource(R.string.sp_condition_folders_failed), color = MaterialTheme.colorScheme.error)
    }
    items(state.folders, key = { "folder:${it.id}" }) { folder ->
        OutlinedButton(onClick = { model.enter(folder) }, enabled = enabled && !state.foldersLoading, modifier = Modifier.fillMaxWidth()) { Text(folder.name, Modifier.weight(1f)) }
    }
    item {
        when {
            state.foldersLoading -> LinearProgressIndicator(Modifier.fillMaxWidth())
            state.path.isNotEmpty() && state.moreFolders -> TextButton(onClick = { model.loadFolders() }, enabled = enabled) { Text(stringResource(if (state.folderError != null) R.string.sp_retry else R.string.sp_library_more_collections)) }
            state.path.isNotEmpty() && state.folders.isEmpty() -> Text(stringResource(R.string.sp_condition_no_subfolders), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun LazyListScope.conditionDates(condition: SynologyPhotoAlbumCondition, model: SynologyPhotoConditionModel, enabled: Boolean) {
    item { Text(stringResource(R.string.sp_condition_dates), style = MaterialTheme.typography.titleMedium) }
    val times = condition.values("time")
    times.forEachIndexed { index, raw -> item(key = "condition-time:$index") {
        val range = raw as? JsonObject ?: return@item
        fun update(key: String, value: Long?) {
            val next = range.toMutableMap(); if (value == null) next.remove(key) else next[key] = JsonPrimitive(value)
            model.values("time", times.toMutableList().also { if (next.isEmpty()) it.removeAt(index) else it[index] = JsonObject(next) })
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("start_time" to R.string.sp_condition_start, "end_time" to R.string.sp_condition_end).forEach { (key, title) ->
                val seconds = (range[key] as? JsonPrimitive)?.longOrNull
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(seconds != null, enabled = enabled, role = Role.Switch,
                    onValueChange = { update(key, if (it) System.currentTimeMillis() / 1000 else null) }), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(title), Modifier.weight(1f))
                    Switch(seconds != null, onCheckedChange = null, enabled = enabled)
                }
                if (seconds != null) PhotoEditDate(seconds, enabled) { update(key, it) }
            }
            TextButton(onClick = { model.values("time", times.filterIndexed { i, _ -> i != index }) }, enabled = enabled) { Text(stringResource(R.string.sp_condition_remove_dates)) }
        }
    } }
    if (times.isEmpty()) item { OutlinedButton(onClick = { model.values("time", listOf(buildJsonObject { put("start_time", System.currentTimeMillis() / 1000) })) }, enabled = enabled) { Text(stringResource(R.string.sp_condition_add_dates)) } }
}

private val conditionKnownKeys = SynologyPhotoConditionField.entries.flatMap { listOf(it.key, "${it.key}_policy") }.toSet() + setOf("user_id", "item_type", "folder_filter", "rating", "time")

@Composable
private fun conditionOptionName(option: SynologyPhotoConditionOption): String {
    option.name?.let { return it }
    val locale = LocalConfiguration.current.locales[0]
    fun part(value: JsonElement?): String? {
        if (value is JsonPrimitive) {
            if (value.isString) return value.content
            value.doubleOrNull?.let { return NumberFormat.getNumberInstance(locale).apply { maximumFractionDigits = 16 }.format(it) }
        }
        if (value is JsonObject) {
            val num = (value["num"] as? JsonPrimitive)?.longOrNull; val den = (value["den"] as? JsonPrimitive)?.longOrNull
            if (num != null && den != null) return "${NumberFormat.getIntegerInstance(locale).format(num)}/${NumberFormat.getIntegerInstance(locale).format(den)}"
        }
        return null
    }
    val value = option.value
    if (value is JsonPrimitive && value.isString) return value.content
    if (value is JsonObject) {
        val start = part(value["start"]); val end = part(value["end"])
        if (start != null && end != null) return stringResource(R.string.sp_condition_range, start, end)
    }
    return (value as? JsonPrimitive)?.longOrNull?.let { stringResource(R.string.sp_condition_missing_name, it) } ?: stringResource(R.string.sp_condition_existing)
}

internal fun SynologyPhotoConditionField.title(): Int = when (this) {
    SynologyPhotoConditionField.KEYWORD -> R.string.sp_condition_keyword
    SynologyPhotoConditionField.PERSON -> R.string.sp_condition_person
    SynologyPhotoConditionField.CONCEPT -> R.string.sp_condition_concept
    SynologyPhotoConditionField.TAG -> R.string.sp_condition_tag
    SynologyPhotoConditionField.CAMERA -> R.string.sp_condition_camera
    SynologyPhotoConditionField.LENS -> R.string.sp_condition_lens
    SynologyPhotoConditionField.APERTURE -> R.string.sp_condition_aperture
    SynologyPhotoConditionField.ISO -> R.string.sp_condition_iso
    SynologyPhotoConditionField.LOCATION -> R.string.sp_condition_location
    SynologyPhotoConditionField.FOCAL_LENGTH -> R.string.sp_condition_focal_length
    SynologyPhotoConditionField.EXPOSURE -> R.string.sp_condition_exposure
    SynologyPhotoConditionField.FLASH -> R.string.sp_condition_flash
}
