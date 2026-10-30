package io.github.eocnd36.kongi.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.MoreTime
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.eocnd36.kongi.DiffLine
import io.github.eocnd36.kongi.FileChange
import io.github.eocnd36.kongi.R
import io.github.eocnd36.kongi.SessionDetail
import io.github.eocnd36.kongi.TimelineEntry
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionScreen(id: String, snackbar: SnackbarHostState) {
    val summary = AppModel.state?.sessions?.firstOrNull { it.id == id }
    val detail = AppModel.detail?.takeIf { it.id == id }
    val busy = summary?.busy ?: detail?.busy ?: false
    var tab by rememberSaveable(id) { mutableStateOf(0) }
    val scope = rememberCoroutineScope()

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = { AppModel.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back)) }
                    },
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                        Kongi(
                            if (summary?.ended == true) Mood.Sleeping else Mood.named(summary?.mood.orEmpty()),
                            size = 22.dp, growth = growth(AppModel.state),
                        )
                        Spacer(Modifier.width(6.dp))
                        Column {
                            Text(summary?.project ?: detail?.project ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis)
                            GlowText(
                                summary?.state ?: detail?.state ?: "", active = busy,
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                        }
                    },
                    actions = {
                        if (summary != null && !summary.ended) {
                            IconButton(
                                onClick = { scope.launch { AppModel.continueAfterReset(id) } },
                                enabled = !summary.continueScheduled,
                            ) {
                                Icon(
                                    Icons.Outlined.MoreTime,
                                    stringResource(if (summary.continueScheduled) R.string.continue_scheduled else R.string.continue_after_reset),
                                    tint = if (summary.continueScheduled) LocalStatus.current.green else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    },
                )
                // 일하는 동안 위쪽에 빛줄기가 지나갑니다.
                Box(Modifier.fillMaxWidth().height(2.dp)) {
                    if (busy) SweepBar(MaterialTheme.colorScheme.primary)
                }
                PrimaryTabRow(selectedTabIndex = tab, containerColor = MaterialTheme.colorScheme.surface) {
                    Tab(tab == 0, onClick = { tab = 0 }, text = { Text(stringResource(R.string.conversation)) })
                    Tab(tab == 1, onClick = { tab = 1 }, text = { Text(stringResource(R.string.changes) + (detail?.changes?.size?.takeIf { it > 0 }?.let { " $it" } ?: "")) })
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(top = padding.calculateTopPadding()).fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                when {
                    detail == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { BeanDots(dot = 9.dp) }
                    tab == 0 -> Conversation(detail)
                    else -> Changes(detail.changes)
                }
            }
            if (tab == 0 && summary?.ended != true) Composer(id)
            else Spacer(Modifier.navigationBarsPadding())
        }
    }
}

// MARK: conversation

@Composable
private fun Conversation(detail: SessionDetail) {
    val entries = detail.timeline
    val list = rememberLazyListState()
    val lastAssistant = entries.lastOrNull { it is TimelineEntry.Message && it.role == "assistant" }?.id
    // 새 글이나 단계가 오면 맨 아래(최신)로
    LaunchedEffect(entries.lastOrNull()?.id) { if (list.firstVisibleItemIndex <= 2) list.animateScrollToItem(0) }
    if (entries.isEmpty() && !detail.thinking) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.no_activity), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(), state = list, reverseLayout = true,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (detail.thinking) {
            item(key = "thinking") { Thinking(Modifier.animateItem()) }
        }
        items(entries.asReversed(), key = { it.id }) { entry ->
            Box(Modifier.animateItem()) {
                when (entry) {
                    is TimelineEntry.Message -> MessageBubble(entry, latest = entry.id == lastAssistant)
                    is TimelineEntry.Step -> StepRow(entry)
                }
            }
        }
    }
}

