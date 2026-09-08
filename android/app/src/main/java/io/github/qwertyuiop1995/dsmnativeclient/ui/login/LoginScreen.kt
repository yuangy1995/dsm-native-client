package io.github.qwertyuiop1995.dsmnativeclient.ui.login

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.LoginState
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.ConfirmDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.ErrorBanner
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.settings.LanguageMenu

@Composable
internal fun LoginScreen(state: LoginState, model: AppViewModel) {
    val profile = state.profiles.firstOrNull { it.id == state.selectedProfileId }
    var formVisible by rememberSaveable { mutableStateOf(state.profiles.isEmpty()) }
    var removal by remember { mutableStateOf<NasProfile?>(null) }
    LaunchedEffect(state.error, state.needsOtp) {
        if (state.error != null || state.needsOtp) formVisible = true
    }
    BackHandler(enabled = formVisible && state.profiles.isNotEmpty() && !state.isConnecting) { formVisible = false }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        if (formVisible) {
            ConnectionForm(
                state = state, profile = profile,
                onBack = if (state.profiles.isNotEmpty()) ({ formVisible = false }) else null,
                onConnect = { name, address, port, username, password, otp, remember, automatic ->
                    model.connect(state.selectedProfileId, name, address, port, username, password, otp, remember, automatic)
                },
            )
        } else {
            SavedDevices(
                state = state,
                onSelect = { model.selectProfile(it); formVisible = true },
                onConnect = { model.restore(it) },
                onRemove = { removal = it },
                onAdd = { model.newProfile(); formVisible = true },
            )
        }
    }
    if (state.isConnecting) LoginConnectionOverlay(
        status = state.connectionStatus,
        canCancel = state.connectionStatus != null,
        onCancel = { model.cancelLogin() },
    )
    removal?.let { target ->
        ConfirmDialog(
            title = stringResource(R.string.remove_profile_title, target.name),
            message = stringResource(R.string.remove_profile_message),
            confirm = stringResource(R.string.remove), destructive = true,
            onConfirm = { model.removeProfile(target); removal = null },
            onDismiss = { removal = null },
        )
    }
}

@Composable
private fun SavedDevices(
    state: LoginState,
    onSelect: (NasProfile) -> Unit,
    onConnect: (NasProfile) -> Unit,
    onRemove: (NasProfile) -> Unit,
    onAdd: () -> Unit,
) {
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        ClientToolbar(stringResource(R.string.app_name), actions = { LanguageMenu() })
        HorizontalDivider()
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Text(stringResource(R.string.client_login_choose), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.client_login_choose_hint), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
            }
            items(state.profiles, key = NasProfile::id) { profile ->
                var menu by remember { mutableStateOf(false) }
                ClientGroup {
                    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Dns, null, Modifier.size(40.dp))
                        TextButton(onClick = { onSelect(profile) }, modifier = Modifier.weight(1f)) {
                            Column(Modifier.fillMaxWidth()) {
                                Text(profile.name, color = MaterialTheme.colorScheme.onSurface,
                                    fontWeight = FontWeight.SemiBold)
                                Text(stringResource(R.string.client_saved_device),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        OutlinedButton(onClick = { onConnect(profile) }, enabled = !state.isConnecting,
                            contentPadding = PaddingValues(horizontal = 12.dp)) { Text(stringResource(R.string.connect)) }
                        Box {
                            IconButton(onClick = { menu = true }) {
                                Icon(Icons.Outlined.MoreVert, stringResource(R.string.client_device_actions))
                            }
                            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(text = { Text(stringResource(R.string.edit)) },
                                    onClick = { menu = false; onSelect(profile) })
                                DropdownMenuItem(text = { Text(stringResource(R.string.remove_saved_nas)) },
                                    onClick = { menu = false; onRemove(profile) })
                            }
                        }
                    }
                }
            }
            item {
                OutlinedButton(onClick = onAdd, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                    Icon(Icons.Outlined.Add, null)
                    Text(stringResource(R.string.client_add_nas), Modifier.padding(start = 8.dp))
                }
            }
        }
        Text(stringResource(R.string.client_saved_password_note), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(24.dp))
    }
}

