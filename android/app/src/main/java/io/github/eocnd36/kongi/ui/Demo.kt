package io.github.eocnd36.kongi.ui

import io.github.eocnd36.kongi.Limit
import io.github.eocnd36.kongi.MacState
import io.github.eocnd36.kongi.Request
import io.github.eocnd36.kongi.SessionDetail
import io.github.eocnd36.kongi.SessionSummary
import io.github.eocnd36.kongi.Step
import io.github.eocnd36.kongi.TimelineEntry
import kotlinx.coroutines.delay
import java.time.Instant

/**
 * 데모 영상용 장면 (demo 빌드에서만 쓰임). 가짜 프로젝트와 가짜 Claude Code 세션을 정해진 순서대로 보여 줍니다.
 * 실제 Mac이나 파일과는 아무 관계가 없습니다.
 */
object Demo {
    private val limits = listOf(
        Limit("session", "Current session", 42.0, "Resets in 2 hr 15 min", "normal"),
        Limit("weekly", "Weekly · all models", 63.0, "Resets Thu 11:00 PM", "normal"),
    )
    private val others = listOf(
        session("demo-2", "website", "Waiting for you", busy = false, mood = "idle", added = 24, removed = 3),
        session("demo-3", "api-server", "Ended", busy = false, ended = true, mood = "sleeping"),
    )

    private fun session(
        id: String, project: String, state: String, busy: Boolean, mood: String,
        steps: List<Step> = emptyList(), thinking: Boolean = false, done: Boolean = false, ended: Boolean = false,
        attention: Boolean = false, added: Int = 0, removed: Int = 0,
    ) = SessionSummary(
        id = id, project = project, state = state, attention = attention, busy = busy, ended = ended,
        updated = Instant.now().toString(), added = added, removed = removed, continueScheduled = false,
        step = steps.lastOrNull { it.status == "running" }?.title.orEmpty(), stepKind = "",
        thinking = thinking, done = done, mood = mood, steps = steps,
    )

    private fun state(main: SessionSummary, requests: List<Request> = emptyList()) =
        MacState("Mac mini", "Max", limits, listOf(main) + others, requests, null)

    suspend fun play() {
        val read = Step("s1", "ForecastView.swift", "running")
        val test = Step("s2", "Run the tests", "running")
        val edit = Step("s3", "ForecastView.swift", "running")
        val deploy = Step("s4", "Deploy the preview", "running")
        fun done(step: Step) = step.copy(status = "succeeded")
        fun main(state: String, mood: String, steps: List<Step>, thinking: Boolean = false, done: Boolean = false, attention: Boolean = false) =
            session("demo-1", "weather-app", state, busy = !done && !attention, mood = mood, steps = steps, thinking = thinking,
                done = done, attention = attention, added = if (steps.size >= 3) 6 else 0, removed = if (steps.size >= 3) 1 else 0)

        AppModel.screen = Screen.Home
        AppModel.showDemo(state(main("Thinking", "thinking", emptyList(), thinking = true)))
        delay(1800)
        AppModel.showDemo(state(main("Reading ForecastView.swift", "reading", listOf(read))))
        delay(2200)
        AppModel.showDemo(state(main("Running the tests", "running", listOf(done(read), test))))
        delay(2000)
        AppModel.showDemo(state(main("Thinking", "thinking", listOf(done(read), done(test)), thinking = true)))
        delay(1500)
        AppModel.showDemo(state(main("Editing ForecastView.swift", "editing", listOf(done(read), done(test), edit))))
        delay(2600)
        val request = Request(
            id = "r1", sessionId = "demo-1", project = "weather-app", kind = "permission", tool = "Bash",
            title = "Allow Bash?", detail = "npm run deploy -- --preview", rules = emptyList(), questions = emptyList(),
        )
        AppModel.showDemo(state(main("Needs approval", "alert", listOf(done(read), done(test), done(edit)), attention = true), listOf(request)))
        delay(3200)
        AppModel.showDemo(state(main("Running Deploy the preview", "running", listOf(done(test), done(edit), deploy))))
        delay(1800)

        val now = Instant.now()
        val finished = main("Done", "happy", listOf(done(test), done(edit), done(deploy)), done = true)
        val detail = SessionDetail(
            id = "demo-1", project = "weather-app", state = "Done", busy = false, thinking = false,
            timeline = listOf(
                TimelineEntry.Message("m1", now.minusSeconds(40), "user", "Show the high and low next to each day", false),
                TimelineEntry.Step("t1", now.minusSeconds(36), "read", "Reading ForecastView.swift", "succeeded", "", emptyList()),
                TimelineEntry.Step("t2", now.minusSeconds(30), "run", "Run the tests", "succeeded", "Test run with 48 tests passed.", emptyList()),
                TimelineEntry.Step(
                    "t3", now.minusSeconds(20), "edit", "Editing ForecastView.swift", "succeeded", "",
                    listOf(
                        io.github.eocnd36.kongi.DiffLine("removed", "Text(\"\\(day.temperature)°\")", 0),
                        io.github.eocnd36.kongi.DiffLine("added", "Text(\"\\(day.high)°\").bold()", 0),
                        io.github.eocnd36.kongi.DiffLine("added", "Text(\"\\(day.low)°\").foregroundStyle(.secondary)", 0),
                    ),
                ),
                TimelineEntry.Step("t4", now.minusSeconds(8), "run", "Deploy the preview", "succeeded", "✓ Preview ready", emptyList()),
                TimelineEntry.Message(
                    "m2", now, "assistant",
                    "Done! Each day now shows its **high** and **low**.\n\n| Day | High | Low |\n|:--|--:|--:|\n| Mon | 24° | 15° |\n| Tue | 22° | 14° |\n\nThe tests pass and the preview is live.",
                    false,
                ),
            ),
            changes = emptyList(),
        )
        AppModel.showDemo(state(finished), detail)
        delay(1200)
        AppModel.screen = Screen.Session("demo-1")
        delay(6000)
        AppModel.back()
        delay(2500)
    }
}
