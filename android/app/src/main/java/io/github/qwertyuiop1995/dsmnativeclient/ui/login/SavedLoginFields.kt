package io.github.qwertyuiop1995.dsmnativeclient.ui.login

import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile

/** 表单的非敏感字段可重建；保存密码只允许回填到原地址、端口与账号。 */
internal fun savedLoginFieldsMatch(profile: NasProfile?, address: String, port: String, username: String): Boolean =
    profile != null && profile.address.trim() == address.trim() && profile.username.trim() == username.trim() &&
        if (profile.port == null) port.isBlank() else port.toIntOrNull() == profile.port
