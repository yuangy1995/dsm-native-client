package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.ZoneOffset

internal enum class SynologyPhotosSection { TIMELINE, FOLDERS, ALBUMS, SHARING }
internal data class SynologyPhotoNavigation(
    val section: SynologyPhotosSection = SynologyPhotosSection.TIMELINE,
    val folders: List<SynologyPhotoCollection> = emptyList(),
    val album: SynologyPhotoCollection? = null,
    val category: SynologyPhotoCategory? = null,
    val categoryItem: SynologyPhotoCollection? = null,
    val shareScope: SynologyPhotoShareScope = SynologyPhotoShareScope.WITH_ME,
    val keyword: String = "",
    val filter: SynologyPhotoFilter = SynologyPhotoFilter(),
) {
    val canGoBack: Boolean get() = folders.size > 1 || album != null || category != null
    val showsCollectionRoot: Boolean get() = section == SynologyPhotosSection.ALBUMS && album == null && category == null && keyword.isEmpty() && !filter.isActive
}

internal data class SynologyPhotoDayGroup(val date: LocalDate, val items: List<SynologyPhoto>)
internal data class SynologyPhotosState(
    val navigation: SynologyPhotoNavigation = SynologyPhotoNavigation(),
    val items: List<SynologyPhoto> = emptyList(),
    val groups: List<SynologyPhotoDayGroup> = emptyList(),
    val collections: List<SynologyPhotoCollection> = emptyList(),
    val sharing: List<SynologyPhotoSharedEntry> = emptyList(),
    val categories: Set<SynologyPhotoCategory> = emptySet(),
    val months: List<YearMonth> = emptyList(),
    val selectedMonth: YearMonth? = null,
    val hasPrevious: Boolean = false,
    val hasMore: Boolean = false,
    val hasMoreCollections: Boolean = false,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val loadingPrevious: Boolean = false,
    val loaded: Boolean = false,
    val error: Throwable? = null,
    val categoriesError: Throwable? = null,
    val previousError: Throwable? = null,
    val options: SynologyPhotoFilterOptions = SynologyPhotoFilterOptions(),
    val optionsLoading: Boolean = false,
    val optionsError: Throwable? = null,
    val paginationKey: Long = 0,
) {
    val empty: Boolean get() = items.isEmpty() && collections.isEmpty() && sharing.isEmpty()
}

/** 月份与向上窗口独立于服务端聚合数量，保留关键词和十二类筛选的原始范围。 */
internal object SynologyPhotoWindows {
    fun bounds(days: List<SynologyPhotoDay>): LongRange? {
        if (days.isEmpty()) return null
        val first = days.minOf { it.date }.atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        val last = days.maxOf { it.date }.atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        return maxOf(0, first - 86_400)..(last + 172_800)
    }

    fun constrain(query: SynologyPhotoQuery, start: Long? = null, end: Long? = null): SynologyPhotoQuery? {
        fun lower(value: Long) = maxOf(value, start ?: value)
        fun upper(value: Long) = minOf(value, end ?: value)
        fun valid(from: Long, to: Long) = lower(from) <= upper(to)
        return when (query) {
            is SynologyPhotoQuery.Timeline -> if (valid(query.start, query.end)) query.copy(start = lower(query.start), end = upper(query.end)) else null
            is SynologyPhotoQuery.Search -> if (valid(query.start, query.end)) query.copy(start = lower(query.start), end = upper(query.end)) else null
            is SynologyPhotoQuery.Category -> if (valid(query.start, query.end)) query.copy(start = lower(query.start), end = upper(query.end)) else null
            is SynologyPhotoQuery.Filtered -> {
                val from = lower(maxOf(query.start, query.filter.startTime ?: query.start))
                val to = upper(minOf(query.end, query.filter.endTime ?: query.end))
                if (from > to) null else query.copy(start = from, end = to, filter = query.filter.copy(
                    startTime = query.filter.startTime?.let { from }, endTime = query.filter.endTime?.let { to },
                ))
            }
            else -> null
        }
    }

    fun groups(items: List<SynologyPhoto>, recent: Boolean, zone: ZoneId): List<SynologyPhotoDayGroup> = items.groupBy {
        Instant.ofEpochMilli(((if (recent) it.indexedAt else it.takenAt) * 1_000).toLong()).atZone(zone).toLocalDate()
    }.toSortedMap(compareByDescending { it }).map { SynologyPhotoDayGroup(it.key, it.value) }
}
