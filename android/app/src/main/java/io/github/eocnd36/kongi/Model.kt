package io.github.eocnd36.kongi

import androidx.compose.runtime.Immutable
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** Mac이 보내는 상태 (state 이벤트). 화면이 다시 그릴 때 비교하기 쉽도록 바뀌지 않는 값으로 둡니다. */
@Immutable
data class MacState(
    val mac: String,
    val plan: String,
    val limits: List<Limit>,
    val sessions: List<SessionSummary>,
    val requests: List<Request>,
    val outage: Outage?,
    /** Mac이 이 상태를 만든 시각 (남은 시간을 휴대폰에서 이어서 셀 때 기준) */
    val updated: Instant = Instant.EPOCH,
    /** Mac에 켜 둔 확장의 일 수 (홈의 확장 단추) */
    val actions: Int = 0,
) {
    companion object {
        fun parse(json: JSONObject) = MacState(
            mac = json.optString("mac", "Mac"),
            plan = json.optString("plan"),
            limits = json.optJSONArray("limits").objects().map(Limit::parse),
            sessions = json.optJSONArray("sessions").objects().map(SessionSummary::parse),
            requests = json.optJSONArray("requests").objects().map(Request::parse),
            outage = json.optJSONObject("outage")?.let { o ->
                Outage(o.optString("summary"), o.optJSONArray("incidents").strings())
            },
            updated = instant(json.optString("updated")),
            actions = json.optInt("actions"),
        )
    }
}

@Immutable
data class Outage(val summary: String, val incidents: List<String>)

@Immutable
data class Limit(val kind: String, val title: String, val percent: Double, val reset: String, val severity: String) {
    companion object {
        fun parse(o: JSONObject) = Limit(
            o.optString("kind"), o.optString("title"), o.optDouble("percent", 0.0), o.optString("reset"), o.optString("severity", "normal"),
        )
    }
}

@Immutable
data class SessionSummary(
    val id: String,
    val project: String,
    val state: String,
    val attention: Boolean,
    val busy: Boolean,
    val ended: Boolean,
    val updated: String,
    val added: Int,
    val removed: Int,
    val continueScheduled: Boolean,
    val step: String,
    val stepKind: String,
    val thinking: Boolean,
    val done: Boolean,
    /** 콩이 기분 (Mac의 Kongi.Mood 이름) */
    val mood: String,
    /** 최근 단계 세 개 */
    val steps: List<Step>,
    /** 실시간: 이번 차례를 시작한 시각 (일하는 중이 아니면 null) */
    val turnStarted: Instant? = null,
    /** Mac이 상태를 만들 때의 남은 시간(초). 모르면 음수 */
    val remaining: Double = -1.0,
    /** 지난 어느 기록보다 오래 걸리는 중 */
    val overdue: Boolean = false,
    /** 할 일 진행 "2/5" */
    val todo: String = "",
    /** 대답이 끝난 뒤에도 뒤에서 도는 명령들 */
    val background: List<BackgroundJob> = emptyList(),
) {
    companion object {
        fun parse(o: JSONObject) = SessionSummary(
            id = o.optString("id"),
            project = o.optString("project"),
            state = o.optString("state"),
            attention = o.optBoolean("attention"),
            busy = o.optBoolean("busy"),
            ended = o.optBoolean("ended"),
            updated = o.optString("updated"),
            added = o.optInt("added"),
            removed = o.optInt("removed"),
            continueScheduled = o.optBoolean("continueScheduled"),
            step = o.optString("step"),
            stepKind = o.optString("stepKind"),
            thinking = o.optBoolean("thinking"),
            done = o.optBoolean("done"),
            mood = o.optString("mood"),
            steps = o.optJSONArray("steps").objects().map { Step(it.optString("id"), it.optString("title"), it.optString("status")) },
            turnStarted = o.optString("turnStarted").takeIf { it.isNotEmpty() }?.let(::instant),
            remaining = o.optDouble("remaining", -1.0),
            overdue = o.optBoolean("overdue"),
            todo = o.optString("todo"),
            background = o.optJSONArray("background").objects().map {
                BackgroundJob(it.optString("label"), instant(it.optString("started")), it.optDouble("remaining", -1.0))
            },
        )
    }
}

@Immutable
data class Step(val id: String, val title: String, val status: String)

/** Mac 확장의 일 하나 (글은 Mac 앱 언어) */
@Immutable
data class ActionInfo(
    val id: String,
    val title: String,
    val extension: String,
    val placeholder: String,
    val takesInput: Boolean,
    val monospaced: Boolean,
    val wantsProject: Boolean,
    val choiceTitle: String,
    val choices: List<Pair<String, String>>,
) {
    companion object {
        fun parse(o: JSONObject) = ActionInfo(
            id = o.optString("id"), title = o.optString("title"), extension = o.optString("extension"),
            placeholder = o.optString("placeholder"), takesInput = o.optBoolean("takesInput", true),
            monospaced = o.optBoolean("monospaced"), wantsProject = o.optBoolean("wantsProject"),
            choiceTitle = o.optString("choiceTitle"),
            choices = o.optJSONArray("choices").objects().map { it.optString("id") to it.optString("title") },
        )
    }
}

