package io.github.eocnd36.kongi.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.eocnd36.kongi.Limit
import io.github.eocnd36.kongi.MacState
import io.github.eocnd36.kongi.R
import io.github.eocnd36.kongi.Request
import io.github.eocnd36.kongi.SessionSummary
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(snackbar: SnackbarHostState) {
    val state = AppModel.state
    val scroll = TopAppBarDefaults.pinnedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                scrollBehavior = scroll,
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Kongi(mood(state), size = 26.dp, growth = growth(state))
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Text("Kongi", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                            ConnectionLine(state)
                        }
                    }
                },
                actions = {
                    IconButton(onClick = { AppModel.screen = Screen.Settings }) {
                        Icon(Icons.Outlined.Settings, stringResource(R.string.settings))
                    }
                },
            )
        },
    ) { padding ->
        // 사용량·알림 카드가 늦게 와서 위에 끼어들어도, 맨 위를 보고 있었다면 맨 위에 머뭅니다.
        val list = rememberLazyListState()
        var atTop by remember { mutableStateOf(true) }
        LaunchedEffect(list) {
            snapshotFlow { (list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset == 0) to list.isScrollInProgress }
                .collect { (top, scrolling) -> if (scrolling || top) atTop = top }
        }
        val topKeys = listOf(!AppModel.live, state?.outage != null, state?.requests?.size ?: 0, state?.limits?.isNotEmpty() == true)
        LaunchedEffect(topKeys) { if (atTop) list.scrollToItem(0) }
        LazyColumn(
            Modifier.fillMaxSize(),
            state = list,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (!AppModel.live) {
                item(key = "offline") {
                    Banner(
                        icon = { if (state == null) Spinner(MaterialTheme.colorScheme.onSurfaceVariant, size = 18.dp) else Icon(Icons.Outlined.WifiOff, null) },
                        text = stringResource(if (state == null) R.string.connecting else R.string.offline),
                        modifier = Modifier.animateItem(),
                    )
                }
            }
            state?.outage?.let { outage ->
                item(key = "outage") {
                    Banner(
                        icon = { Icon(Icons.Outlined.WarningAmber, null, tint = LocalStatus.current.orange) },
                        title = stringResource(R.string.outage),
                        text = outage.incidents.joinToString(", ").ifEmpty { outage.summary },
                    )
                }
            }
            if (state == null) return@LazyColumn

            if (state.requests.isNotEmpty()) {
                item(key = "requests-title") { SectionTitle(stringResource(R.string.needs_you_title), Modifier.animateItem()) }
                items(state.requests, key = { "r-" + it.id }) { request ->
                    RequestCard(request, Modifier.animateItem())
                }
            }

            if (state.limits.isNotEmpty()) {
                item(key = "usage-title") { SectionTitle(stringResource(R.string.usage)) }
                item(key = "usage") {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        state.limits.chunked(2).forEach { pair ->
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                pair.forEach { UsageCard(it, Modifier.weight(1f)) }
                                if (pair.size == 1) Spacer(Modifier.weight(1f))
                            }
                        }
                    }
                }
            }

            item(key = "sessions-title") { SectionTitle(stringResource(R.string.sessions)) }
            if (state.sessions.isEmpty()) {
                item(key = "no-sessions") {
                    Column(
                        Modifier.fillMaxWidth().padding(vertical = 24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Kongi(Mood.Sleeping, size = 44.dp)
                        Spacer(Modifier.size(8.dp))
                        Text(
                            stringResource(R.string.no_sessions), style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 24.dp),
                        )
                    }
                }
            }
            items(state.sessions, key = { "s-" + it.id }) { session ->
                SessionRow(session, Modifier.animateItem()) { AppModel.openSession(session.id) }
            }
        }
    }
}

