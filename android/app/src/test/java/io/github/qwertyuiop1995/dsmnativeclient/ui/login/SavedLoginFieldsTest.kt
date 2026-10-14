package io.github.qwertyuiop1995.dsmnativeclient.ui.login

import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import org.junit.Assert.*
import org.junit.Test

class SavedLoginFieldsTest {
    private val profile = NasProfile("a", "NAS", "https://nas.example.invalid", "account", 5001)

    @Test fun `只有原目标和账号允许回填保存密码`() {
        assertTrue(savedLoginFieldsMatch(profile, profile.address, "5001", profile.username))
        assertFalse(savedLoginFieldsMatch(profile, "https://other.example.invalid", "5001", profile.username))
        assertFalse(savedLoginFieldsMatch(profile, profile.address, "5001", "another-account"))
        assertFalse(savedLoginFieldsMatch(profile, profile.address, "5443", profile.username))
    }

    @Test fun `默认端口只匹配空端口且无资料不能猜测密码归属`() {
        val implicitPort = profile.copy(port = null)
        assertTrue(savedLoginFieldsMatch(implicitPort, implicitPort.address, "", implicitPort.username))
        assertFalse(savedLoginFieldsMatch(implicitPort, implicitPort.address, "invalid", implicitPort.username))
        assertFalse(savedLoginFieldsMatch(null, "", "", ""))
    }

    @Test fun `显示名称和保存偏好变化不改变密码归属`() {
        assertTrue(savedLoginFieldsMatch(profile.copy(name = "Renamed", rememberSession = false), profile.address, "5001", profile.username))
    }
}
