package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*

/** 冻结一次领取时的浏览范围；完整分页才允许环绕，时间线不向前环绕。 */
internal data class SynologyPhotoAutomaticPreviewView(
    val photos: List<SynologyPhoto>, val current: SynologyPhoto?,
    val space: SynologyPhotoSpace, val spaces: List<SynologyPhotoSpace>, val managesShared: Boolean,
    val timeline: Boolean, val complete: Boolean,
) {
    fun ordered(visible: Set<SynologyPhotoId>): List<SynologyPhoto> =
        (listOfNotNull(current) + neighbors() + photos.filter { it.id in visible }).distinctBy { it.id }

    fun neighbors(): List<SynologyPhoto> {
        val photo = current ?: return emptyList()
        val index = photos.indexOfFirst { it.id == photo.id }.takeIf { it >= 0 } ?: return emptyList()
        fun neighbor(offset: Int, wraps: Boolean): SynologyPhoto? {
            val position = index + offset
            if (position in photos.indices) return photos[position]
            return if (wraps && complete) photos[Math.floorMod(position, photos.size)] else null
        }
        var previous = listOf(-2, -1).mapNotNull { neighbor(it, !timeline) }
        var next = listOf(1, 2, 3).mapNotNull { neighbor(it, true) }
        val count = (previous + photo + next).distinctBy { it.id }.size
        if (count < 4) next = next.take(1) else if (count == 4) next = next.dropLast(1)
        if (count < 6) previous = previous.takeLast(1)
        return (next + previous).filter { it.id != photo.id && it.mediaType !in setOf("video", "video360") }.distinctBy { it.id }
    }
}
