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
        )
    }
}

@Immutable
data class Step(val id: String, val title: String, val status: String)

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

private fun JSONArray?.objects(): List<JSONObject> =
    if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

private fun JSONArray?.arrays(): List<JSONArray> =
    if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONArray(it) }

private fun JSONArray?.strings(): List<String> =
    if (this == null) emptyList() else (0 until length()).map { optString(it) }
