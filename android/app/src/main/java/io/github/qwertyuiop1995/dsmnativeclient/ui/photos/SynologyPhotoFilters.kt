package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosState
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private enum class PhotoFilterField(val title: Int) {
    TYPE(R.string.sp_filters_type), PERSON(R.string.sp_category_person), PLACE(R.string.sp_category_location),
    TAG(R.string.sp_category_tags), RATING(R.string.sp_detail_rating), CAMERA(R.string.sp_detail_camera),
    LENS(R.string.sp_detail_lens), ISO(R.string.sp_detail_iso), APERTURE(R.string.sp_detail_aperture),
    FOCAL(R.string.sp_detail_focal), EXPOSURE(R.string.sp_detail_shutter),
}

/** 十二类筛选直接提交 NAS 返回的标识/区间；标题、月份或翻译从不参与查询参数。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SynologyPhotoFilters(state: SynologyPhotosState, onRetry: () -> Unit, onDismiss: () -> Unit, onApply: (SynologyPhotoFilter) -> Unit) {
    var draft by remember { mutableStateOf(state.navigation.filter) }
    var selected by remember { mutableStateOf<PhotoFilterField?>(null) }
    var datePicker by remember { mutableStateOf(false) }
    val options = state.options
    val places = remember(options.locations) { flattenLocations(options.locations) }
    ClientPageDialog(stringResource(R.string.sp_filters), onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = { draft = SynologyPhotoFilter() }) { Text(stringResource(R.string.sp_filters_clear)) }
                Button(onClick = { onApply(draft) }, modifier = Modifier.padding(vertical = 8.dp)) { Text(stringResource(R.string.sp_filters_apply)) }
            }
            if (state.optionsLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (state.optionsError != null) PhotoErrorPanel(state.optionsError, onRetry)
            LazyColumn(Modifier.weight(1f)) {
                item { FilterRow(stringResource(R.string.sp_filters_date), dateSummary(draft)) { datePicker = true } }
                items(PhotoFilterField.entries) { field ->
                    val detail = when (field) {
                        PhotoFilterField.TYPE -> draft.mediaType?.let { stringResource(if (it == 0) R.string.sp_filters_images else R.string.sp_filters_videos) }
                        PhotoFilterField.PERSON -> options.people.find { it.id == draft.personId }?.name
                        PhotoFilterField.PLACE -> places.find { it.id == draft.locationId }?.name
                        PhotoFilterField.TAG -> options.tags.find { it.id == draft.tagId }?.name
                        PhotoFilterField.RATING -> draft.rating?.let { ratingLabel(it) }
                        PhotoFilterField.CAMERA -> options.cameras.find { it.id == draft.cameraId }?.name
                        PhotoFilterField.LENS -> options.lenses.find { it.id == draft.lensId }?.name
                        PhotoFilterField.ISO -> options.iso.find { it.id == draft.isoId }?.name
                        PhotoFilterField.APERTURE -> options.apertures.find { it.id == draft.apertureId }?.name
                        PhotoFilterField.FOCAL -> draft.focalRange?.let { focalLabel(it) }
                        PhotoFilterField.EXPOSURE -> draft.exposureRange?.let { exposureLabel(it) }
                    }
                    FilterRow(stringResource(field.title), detail ?: stringResource(R.string.sp_filters_all)) { selected = field }
                }
            }
        }
    }
    selected?.let { field ->
        val close = { selected = null }
        ClientPageDialog(stringResource(field.title), close) {
            when (field) {
                PhotoFilterField.TYPE -> PhotoChoices(listOf(0, 1), draft.mediaType, { it.toString() }, { stringResource(if (it == 0) R.string.sp_filters_images else R.string.sp_filters_videos) }) { draft = draft.copy(mediaType = it); close() }
                PhotoFilterField.RATING -> PhotoChoices((0..5).toList(), draft.rating, { it.toString() }, { ratingLabel(it) }) { draft = draft.copy(rating = it); close() }
                PhotoFilterField.PERSON -> IdChoices(options.people, draft.personId) { draft = draft.copy(personId = it); close() }
                PhotoFilterField.PLACE -> IdChoices(places, draft.locationId) { draft = draft.copy(locationId = it); close() }
                PhotoFilterField.TAG -> IdChoices(options.tags, draft.tagId) { draft = draft.copy(tagId = it); close() }
                PhotoFilterField.CAMERA -> IdChoices(options.cameras, draft.cameraId) { draft = draft.copy(cameraId = it); close() }
                PhotoFilterField.LENS -> IdChoices(options.lenses, draft.lensId) { draft = draft.copy(lensId = it); close() }
                PhotoFilterField.ISO -> IdChoices(options.iso, draft.isoId) { draft = draft.copy(isoId = it); close() }
                PhotoFilterField.APERTURE -> IdChoices(options.apertures, draft.apertureId) { draft = draft.copy(apertureId = it); close() }
                PhotoFilterField.FOCAL -> PhotoChoices(options.focalRanges, draft.focalRange, { it.toString() }, { focalLabel(it) }) { draft = draft.copy(focalRange = it); close() }
                PhotoFilterField.EXPOSURE -> PhotoChoices(options.exposureRanges, draft.exposureRange, { it.toString() }, { exposureLabel(it) }) { draft = draft.copy(exposureRange = it); close() }
            }
        }
    }
    if (datePicker) {
        val picker = rememberDateRangePickerState(initialSelectedStartDateMillis = draft.startTime?.let { pickerDay(it) }, initialSelectedEndDateMillis = draft.endTime?.let { pickerDay(it) })
        ClientPageDialog(stringResource(R.string.sp_choose_date_range), { datePicker = false }) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = { draft = draft.copy(startTime = null, endTime = null); datePicker = false }) { Text(stringResource(R.string.sp_filters_clear)) }
                    Button(onClick = {
                        val start = picker.selectedStartDateMillis ?: return@Button
                        val end = picker.selectedEndDateMillis ?: return@Button
                        draft = draft.copy(startTime = localDay(start).atStartOfDay(ZoneId.systemDefault()).toEpochSecond(),
                            endTime = localDay(end).plusDays(1).atStartOfDay(ZoneId.systemDefault()).toEpochSecond() - 1)
                        datePicker = false
                    }, enabled = picker.selectedStartDateMillis != null && picker.selectedEndDateMillis != null) { Text(stringResource(R.string.sp_filters_apply)) }
                }
                DateRangePicker(picker, modifier = Modifier.weight(1f), title = null, headline = null)
            }
        }
    }
}

@Composable
private fun FilterRow(title: String, value: String, onClick: () -> Unit) = ListItem(
    headlineContent = { Text(title) }, supportingContent = { Text(value) }, modifier = Modifier.clickable(onClick = onClick),
)

@Composable
private fun IdChoices(values: List<SynologyPhotoChoice>, selectedId: Long?, onChoose: (Long?) -> Unit) =
    PhotoChoices(values, values.find { it.id == selectedId }, { it.id.toString() }, { it.name }) { onChoose(it?.id) }

@Composable
private fun <T> PhotoChoices(values: List<T>, selected: T?, key: (T) -> String, label: @Composable (T) -> String, onChoose: (T?) -> Unit) {
    var search by remember { mutableStateOf("") }
    // 只转换当前筛选分组的文案；数万项目图库不进入筛选面板的内存或搜索。
    val labelled = values.map { it to label(it) }
    val visible = remember(labelled, search) { labelled.filter { (_, title) -> title.contains(search, ignoreCase = true) } }
    Column(Modifier.fillMaxSize()) {
        ClientSearchField(search, { search = it }, stringResource(R.string.sp_filter_candidate_search), Modifier.padding(12.dp))
        LazyColumn(Modifier.weight(1f)) {
            item(key = "all") { ListItem(headlineContent = { Text(stringResource(R.string.sp_filters_all)) },
                leadingContent = { RadioButton(selected == null, onClick = null) }, modifier = Modifier.clickable { onChoose(null) }) }
            items(visible, key = { "option:${key(it.first)}" }) { (value, title) ->
                ListItem(headlineContent = { Text(title) }, leadingContent = { RadioButton(selected == value, onClick = null) }, modifier = Modifier.clickable { onChoose(value) })
            }
            if (visible.isEmpty()) item { Text(stringResource(R.string.sp_filters_no_options), Modifier.padding(24.dp)) }
        }
    }
}

private fun flattenLocations(locations: List<SynologyPhotoLocation>): List<SynologyPhotoChoice> = buildList {
    fun visit(values: List<SynologyPhotoLocation>) { values.forEach { add(SynologyPhotoChoice(it.id, it.name)); visit(it.children) } }
    visit(locations)
}

private fun localDay(milliseconds: Long) = Instant.ofEpochMilli(milliseconds).atZone(ZoneOffset.UTC).toLocalDate()
private fun pickerDay(seconds: Long) = Instant.ofEpochSecond(seconds).atZone(ZoneId.systemDefault()).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()

@Composable
private fun dateSummary(filter: SynologyPhotoFilter): String {
    val start = filter.startTime ?: return stringResource(R.string.sp_filters_all)
    val end = filter.endTime ?: return stringResource(R.string.sp_filters_all)
    val locale = LocalConfiguration.current.locales[0]
    val formatter = remember(locale) { DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).withZone(ZoneId.systemDefault()) }
    return stringResource(R.string.sp_date_range, formatter.format(Instant.ofEpochSecond(start)), formatter.format(Instant.ofEpochSecond(end)))
}

@Composable
private fun ratingLabel(value: Int) = if (value == 0) stringResource(R.string.sp_filters_unrated) else stringResource(R.string.sp_stars, value)

@Composable
private fun focalLabel(value: SynologyPhotoFocalRange): String {
    val numbers = NumberFormat.getIntegerInstance(LocalConfiguration.current.locales[0])
    return when {
        value.start == 0 -> stringResource(R.string.sp_filters_focal_below, numbers.format(value.end))
        value.end == 0 -> stringResource(R.string.sp_filters_focal_above, numbers.format(value.start))
        else -> stringResource(R.string.sp_filters_focal_range, numbers.format(value.start), numbers.format(value.end))
    }
}

@Composable
private fun exposureLabel(value: SynologyPhotoExposureRange): String {
    val numbers = NumberFormat.getNumberInstance(LocalConfiguration.current.locales[0]).apply { maximumFractionDigits = 6 }
    fun format(fraction: SynologyPhotoFraction) = if (fraction.num == 1 && fraction.den > 1) "${numbers.format(fraction.num)}/${numbers.format(fraction.den)}" else numbers.format(fraction.num.toDouble() / fraction.den)
    return when {
        value.start.num == 0 -> stringResource(R.string.sp_filters_exposure_below, format(value.end))
        value.end.num == 0 -> stringResource(R.string.sp_filters_exposure_above, format(value.start))
        else -> stringResource(R.string.sp_filters_exposure_range, format(value.start), format(value.end))
    }
}