/** 확장의 일 결과: 글(과 메모), 더 알아야 할 질문, 또는 오류 */
@Immutable
data class ActionResult(val kind: String, val text: String, val note: String, val questions: List<ActionQuestion>) {
    companion object {
        fun parse(o: JSONObject) = ActionResult(
            kind = o.optString("kind"), text = o.optString("text"), note = o.optString("note"),
            questions = o.optJSONArray("questions").objects().map {
                ActionQuestion(it.optString("question"), it.optJSONArray("options").strings(), it.optBoolean("multiSelect"), it.optString("confirm"))
            },
        )
    }
}

/** 확장이 묻는 것: 보기, 여러 개 고르기, 확인 단추 이름(예: 삭제) */
@Immutable
data class ActionQuestion(val question: String, val options: List<String>, val multiSelect: Boolean, val confirm: String)

@Immutable
data class BackgroundJob(val label: String, val started: Instant, val remaining: Double)

@Immutable
data class Request(
    val id: String,
    val sessionId: String,
    val project: String,
    val kind: String,
    val tool: String,
    val title: String,
    val detail: String,
    val rules: List<String>,
    val questions: List<Question>,
) {
    val isPermission get() = kind == "permission"

    companion object {
        fun parse(o: JSONObject) = Request(
            id = o.optString("id"),
            sessionId = o.optString("sessionId"),
            project = o.optString("project"),
            kind = o.optString("kind"),
            tool = o.optString("tool"),
            title = o.optString("title"),
            detail = o.optString("detail"),
            rules = o.optJSONArray("rules").strings(),
            questions = o.optJSONArray("questions").objects().map { q ->
                Question(
                    question = q.optString("question"),
                    header = q.optString("header"),
                    multiSelect = q.optBoolean("multiSelect"),
                    options = q.optJSONArray("options").objects().map { Option(it.optString("label"), it.optString("description")) },
                )
            },
        )
    }
}

@Immutable
data class Question(val question: String, val header: String, val multiSelect: Boolean, val options: List<Option>)

@Immutable
data class Option(val label: String, val description: String)

/** 세션 하나의 자세한 내용 (대화, 단계, 바뀐 파일) */
@Immutable
data class SessionDetail(
    val id: String,
    val project: String,
    val state: String,
    val busy: Boolean,
    val thinking: Boolean,
    val timeline: List<TimelineEntry>,
    val changes: List<FileChange>,
) {
    companion object {
        fun parse(o: JSONObject): SessionDetail {
            val messages = o.optJSONArray("messages").objects().mapIndexed { index, m ->
                TimelineEntry.Message(
                    id = m.optString("id").ifEmpty { "m$index" },
                    time = instant(m.optString("time")),
                    role = m.optString("role"),
                    text = m.optString("text"),
                    queued = m.optBoolean("queued"),
                )
            }
            val steps = o.optJSONArray("activities").objects().mapIndexed { index, a ->
                TimelineEntry.Step(
                    id = a.optString("id").ifEmpty { "a$index" },
                    time = instant(a.optString("time")),
                    kind = a.optString("kind"),
                    label = a.optString("label"),
                    status = a.optString("status"),
                    output = a.optString("output"),
                    preview = a.optJSONArray("preview").objects().map { DiffLine(it.optString("k"), it.optString("t"), 0) },
                )
            }
            return SessionDetail(
                id = o.optString("id"),
                project = o.optString("project"),
                state = o.optString("state"),
                busy = o.optBoolean("busy"),
                thinking = o.optBoolean("thinking"),
                // 오래된 것부터 (대화처럼 아래가 최신)
                timeline = (messages + steps).sortedBy { it.time },
                changes = o.optJSONArray("changes").objects().map { c ->
                    FileChange(
                        name = c.optString("name"),
                        path = c.optString("path"),
                        added = c.optInt("added"),
                        removed = c.optInt("removed"),
                        hunks = c.optJSONArray("hunks").arrays().map { hunk ->
                            hunk.objects().map { DiffLine(it.optString("k"), it.optString("t"), it.optInt("n")) }
                        },
                    )
                },
            )
        }
    }
}

@Immutable
sealed interface TimelineEntry {
    val id: String
    val time: Instant

    @Immutable
    data class Message(override val id: String, override val time: Instant, val role: String, val text: String, val queued: Boolean) : TimelineEntry

    @Immutable
    data class Step(
        override val id: String,
        override val time: Instant,
        val kind: String,
        val label: String,
        val status: String,
        val output: String,
        val preview: List<DiffLine>,
    ) : TimelineEntry
}

@Immutable
data class FileChange(val name: String, val path: String, val added: Int, val removed: Int, val hunks: List<List<DiffLine>>)

@Immutable
data class DiffLine(val kind: String, val text: String, val number: Int)

private fun instant(text: String): Instant = runCatching { Instant.parse(text) }.getOrDefault(Instant.EPOCH)

internal fun JSONArray?.objects(): List<JSONObject> =
    if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

private fun JSONArray?.arrays(): List<JSONArray> =
    if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONArray(it) }

private fun JSONArray?.strings(): List<String> =
    if (this == null) emptyList() else (0 until length()).map { optString(it) }
