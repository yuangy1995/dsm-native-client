package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoDisplaySettings
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

internal object SynologyPhotoDisplayFormat {
    fun date(settings: SynologyPhotoDisplaySettings?, locale: Locale): DateTimeFormatter =
        (settings?.let { DateTimeFormatter.ofPattern(if (it.grouping == SynologyPhotoDisplaySettings.Grouping.MONTH) it.date.monthPattern else it.date.pattern) }
            ?: DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)).withLocale(locale)

    fun timestamp(settings: SynologyPhotoDisplaySettings?, locale: Locale, zone: ZoneId = ZoneId.systemDefault()): DateTimeFormatter =
        (settings?.let { DateTimeFormatter.ofPattern(it.date.pattern + if (it.clock == SynologyPhotoDisplaySettings.Clock.TWELVE) " h:mm a" else " HH:mm") }
            ?: DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM)).withLocale(locale).withZone(zone)
}
