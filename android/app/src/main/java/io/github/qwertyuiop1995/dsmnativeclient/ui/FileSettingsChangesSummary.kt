package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientGroup
import java.text.NumberFormat

@Composable
internal fun FileSettingsChangesSummary(change: FileSettingsChange) {
    val context = LocalContext.current
    val numbers = NumberFormat.getIntegerInstance(context.resources.configuration.locales[0])
    fun text(id: Int) = context.getString(id)
    fun bool(value: Boolean) = text(if (value) R.string.enabled else R.string.disabled)
    val rows = buildList<Pair<Int, String>> {
        when (change) {
            is FileSettingsChange.General -> {
                val old = change.baseline; val new = change.updated
                if (old.recordsTransfers != new.recordsTransfers) add(R.string.file_settings_record_transfers to bool(new.recordsTransfers))
                if (old.usesDefaultPermissions != new.usesDefaultPermissions) add(R.string.file_settings_default_permissions to bool(new.usesDefaultPermissions))
                if (old.showsAccounts != new.showsAccounts) add(R.string.file_settings_show_accounts to bool(new.showsAccounts))
                if (old.customSharingPage != new.customSharingPage) add(R.string.file_settings_custom_page to bool(new.customSharingPage == true))
                if (old.sharing != new.sharing) add(R.string.file_settings_share_permission to text(new.sharing.label()))
                if (old.fileRequests != new.fileRequests) add(R.string.file_settings_request_permission to text(new.fileRequests.label()))
                if (old.remoteMounts != new.remoteMounts) add(R.string.file_settings_mount_permission to text(new.remoteMounts.label()))
                if (old.isoMounts != new.isoMounts) add(R.string.file_settings_iso_permission to text(new.isoMounts.label()))
                if (old.defaultLinkLimit != new.defaultLinkLimit) add(R.string.file_settings_link_limit to numbers.format(new.defaultLinkLimit))
                if (old.bandwidth != new.bandwidth) add(R.string.file_settings_bandwidth_policy to text(new.bandwidth.label()))
                if (old.schedule != new.schedule) add(R.string.file_settings_schedule_title to text(R.string.file_settings_schedule_changed))
                for ((label, before, after) in listOf(Triple(R.string.file_settings_share_accounts, old.sharingAccounts, new.sharingAccounts),
                        Triple(R.string.file_settings_request_accounts, old.requestAccounts, new.requestAccounts)))
                    if (before != after) add(label to context.getString(R.string.file_settings_members_changed, (after - before).size, (before - after).size))
            }
            is FileSettingsChange.MountScope -> if (change.baseline != change.updated) add(R.string.file_settings_remote_access to text(change.updated.label()))
            is FileSettingsChange.MountAccount -> if (change.baseline.enabled != change.enabled) add(R.string.file_settings_account_allowed to bool(change.enabled))
            is FileSettingsChange.Bandwidth -> {
                val old = change.baseline; val new = change.updated
                if (old.policy != new.policy) add(R.string.file_settings_bandwidth_policy to text(new.policy.label(new.ownerType.isGroup)))
                if (old.schedule != new.schedule) add(R.string.file_settings_schedule_title to text(R.string.file_settings_schedule_changed))
                for ((label, before, after) in listOf(Triple(R.string.file_settings_upload_limit, old.uploadLimit, new.uploadLimit),
                        Triple(R.string.file_settings_download_limit, old.downloadLimit, new.downloadLimit),
                        Triple(R.string.file_settings_alternate_upload, old.alternateUploadLimit, new.alternateUploadLimit),
                        Triple(R.string.file_settings_alternate_download, old.alternateDownloadLimit, new.alternateDownloadLimit)))
                    if (before != after) add(label to numbers.format(after))
            }
            is FileSettingsChange.Theme -> {
                val old = change.baseline; val new = change.updated
                if (old.customLogo != new.customLogo) add(R.string.file_theme_logo to bool(new.customLogo))
                if (old.customBackground != new.customBackground) add(R.string.file_theme_background to bool(new.customBackground))
                if (old.logoPosition != new.logoPosition) add(R.string.file_theme_logo_position to text(new.logoPosition.label()))
                if (old.backgroundPosition != new.backgroundPosition) add(R.string.file_theme_background_position to text(new.backgroundPosition.label()))
                if (old.backgroundColor != new.backgroundColor) add(R.string.file_theme_color to new.backgroundColor)
                if (old.footer != new.footer) add(R.string.file_theme_footer to new.footer)
                if (old.footerUsesHtml != new.footerUsesHtml) add(R.string.file_theme_footer_html to bool(new.footerUsesHtml))
                new.logoImage?.let { add(R.string.file_theme_choose_logo to themeImageName(it, context)) }
                new.backgroundImage?.let { add(R.string.file_theme_choose_background to themeImageName(it, context)) }
            }
        }
    }
    if (rows.isNotEmpty()) ClientGroup {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.file_settings_changes), style = MaterialTheme.typography.titleSmall)
            rows.forEach { (title, value) -> Text(stringResource(R.string.file_settings_change_value, stringResource(title), value)) }
        }
    }
}