@Composable
private fun Thinking(modifier: Modifier = Modifier) {
    Row(modifier.padding(start = 4.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Avatar()
        Spacer(Modifier.width(10.dp))
        BeanDots(dot = 6.dp)
    }
}

@Composable
private fun Avatar() {
    Box(
        Modifier.size(26.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer),
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(R.drawable.ic_notification), null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun MessageBubble(message: TimelineEntry.Message, latest: Boolean) {
    if (message.role == "user") {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Column(horizontalAlignment = Alignment.End, modifier = Modifier.widthIn(max = 320.dp).padding(start = 48.dp)) {
                Surface(
                    shape = RoundedCornerShape(20.dp, 20.dp, 6.dp, 20.dp),
                    color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = if (message.queued) 0.55f else 1f),
                ) {
                    Text(
                        message.text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 9.dp),
                    )
                }
                if (message.queued) {
                    Text(stringResource(R.string.sent_queued), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 3.dp))
                }
            }
        }
    } else {
        Row(Modifier.fillMaxWidth().padding(end = 24.dp)) {
            Avatar()
            Spacer(Modifier.width(10.dp))
            Surface(shape = RoundedCornerShape(6.dp, 20.dp, 20.dp, 20.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                BloomingMarkdown(
                    id = message.id, text = message.text,
                    // 방금(10초 안) 온 마지막 대답만 써 내려갑니다.
                    fresh = latest && Duration.between(message.time, Instant.now()).seconds < 10,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
        }
    }
}

private fun icon(kind: String): ImageVector = when (kind) {
    "read" -> Icons.Outlined.Description
    "edit", "write" -> Icons.Outlined.Edit
    "run" -> Icons.Outlined.Terminal
    "search" -> Icons.Outlined.Search
    "web" -> Icons.Outlined.Language
    "agent" -> Icons.Outlined.AccountTree
    "plan" -> Icons.Outlined.Checklist
    "question" -> Icons.Outlined.HelpOutline
    else -> Icons.Outlined.Extension
}

private val clock = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())

@Composable
private fun StepRow(step: TimelineEntry.Step) {
    val status = LocalStatus.current
    val running = step.status == "running"
    var showOutput by remember(step.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().animateContentSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 2.dp)) {
            Box(
                Modifier.size(26.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHigh),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon(step.kind), null, Modifier.size(15.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(10.dp))
            GlowText(
                step.label, active = running, modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodyMedium,
                base = if (running) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.width(8.dp))
            when (step.status) {
                "running" -> Spinner(status.orange, size = 14.dp)
                "failed" -> Icon(Icons.Filled.Close, null, Modifier.size(16.dp), tint = status.red)
                else -> Icon(Icons.Filled.Check, null, Modifier.size(16.dp), tint = status.green)
            }
            Spacer(Modifier.width(8.dp))
            Text(clock.format(step.time), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
        }
        if (step.preview.isNotEmpty()) {
            DiffLines(step.preview, Modifier.padding(start = 36.dp, top = 4.dp), numbers = false)
        }
        if (step.output.isNotEmpty()) {
            Text(
                step.output, fontFamily = FontFamily.Monospace, fontSize = 11.5.sp, lineHeight = 16.sp,
                maxLines = if (showOutput) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis,
                color = if (step.status == "failed") status.red else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 36.dp, top = 4.dp).fillMaxWidth().clip(RoundedCornerShape(10.dp))
                    .background(status.code).clickable { showOutput = !showOutput }.padding(horizontal = 10.dp, vertical = 7.dp),
            )
        }
    }
}

@Composable
private fun DiffLines(lines: List<DiffLine>, modifier: Modifier = Modifier, numbers: Boolean) {
    val status = LocalStatus.current
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(status.code)
            .horizontalScroll(rememberScrollState()).padding(vertical = 6.dp),
    ) {
        for (line in lines) {
            val (fg, bg) = when (line.kind) {
                "added" -> status.added to status.addedBackground
                "removed" -> status.removed to status.removedBackground
                else -> MaterialTheme.colorScheme.onSurfaceVariant to androidx.compose.ui.graphics.Color.Transparent
            }
            Row(Modifier.background(bg).padding(horizontal = 10.dp)) {
                if (numbers) {
                    Text(
                        if (line.number > 0) line.number.toString() else "", fontFamily = FontFamily.Monospace, fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.outline, modifier = Modifier.width(34.dp),
                    )
                }
                Text(
                    (if (line.kind == "added") "+ " else if (line.kind == "removed") "− " else "  ") + line.text,
                    fontFamily = FontFamily.Monospace, fontSize = 11.5.sp, lineHeight = 17.sp, color = fg, softWrap = false,
                )
            }
        }
    }
}

// MARK: changes

@Composable
private fun Changes(changes: List<FileChange>) {
    if (changes.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.no_changes), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(), contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(changes, key = { it.path }) { change -> FileCard(change) }
    }
}

@Composable
private fun FileCard(change: FileChange) {
    var open by rememberSaveable(change.path) { mutableStateOf(false) }
    val turn by animateFloatAsState(if (open) 180f else 0f, label = "chevron")
    Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable { open = !open }.padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(change.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(change.path, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                ChangeCount(change.added, change.removed)
                Icon(Icons.Filled.ExpandMore, null, Modifier.padding(start = 6.dp).rotate(turn), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            AnimatedVisibility(open) {
                Column(Modifier.padding(start = 8.dp, end = 8.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    change.hunks.forEach { hunk ->
                        hunk.firstOrNull()?.let {
                            Text(
                                stringResource(R.string.line_number, it.number), style = MaterialTheme.typography.labelSmall,
                                color = LocalStatus.current.blue, modifier = Modifier.padding(start = 6.dp),
                            )
                        }
                        DiffLines(hunk, numbers = true)
                    }
                }
            }
        }
    }
}

// MARK: composer

@Composable
private fun Composer(sessionId: String) {
    var text by rememberSaveable(sessionId) { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Surface(color = MaterialTheme.colorScheme.surface, tonalElevation = 2.dp) {
        Row(
            Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            OutlinedTextField(
                value = text, onValueChange = { text = it },
                placeholder = { Text(stringResource(R.string.message_hint)) },
                modifier = Modifier.weight(1f), maxLines = 5, shape = RoundedCornerShape(24.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    unfocusedBorderColor = androidx.compose.ui.graphics.Color.Transparent,
                ),
            )
            Spacer(Modifier.width(8.dp))
            FilledIconButton(
                onClick = {
                    val prompt = text.trim()
                    sending = true
                    scope.launch {
                        if (AppModel.send(sessionId, prompt)) text = ""
                        sending = false
                    }
                },
                enabled = text.isNotBlank() && !sending,
                modifier = Modifier.padding(bottom = 4.dp).size(48.dp),
            ) {
                if (sending) Spinner(MaterialTheme.colorScheme.onPrimary, size = 18.dp)
                else Icon(Icons.AutoMirrored.Filled.Send, stringResource(R.string.send))
            }
        }
    }
}
