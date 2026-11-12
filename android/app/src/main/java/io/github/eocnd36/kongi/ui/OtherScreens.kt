package io.github.eocnd36.kongi.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.SystemUpdate
import androidx.compose.material.icons.outlined.Download
import io.github.eocnd36.kongi.UpdateStatus
import io.github.eocnd36.kongi.Updates
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.github.eocnd36.kongi.Pairing
import io.github.eocnd36.kongi.R
import kotlinx.coroutines.launch

/** 처음 연결: 콩이와 두 단계 안내, QR 찍기 버튼 */
@Composable
fun PairScreen(onScan: () -> Unit, snackbar: SnackbarHostState) {
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Spacer(Modifier.height(40.dp))
            Kongi(Mood.Idle, size = 84.dp)
            Spacer(Modifier.height(20.dp))
            Text(stringResource(R.string.pair_title), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            Text(
                stringResource(if (AppModel.needsRepair) R.string.repair else R.string.pair_text),
                style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(28.dp))
            Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Step(1, stringResource(R.string.pair_step1))
                    Step(2, stringResource(R.string.pair_step2))
                }
            }
            Spacer(Modifier.height(28.dp))
            Button(onClick = onScan, modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(28.dp)) {
                Icon(Icons.Outlined.QrCodeScanner, null)
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.scan), style = MaterialTheme.typography.titleMedium)
            }
            Spacer(Modifier.height(40.dp))
        }
    }
}

@Composable
private fun Step(number: Int, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.size(28.dp)) {
            Text(
                "$number", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer,
                textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp),
            )
        }
        Spacer(Modifier.width(14.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(top = 2.dp))
    }
}