/** 콩이 기분: 확인할 게 있으면 놀라고, 일하는 세션이 있으면 그 세션이 하는 일에 맞춥니다. */
private fun mood(state: MacState?): Mood {
    if (state == null) return Mood.Sleeping
    if (state.requests.isNotEmpty()) return Mood.Alert
    val moods = state.sessions.filter { !it.ended }.map { Mood.named(it.mood) }
    return moods.firstOrNull { it.busy } ?: moods.firstOrNull { it == Mood.Sad || it == Mood.Happy }
        ?: if (moods.isEmpty()) Mood.Sleeping else Mood.Idle
}

/** 5시간 사용량만큼 콩이가 자랍니다. */
fun growth(state: MacState?): Float = ((state?.limits?.firstOrNull()?.percent ?: 30.0) / 100).toFloat().coerceIn(0f, 1f)

@Composable
private fun ConnectionLine(state: MacState?) {
    val live = AppModel.live
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(if (live) LocalStatus.current.green else MaterialTheme.colorScheme.outline))
        Spacer(Modifier.width(6.dp))
        Text(
            when {
                state != null -> state.mac + if (state.plan.isNotEmpty()) " · ${state.plan}" else ""
                else -> AppModel.pairing?.name?.ifEmpty { null } ?: "Mac"
            },
            style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(start = 4.dp, top = 10.dp, bottom = 2.dp),
    )
}

