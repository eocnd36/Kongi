package io.github.eocnd36.kongi.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import io.github.eocnd36.kongi.ActionInfo
import io.github.eocnd36.kongi.ActionResult
import io.github.eocnd36.kongi.R
import kotlinx.coroutines.launch

/** Mac에 켜 둔 확장의 일을 휴대폰에서: 고르고, 입력하고, 질문에 답하고, 결과를 복사하거나 대화에 보냅니다. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExtensionsScreen(snackbar: SnackbarHostState) {
    var actions by remember { mutableStateOf<List<ActionInfo>?>(null) }
    var selected by remember { mutableStateOf<ActionInfo?>(null) }
    LaunchedEffect(Unit) { actions = AppModel.actions() }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = { if (selected != null) selected = null else AppModel.back() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back))
                    }
                },
                title = { Text(selected?.title ?: stringResource(R.string.extensions)) },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            val list = actions
            when {
                list == null -> LinearProgressIndicator(Modifier.fillMaxWidth())
                selected != null -> ActionPanel(selected!!)
                list.isEmpty() -> Text(stringResource(R.string.no_extensions), Modifier.padding(20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                else -> Column(Modifier.verticalScroll(rememberScrollState())) {
                    list.forEach { action ->
                        ListItem(
                            headlineContent = { Text(action.title) },
                            supportingContent = { Text(action.extension) },
                            leadingContent = { Icon(Icons.Outlined.Extension, null) },
                            modifier = Modifier.clickable { selected = action }.padding(horizontal = 4.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionPanel(action: ActionInfo) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var input by remember(action.id) { mutableStateOf("") }
    var choice by remember(action.id) { mutableStateOf(action.choices.firstOrNull()?.first) }
    // 프로젝트: 진행 중인 대화부터
    val sessions = AppModel.state?.sessions.orEmpty().filter { !it.ended }
    var sessionId by remember(action.id) { mutableStateOf(sessions.firstOrNull { it.busy }?.id ?: sessions.firstOrNull()?.id) }
    var running by remember { mutableStateOf(false) }
    var result by remember(action.id) { mutableStateOf<ActionResult?>(null) }
    val answers = remember(action.id) { mutableStateListOf<String>() }
    var answered by remember(action.id) { mutableStateOf(listOf<Pair<String, String>>()) }

    fun run(skip: Boolean = false, fresh: Boolean = false) {
        if (fresh) answered = emptyList()
        running = true
        scope.launch {
            val output = AppModel.runAction(action.id, input, choice, if (action.wantsProject) sessionId else null, answered, skip)
            running = false
            result = output
            answers.clear()
            output?.questions?.forEach { _ -> answers.add("") }
        }
    }

    // 입력이 필요 없는 일(상태 보기)은 열자마자 실행
    LaunchedEffect(action.id) { if (!action.takesInput) run(fresh = true) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (action.choices.isNotEmpty()) {
            if (action.choiceTitle.isNotEmpty()) Text(action.choiceTitle, style = MaterialTheme.typography.labelLarge)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                action.choices.forEach { (id, title) ->
                    FilterChip(selected = choice == id, onClick = {
                        choice = id
                        // 입력이 필요 없는 일은 고르면 바로 실행 (예: 저장공간 → 정리하기)
                        if (!action.takesInput && !running) run(fresh = true)
                    }, label = { Text(title) })
                }
            }
        }
        if (action.wantsProject) {
            var open by remember { mutableStateOf(false) }
            Box {
                OutlinedButton(onClick = { open = true }) {
                    Text(sessions.firstOrNull { it.id == sessionId }?.project ?: stringResource(R.string.no_project))
                }
                DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.no_project)) }, onClick = { sessionId = null; open = false })
                    sessions.forEach { session ->
                        DropdownMenuItem(text = { Text(session.project) }, onClick = { sessionId = session.id; open = false })
                    }
                }
            }
        }
        if (action.takesInput) {
            OutlinedTextField(
                value = input, onValueChange = { input = it }, modifier = Modifier.fillMaxWidth(),
                placeholder = { Text(action.placeholder) }, minLines = 3, maxLines = 8,
            )
        }
        val current = result
        if (current?.kind == "questions") {
            Text(stringResource(R.string.questions_title), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            current.questions.forEachIndexed { index, item ->
                val question = item.question
                val options = item.options
                Text(question, style = MaterialTheme.typography.bodyLarge)
                if (item.multiSelect) {
                    // 여러 개 고르기: 고른 보기를 줄바꿈으로 이어 답으로 보냄
                    options.forEach { option ->
                        val picked = answers.getOrNull(index)?.split("\n")?.contains(option) == true
                        Row(Modifier.fillMaxWidth().clickable {
                            if (index < answers.size) {
                                val set = answers[index].split("\n").filter { it.isNotEmpty() }.toMutableList()
                                if (picked) set.remove(option) else set.add(option)
                                answers[index] = set.joinToString("\n")
                            }
                        }, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                            androidx.compose.material3.Checkbox(checked = picked, onCheckedChange = null)
                            Text(option)
                        }
                    }
                } else if (options.isNotEmpty()) {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        options.forEach { option ->
                            FilterChip(selected = answers.getOrNull(index) == option, onClick = { if (index < answers.size) answers[index] = option }, label = { Text(option) })
                        }
                    }
                }
                if (index < answers.size && !item.multiSelect) {
                    OutlinedTextField(value = answers[index], onValueChange = { answers[index] = it }, modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text(stringResource(R.string.your_answer)) }, maxLines = 3)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    answered = answered + current.questions.mapIndexedNotNull { index, item ->
                        answers.getOrNull(index)?.trim()?.takeIf { it.isNotEmpty() }?.let { item.question to it }
                    }
                    run()
                }, enabled = !running) { Text(current.questions.firstOrNull()?.confirm?.ifEmpty { null } ?: stringResource(R.string.continue_answers)) }
                val confirmType = current.questions.firstOrNull()?.confirm?.isNotEmpty() == true
                // 확인형(삭제 등)의 취소는 아무것도 하지 않고 닫음
                TextButton(onClick = { if (confirmType) result = null else run(skip = true) }, enabled = !running) {
                    Text(stringResource(if (confirmType) R.string.cancel else R.string.skip))
                }
            }
        } else {
            Button(onClick = { run(fresh = true) }, enabled = !running && (!action.takesInput || input.isNotBlank())) {
                Text(stringResource(if (action.takesInput) R.string.run else R.string.refresh))
            }
        }
        if (running) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (current != null && current.kind != "questions") {
            Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                SelectionContainer {
                    Text(
                        current.text, Modifier.fillMaxWidth().padding(12.dp),
                        fontFamily = if (action.monospaced) FontFamily.Monospace else null,
                        color = if (current.kind == "error") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (current.note.isNotEmpty()) Text(current.note, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (current.kind == "text") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Kongi", current.text))
                    }) { Text(stringResource(R.string.copy)) }
                    if (sessions.isNotEmpty()) {
                        var open by remember { mutableStateOf(false) }
                        Box {
                            OutlinedButton(onClick = { open = true }) { Text(stringResource(R.string.send_to_conversation)) }
                            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                                sessions.sortedByDescending { it.id == sessionId }.forEach { session ->
                                    DropdownMenuItem(text = { Text(session.project) }, onClick = {
                                        open = false
                                        scope.launch { AppModel.send(session.id, current.text) }
                                    })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