@Composable
private fun ConnectionForm(
    state: LoginState,
    profile: NasProfile?,
    onBack: (() -> Unit)?,
    onConnect: (String, String, String, String, String, String, Boolean, Boolean) -> Unit,
) {
    val profileId = state.selectedProfileId
    var name by rememberSaveable(profileId) { mutableStateOf(profile?.name.orEmpty()) }
    var address by rememberSaveable(profileId) { mutableStateOf(profile?.address.orEmpty()) }
    var port by rememberSaveable(profileId) { mutableStateOf(profile?.port?.toString().orEmpty()) }
    var username by rememberSaveable(profileId) { mutableStateOf(profile?.username.orEmpty()) }
    // 密码与验证码只留在当前组合内，绝不进入 Activity SavedState。
    var password by remember(profileId) { mutableStateOf(state.savedPassword) }
    var otp by remember(profileId) { mutableStateOf("") }
    var remembersPassword by rememberSaveable(profileId) { mutableStateOf(state.rememberPassword) }
    var automatic by rememberSaveable(profileId) { mutableStateOf(state.autoLoginEnabled) }
    var advanced by rememberSaveable { mutableStateOf(false) }
    var passwordVisible by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val otpFocus = remember { FocusRequester() }
    LaunchedEffect(profileId, state.savedPassword) {
        password = state.savedPassword
        otp = ""
        remembersPassword = state.rememberPassword
        automatic = state.autoLoginEnabled
    }
    val submit: () -> Unit = {
        if (!state.isConnecting) {
            focus.clearFocus(); keyboard?.hide()
            onConnect(name, address, port, username, password, otp, remembersPassword, automatic)
        }
    }
    Scaffold(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().imePadding(),
        contentWindowInsets = WindowInsets(0),
        topBar = { ClientToolbar(stringResource(R.string.client_connect_nas), onBack, actions = { LanguageMenu() }) },
        bottomBar = {
            Surface(color = MaterialTheme.colorScheme.background) {
                Button(onClick = submit, enabled = !state.isConnecting,
                    modifier = Modifier.fillMaxWidth().padding(20.dp).heightIn(min = 52.dp)) {
                    Text(stringResource(R.string.connect))
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
            .padding(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.Dns, null, Modifier.size(40.dp))
                Text(name.ifBlank { stringResource(R.string.client_new_nas) },
                    style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                IconButton(onClick = { advanced = !advanced }) {
                    Icon(Icons.Outlined.Edit, stringResource(R.string.display_name))
                }
            }
            OutlinedTextField(address, { address = it }, enabled = !state.isConnecting, label = { Text(stringResource(R.string.nas_address_or_quickconnect)) },
                singleLine = true, shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth().testTag("login_address"))
            OutlinedTextField(username, { username = it }, enabled = !state.isConnecting, label = { Text(stringResource(R.string.account)) },
                singleLine = true, shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth().testTag("login_username"))
            OutlinedTextField(password, { password = it }, enabled = !state.isConnecting, label = { Text(stringResource(R.string.password)) },
                singleLine = true, shape = MaterialTheme.shapes.small,
                visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { passwordVisible = !passwordVisible }, enabled = !state.isConnecting) {
                        Icon(if (passwordVisible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                            stringResource(if (passwordVisible) R.string.client_hide_password else R.string.client_show_password))
                    }
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password,
                    imeAction = if (state.needsOtp) ImeAction.Next else ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.fillMaxWidth().testTag("login_password"))
            if (state.needsOtp) {
                OutlinedTextField(otp, { otp = it.filter(Char::isDigit) }, enabled = !state.isConnecting,
                label = { Text(stringResource(R.string.two_factor_code)) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.fillMaxWidth().focusRequester(otpFocus).testTag("login_otp"))
                // 焦点请求必须在 Scaffold 的内容子组合挂载后执行。
                LaunchedEffect(state.isConnecting) { if (!state.isConnecting) otpFocus.requestFocus() }
            }
            LoginPreference(stringResource(R.string.remember_password), remembersPassword, !state.isConnecting) {
                remembersPassword = it
                if (!it) automatic = false
            }
            LoginPreference(stringResource(R.string.auto_login), automatic, !state.isConnecting) {
                automatic = it
                if (it) remembersPassword = true
            }
            TextButton(onClick = { advanced = !advanced }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.client_more_connection_options), modifier = Modifier.weight(1f))
                Icon(if (advanced) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
            }
            if (advanced) {
                OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.display_name)) },
                    singleLine = true, modifier = Modifier.fillMaxWidth().testTag("login_name"))
                OutlinedTextField(port, { port = it.filter(Char::isDigit) },
                    label = { Text(stringResource(R.string.custom_https_port)) }, singleLine = true,
                    supportingText = { Text(stringResource(R.string.custom_https_port_note)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth())
            }
            state.error?.let { ErrorBanner(it.localize(LocalContext.current).combined) }
            Text(stringResource(R.string.client_saved_password_note), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun LoginPreference(title: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = checked, enabled = enabled,
        role = Role.Switch, onValueChange = onChange), verticalAlignment = Alignment.CenterVertically) {
        Text(title, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(checked, onCheckedChange = null, enabled = enabled)
    }
}

@Composable
internal fun LoginConnectionOverlay(status: ConnectionStatus?, canCancel: Boolean, onCancel: () -> Unit) {
    Dialog(onDismissRequest = { if (canCancel) onCancel() },
        properties = DialogProperties(dismissOnBackPress = canCancel, dismissOnClickOutside = false)) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(28.dp)
                .semantics { liveRegion = LiveRegionMode.Polite },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Box(Modifier.size(72.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.fillMaxSize(), strokeWidth = 3.dp,
                        trackColor = MaterialTheme.colorScheme.primaryContainer)
                    Icon(Icons.Outlined.Dns, null, Modifier.size(28.dp))
                }
                Text(stringResource(if (status == null) R.string.client_switching_nas else R.string.client_connecting),
                    style = MaterialTheme.typography.titleMedium)
                if (status != null) Text(stringResource(when (status) {
                    ConnectionStatus.AUTHENTICATING -> R.string.client_authenticating
                    ConnectionStatus.PREPARING -> R.string.status_preparing_connection
                    ConnectionStatus.CONNECTING_DIRECT -> R.string.status_connecting_nas
                    ConnectionStatus.LOOKING_UP_QUICK_CONNECT -> R.string.status_looking_up_quickconnect
                    ConnectionStatus.TRYING_LOCAL -> R.string.status_trying_local
                    ConnectionStatus.TRYING_EXTERNAL -> R.string.status_trying_external
                    ConnectionStatus.ESTABLISHING_RELAY -> R.string.status_establishing_relay
                    ConnectionStatus.RESTORING_SESSION -> R.string.status_restoring_session
                }), style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.client_connecting_hint), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (canCancel) TextButton(onClick = onCancel, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.client_cancel_connection))
                }
            }
        }
    }
}