@Composable
private fun Banner(icon: @Composable () -> Unit, text: String, modifier: Modifier = Modifier, title: String? = null) {
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) { icon() }
            Spacer(Modifier.width(12.dp))
            Column {
                title?.let { Text(it, style = MaterialTheme.typography.titleSmall) }
                Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun UsageCard(limit: Limit, modifier: Modifier = Modifier) {
    val status = LocalStatus.current
    val color = when (limit.severity) {
        "critical" -> status.red
        "warning" -> status.orange
        else -> MaterialTheme.colorScheme.primary
    }
    val progress by animateFloatAsState((limit.percent / 100).toFloat().coerceIn(0f, 1f), label = "usage")
    Card(modifier, shape = RoundedCornerShape(18.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(14.dp)) {
            Text(limit.title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${limit.percent.roundToInt()}%", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = color)
            LinearProgressIndicator(
                progress = { progress }, color = color, trackColor = color.copy(alpha = 0.15f), strokeCap = StrokeCap.Round,
                gapSize = 0.dp, drawStopIndicator = {}, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            )
            Text(limit.reset, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
        }
    }
}

@Composable
private fun SessionRow(session: SessionSummary, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val status = LocalStatus.current
    val color = when {
        session.attention -> status.yellow
        session.ended -> MaterialTheme.colorScheme.outline
        session.busy -> status.orange
        else -> status.blue
    }
    Surface(
        onClick = onClick, modifier = modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 12.dp).heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
            PulsingDot(color, size = 9.dp, pulsing = session.busy || session.attention)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f).animateContentSize()) {
                Text(session.project, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                // 일하는 중이면 단계가 티커로 굴러 올라갑니다.
                if (session.busy) {
                    SproutSteps(session, style = MaterialTheme.typography.bodyMedium)
                } else {
                    Text(session.state, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (session.added > 0 || session.removed > 0) {
                Spacer(Modifier.width(8.dp))
                ChangeCount(session.added, session.removed)
            }
        }
    }
}

@Composable
fun ChangeCount(added: Int, removed: Int) {
    val status = LocalStatus.current
    Row {
        Text("+$added", style = MaterialTheme.typography.labelLarge, fontFamily = FontFamily.Monospace, color = status.added)
        Spacer(Modifier.width(4.dp))
        Text("−$removed", style = MaterialTheme.typography.labelLarge, fontFamily = FontFamily.Monospace, color = status.removed)
    }
}

// MARK: requests

@Composable
private fun RequestCard(request: Request, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    var busy by remember(request.id) { mutableStateOf(false) }
    fun act(action: String, answers: Map<String, String>? = null) {
        busy = true
        scope.launch { if (!AppModel.answer(request.id, action, answers)) busy = false }
    }
    val yellow = LocalStatus.current.yellow
    Card(
        modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        border = androidx.compose.foundation.BorderStroke(1.dp, yellow.copy(alpha = 0.45f)),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(request.project, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (request.isPermission) {
                Text(request.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 2.dp, bottom = 10.dp))
                if (request.detail.isNotEmpty()) {
                    Box(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) { CodeBlock("", request.detail) }
                }
                if (request.rules.isNotEmpty()) {
                    Text(
                        stringResource(R.string.always_rules) + "\n" + request.rules.joinToString("\n"),
                        style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 10.dp),
                    )
                }
                Row(Modifier.fillMaxWidth().padding(top = 14.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { act("deny") }, enabled = !busy, colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text(stringResource(R.string.deny))
                    }
                    Spacer(Modifier.weight(1f))
                    if (request.rules.isNotEmpty()) {
                        TextButton(onClick = { act("always") }, enabled = !busy) { Text(stringResource(R.string.always)) }
                    }
                    Button(onClick = { act("allow") }, enabled = !busy) { Text(stringResource(R.string.allow)) }
                }
                TextButton(onClick = { act("terminal") }, enabled = !busy, contentPadding = PaddingValues(horizontal = 4.dp)) {
                    Text(stringResource(R.string.on_mac), style = MaterialTheme.typography.labelMedium)
                }
            } else {
                QuestionForm(request, busy, ::act)
            }
        }
    }
}

@Composable
private fun QuestionForm(request: Request, busy: Boolean, act: (String, Map<String, String>?) -> Unit) {
    // 질문마다 고른 답과 직접 쓴 답
    val chosen = remember(request.id) { request.questions.map { mutableStateListOf<String>() } }
    val typed = remember(request.id) { request.questions.map { mutableStateOf("") } }
    request.questions.forEachIndexed { index, question ->
        Column(Modifier.padding(top = 10.dp)) {
            if (question.header.isNotEmpty()) {
                Text(
                    question.header, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = Color.Black,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(LocalStatus.current.yellow).padding(horizontal = 8.dp, vertical = 2.dp),
                )
            }
            Text(question.question, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(vertical = 6.dp))
            question.options.forEach { option ->
                val selected = option.label in chosen[index]
                val toggle = {
                    if (question.multiSelect) {
                        if (selected) chosen[index].remove(option.label) else chosen[index].add(option.label)
                    } else {
                        chosen[index].clear()
                        chosen[index].add(option.label)
                    }
                }
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                        .then(
                            if (question.multiSelect) Modifier.toggleable(selected, role = Role.Checkbox) { toggle() }
                            else Modifier.selectable(selected, role = Role.RadioButton) { toggle() },
                        )
                        .padding(vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (question.multiSelect) Checkbox(selected, null, Modifier.padding(12.dp)) else RadioButton(selected, null, Modifier.padding(12.dp))
                    Column(Modifier.weight(1f).padding(end = 8.dp)) {
                        Text(option.label, style = MaterialTheme.typography.bodyLarge)
                        if (option.description.isNotEmpty()) {
                            Text(option.description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            OutlinedTextField(
                value = typed[index].value, onValueChange = { typed[index].value = it },
                placeholder = { Text(stringResource(R.string.other_answer)) },
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp), shape = RoundedCornerShape(14.dp),
                keyboardOptions = KeyboardOptions.Default,
            )
        }
    }
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { act("terminal", null) }, enabled = !busy) { Text(stringResource(R.string.on_mac)) }
        Spacer(Modifier.weight(1f))
        Button(
            onClick = {
                val answers = request.questions.mapIndexedNotNull { index, question ->
                    val labels = chosen[index].toList() + listOfNotNull(typed[index].value.trim().ifEmpty { null })
                    if (labels.isEmpty()) null else question.question to labels.joinToString(", ")
                }.toMap()
                act("answer", answers)
            },
            enabled = !busy,
        ) { Text(stringResource(R.string.send_answer)) }
    }
}