/** 이 휴대폰 설정: 연결된 Mac, 백그라운드 연결, 알림 테스트, 연결 해제 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    snackbar: SnackbarHostState,
    version: String,
    onBackground: (Boolean) -> Unit,
    onScan: () -> Unit,
    onUnpair: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var confirmUnpair by remember { mutableStateOf(false) }
    var showLicenses by remember { mutableStateOf(false) }
    val name = AppModel.state?.mac ?: AppModel.pairing?.name?.ifEmpty { null } ?: "Mac"
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(onClick = { AppModel.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back)) } },
                title = { Text(stringResource(R.string.settings)) },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            SectionTitle(stringResource(R.string.this_phone))
            Group {
                ListItem(
                    headlineContent = { Text(stringResource(R.string.connected_mac)) },
                    supportingContent = { Text(name) },
                    leadingContent = { Icon(Icons.Outlined.Computer, null) },
                    trailingContent = { PulsingDot(if (AppModel.live) LocalStatus.current.green else MaterialTheme.colorScheme.outline, size = 8.dp, pulsing = false) },
                    colors = itemColors(),
                )
                ListItem(
                    headlineContent = { Text(stringResource(R.string.background_title)) },
                    supportingContent = { Text(stringResource(R.string.background_help)) },
                    leadingContent = { Icon(Icons.Outlined.Sync, null) },
                    trailingContent = { Switch(AppModel.background, onCheckedChange = onBackground) },
                    colors = itemColors(),
                )
                ListItem(
                    headlineContent = { Text(stringResource(R.string.test_notification)) },
                    supportingContent = { Text(stringResource(R.string.test_help)) },
                    leadingContent = { Icon(Icons.Outlined.NotificationsActive, null) },
                    colors = itemColors(),
                    modifier = Modifier.clickable { scope.launch { AppModel.testNotification() } },
                )
            }
            SectionTitle(stringResource(R.string.connection))
            Group {
                ListItem(
                    headlineContent = { Text(stringResource(R.string.scan_other)) },
                    leadingContent = { Icon(Icons.Outlined.QrCodeScanner, null) },
                    colors = itemColors(),
                    modifier = Modifier.clickable(onClick = onScan),
                )
                ListItem(
                    headlineContent = { Text(stringResource(R.string.disconnect), color = MaterialTheme.colorScheme.error) },
                    supportingContent = { Text(stringResource(R.string.disconnect_help)) },
                    leadingContent = { Icon(Icons.Outlined.LinkOff, null, tint = MaterialTheme.colorScheme.error) },
                    colors = itemColors(),
                    modifier = Modifier.clickable { confirmUnpair = true },
                )
            }
            SectionTitle(stringResource(R.string.updates))
            Group {
                val context = LocalContext.current
                var notify by remember { mutableStateOf(Updates.enabled(context, Updates.NOTIFY)) }
                var auto by remember { mutableStateOf(Updates.enabled(context, Updates.AUTO)) }
                ListItem(
                    headlineContent = { Text(stringResource(R.string.update_notify)) },
                    supportingContent = { Text(stringResource(R.string.update_notify_help)) },
                    leadingContent = { Icon(Icons.Outlined.NotificationsActive, null) },
                    trailingContent = { Switch(notify, onCheckedChange = { notify = it; Updates.set(context, Updates.NOTIFY, it) }) },
                    colors = itemColors(),
                )
                ListItem(
                    headlineContent = { Text(stringResource(R.string.update_auto)) },
                    supportingContent = { Text(stringResource(R.string.update_auto_help)) },
                    leadingContent = { Icon(Icons.Outlined.Download, null) },
                    trailingContent = { Switch(auto, onCheckedChange = { auto = it; Updates.set(context, Updates.AUTO, it) }) },
                    colors = itemColors(),
                )
                val status = AppModel.updateStatus
                ListItem(
                    headlineContent = {
                        Text(stringResource(if (status == UpdateStatus.Available) R.string.update_now else R.string.update_check))
                    },
                    supportingContent = {
                        if (status == UpdateStatus.Available && AppModel.updateChanges.isNotEmpty()) {
                            Text(AppModel.updateChanges.joinToString("\n") { "• $it" })
                        } else Text(stringResource(when (status) {
                            UpdateStatus.Checking -> R.string.update_checking
                            UpdateStatus.UpToDate -> R.string.update_latest
                            UpdateStatus.Available -> R.string.update_available
                            UpdateStatus.Installing -> R.string.update_installing
                            UpdateStatus.Failed -> R.string.update_failed
                            UpdateStatus.Idle -> R.string.update_idle
                        }))
                    },
                    leadingContent = { Icon(Icons.Outlined.SystemUpdate, null) },
                    colors = itemColors(),
                    modifier = Modifier.clickable(enabled = status != UpdateStatus.Checking && status != UpdateStatus.Installing) {
                        if (status == UpdateStatus.Available) Updates.installNow(context) else Updates.check(context, force = true)
                    },
                )
            }
            SectionTitle(stringResource(R.string.about))
            Group {
                ListItem(
                    headlineContent = { Text(stringResource(R.string.licenses)) },
                    leadingContent = { Icon(Icons.Outlined.Description, null) },
                    colors = itemColors(),
                    modifier = Modifier.clickable { showLicenses = true },
                )
            }
            Text(
                stringResource(R.string.version, version), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline, modifier = Modifier.fillMaxWidth().padding(24.dp), textAlign = TextAlign.Center,
            )
        }
    }
    if (showLicenses) {
        val context = LocalContext.current
        val text = remember { runCatching { context.assets.open("THIRD_PARTY_NOTICES.md").bufferedReader().readText() }.getOrDefault("") }
        AlertDialog(
            onDismissRequest = { showLicenses = false },
            title = { Text(stringResource(R.string.licenses)) },
            text = { Box(Modifier.verticalScroll(rememberScrollState())) { MarkdownText(text, style = MaterialTheme.typography.bodySmall) } },
            confirmButton = { TextButton(onClick = { showLicenses = false }) { Text(stringResource(android.R.string.ok)) } },
        )
    }
    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text(stringResource(R.string.disconnect_confirm, name)) },
            text = { Text(stringResource(R.string.disconnect_help)) },
            confirmButton = {
                TextButton(onClick = { confirmUnpair = false; onUnpair() }) { Text(stringResource(R.string.disconnect), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text(stringResource(android.R.string.cancel)) } },
        )
    }
}

@Composable
private fun Group(content: @Composable () -> Unit) {
    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
        Column { content() }
    }
}

@Composable
private fun itemColors() = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer)

/** 링크·카메라로 들어온 연결 확인 */
@Composable
fun PairConfirmDialog(pairing: Pairing, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    val existing = AppModel.pairing
    val name = pairing.name.ifEmpty { "Mac" }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.pair_confirm_title)) },
        text = {
            Column {
                Text(stringResource(R.string.pair_confirm_detail, name, pairing.hosts.joinToString(", ")))
                if (existing != null) {
                    Spacer(Modifier.height(12.dp))
                    Text(stringResource(R.string.pair_confirm_replace, existing.name.ifEmpty { "Mac" }), fontWeight = FontWeight.SemiBold)
                }
            }
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.pair_confirm_ok)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) } },
    )
}

/** 앱을 열면: 새 버전이 있으면 바뀐 것과 "업데이트" 버튼, 방금 업데이트했으면 바뀐 것 (한 번) */
@Composable
fun UpdateDialogs() {
    val context = LocalContext.current
    val version = AppModel.updateVersion
    if (AppModel.updatePrompt && version != null && AppModel.updateStatus == io.github.eocnd36.kongi.UpdateStatus.Available) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { AppModel.updatePrompt = false },
            icon = { Icon(Icons.Outlined.SystemUpdate, null) },
            title = { Text(stringResource(R.string.update_title, version)) },
            text = { ChangeList(AppModel.updateChanges) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    AppModel.updatePrompt = false
                    Updates.installNow(context)
                }) { Text(stringResource(R.string.update_now)) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = {
                    AppModel.updatePrompt = false
                    Updates.dismiss(context, version)
                }) { Text(stringResource(R.string.later)) }
            },
        )
    }
    AppModel.installedNotes?.let { (installed, changes) ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { AppModel.installedNotes = null },
            icon = { Icon(Icons.Outlined.SystemUpdate, null) },
            title = { Text(stringResource(R.string.updated_title, installed)) },
            text = { ChangeList(changes) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { AppModel.installedNotes = null }) { Text(stringResource(R.string.ok)) }
            },
        )
    }
}

@Composable
private fun ChangeList(changes: List<String>) {
    Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(6.dp)) {
        if (changes.isEmpty()) Text(stringResource(R.string.update_tap))
        changes.forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) }
    }
}
