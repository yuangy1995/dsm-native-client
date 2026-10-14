package io.github.qwertyuiop1995.dsmnativeclient.ui

import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class DownloadSettingsDraftTest {
    @Test
    fun `有效草稿保留目录空格且不关闭未编辑的独立计划`() {
        val draft = DownloadSettingsDraft.from(
            DownloadSettings(
                defaultDestination = "/downloads/current ",
                emuleEnabled = false,
                btDownloadLimitKb = 500,
                scheduleEnabled = true,
                emuleScheduleEnabled = true,
            ),
        )

        val settings = draft.toSettingsOrNull(supportsSchedule = true)!!

        assertEquals("downloads/current ", settings.defaultDestination)
        assertEquals(500, settings.btDownloadLimitKb)
        org.junit.Assert.assertTrue(settings.emuleScheduleEnabled)
    }

    @Test
    fun `越界限速和父目录片段不会进入保存请求`() {
        val base = DownloadSettingsDraft.from(DownloadSettings(defaultDestination = "downloads"))

        assertNull(base.copy(btDownload = "1000001").toSettingsOrNull(true))
        assertNull(base.copy(destination = "downloads/../private").toSettingsOrNull(true))
    }
}
