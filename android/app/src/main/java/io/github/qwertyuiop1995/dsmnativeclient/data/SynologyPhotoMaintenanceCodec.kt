package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid

internal object SynologyPhotoMaintenanceCodec {
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.maintenance ?: invalid(); val original = value.original
        if (original.profileId != row.profileId || original.userId != row.userId || !original.canStart(value.action) ||
            row.album != null || row.name != null || row.targets.isNotEmpty() ||
            !row.submitted && (value.attempted || value.acknowledged || value.rejected) ||
            value.acknowledged && (!value.attempted || value.rejected) || value.rejected && !value.attempted ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && !value.acknowledged ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && value.attempted && !value.rejected) invalid()
    }
}
