package io.github.qwertyuiop1995.dsmnativeclient.ui.login

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.LocalNetworkPermissionRequest

@Composable
internal fun LocalNetworkPermissionEffect(request: LocalNetworkPermissionRequest) {
    val pending by request.pending.collectAsStateWithLifecycle()
    var launched by rememberSaveable { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        request.complete(launched, allowed)
    }
    LaunchedEffect(pending) {
        val id = pending ?: return@LaunchedEffect
        if (launched != id) {
            launched = id
            launcher.launch(Manifest.permission.ACCESS_LOCAL_NETWORK)
        }
    }
}
