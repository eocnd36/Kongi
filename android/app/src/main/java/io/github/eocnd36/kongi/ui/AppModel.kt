package io.github.eocnd36.kongi.ui

import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.eocnd36.kongi.MacLink
import io.github.eocnd36.kongi.MacState
import io.github.eocnd36.kongi.Pairing
import io.github.eocnd36.kongi.R
import io.github.eocnd36.kongi.SessionDetail
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import kotlin.coroutines.resume

/** 지금 보고 있는 화면 */
sealed interface Screen {
    data object Home : Screen
    data class Session(val id: String) : Screen
    data object Settings : Screen
}

/** 화면 아래에 잠깐 띄우는 말 (문자열 리소스 또는 Mac이 보낸 글) */
data class Notice(@StringRes val res: Int? = null, val text: String? = null)

/** 요청 결과: 성공이면 응답 본문, 실패면 보여 줄 말 */
sealed interface Reply {
    data class Ok(val body: JSONObject) : Reply
    data class Failed(val notice: Notice) : Reply
}

/**
 * 화면이 보는 상태. MacLink(네트워크)에서 오는 소식을 Compose 상태로 바꿔 둡니다.
 * 모든 값은 메인 스레드에서만 바꿉니다 (MacLink가 메인 스레드로 넘겨 줌).
 */
object AppModel {
    var pairing by mutableStateOf<Pairing?>(null)
        private set
    var background by mutableStateOf(false)
    var live by mutableStateOf(false)
        private set
    var state by mutableStateOf<MacState?>(null)
        private set
    /** Mac에서 연결을 새로 만들어 QR을 다시 찍어야 함 */
    var needsRepair by mutableStateOf(false)
        private set
    var screen by mutableStateOf<Screen>(Screen.Home)
    var detail by mutableStateOf<SessionDetail?>(null)
        private set
    /** 앱 업데이트 확인 상태 (Updates) */
    var updateStatus by mutableStateOf(io.github.eocnd36.kongi.UpdateStatus.Idle)
    var updateVersion by mutableStateOf<String?>(null)
    var updateChanges by mutableStateOf<List<String>>(emptyList())
    /** 업데이트 뒤 처음 열었을 때 보여 줄 (버전, 바뀐 것) */
    var installedNotes by mutableStateOf<Pair<String, List<String>>?>(null)
    /** 앱을 열면 "새 버전이 있어요" 창을 띄움 */
    var updatePrompt by mutableStateOf(false)

    /** 링크·카메라로 들어와 확인을 기다리는 연결 */
    var pendingPairing by mutableStateOf<Pairing?>(null)

    private val noticeChannel = Channel<Notice>(Channel.BUFFERED)
    val notices = noticeChannel.receiveAsFlow()

    /** 데모 영상용 빌드: Mac과 연결하지 않고 정해진 장면을 재생합니다. */
    var demo = false
        private set

    private var detailVersion: String? = null
    private var loadingDetail = false
    private var detailDirty = false

    fun notice(notice: Notice) {
        noticeChannel.trySend(notice)
    }

    fun refreshPairing(background: Boolean) {
        pairing = MacLink.pairing
        this.background = background
        if (pairing == null) {
            state = null
            detail = null
            screen = Screen.Home
        } else {
            needsRepair = false
            MacLink.lastState?.let(::onState)
        }
        live = MacLink.live
    }

    fun onConnection(value: Boolean) {
        live = value
    }

    fun onState(json: String) {
        val data = runCatching { JSONObject(json) }.getOrNull() ?: return
        if (data.optBoolean("unpaired")) {
            needsRepair = true
            return
        }
        val next = MacState.parse(data)
        state = next
        val open = screen as? Screen.Session ?: return
        // 열어 둔 세션이 바뀌었으면 자세한 내용을 다시 받습니다.
        val version = next.sessions.firstOrNull { it.id == open.id }?.updated
        if (version != null && version != detailVersion) loadDetail(open.id)
    }

    // MARK: navigation

    fun openSession(id: String) {
        if (detail?.id != id) detail = null
        detailVersion = null
        screen = Screen.Session(id)
        loadDetail(id)
    }

    /** 뒤로 가기: 처리했으면 true */
    fun back(): Boolean {
        if (screen == Screen.Home) return false
        screen = Screen.Home
        return true
    }

    private fun loadDetail(id: String) {
        if (demo) return
        if (loadingDetail) {
            detailDirty = true
            return
        }
        loadingDetail = true
        detailVersion = state?.sessions?.firstOrNull { it.id == id }?.updated
        MacLink.rpc("GET", "/api/sessions/${java.net.URLEncoder.encode(id, "UTF-8")}", null) { status, json ->
            loadingDetail = false
            if (status in 200..299 && (screen as? Screen.Session)?.id == id) {
                runCatching { SessionDetail.parse(JSONObject(json)) }.getOrNull()?.let { detail = it }
            }
            if (detailDirty) {
                detailDirty = false
                (screen as? Screen.Session)?.let { loadDetail(it.id) }
            }
        }
    }

    /** 데모 장면 하나: 가짜 상태(와 세션 내용)로 바꿉니다. */
    fun showDemo(state: MacState, detail: SessionDetail? = null) {
        demo = true
        pairing = Pairing("demo", "Mac mini", listOf("192.168.0.2"), 47815, ByteArray(32))
        needsRepair = false
        live = true
        this.state = state
        if (detail != null) this.detail = detail
    }

    // MARK: requests

    suspend fun call(method: String, path: String, body: JSONObject? = null): Reply = suspendCancellableCoroutine { continuation ->
        MacLink.rpc(method, path, body) { status, json ->
            val reply = runCatching { JSONObject(json) }.getOrDefault(JSONObject())
            val result = when {
                status == 401 -> {
                    needsRepair = true
                    Reply.Failed(Notice(R.string.repair))
                }
                status == 0 -> Reply.Failed(Notice(R.string.offline))
                status == 409 && path.startsWith("/api/requests") -> Reply.Failed(Notice(R.string.already_answered))
                status !in 200..299 -> {
                    val error = reply.optString("error")
                    Reply.Failed(if (error.isEmpty()) Notice(R.string.offline) else Notice(text = error))
                }
                else -> Reply.Ok(reply)
            }
            if (continuation.isActive) continuation.resume(result)
        }
    }

    suspend fun answer(requestId: String, action: String, answers: Map<String, String>? = null): Boolean {
        val body = JSONObject().put("action", action)
        if (answers != null) body.put("answers", JSONObject(answers))
        return when (val reply = call("POST", "/api/requests/$requestId", body)) {
            is Reply.Ok -> true
            is Reply.Failed -> { notice(reply.notice); false }
        }
    }

    suspend fun send(sessionId: String, prompt: String): Boolean {
        val reply = call("POST", "/api/prompt", JSONObject().put("sessionId", sessionId).put("prompt", prompt))
        return when (reply) {
            is Reply.Ok -> {
                notice(Notice(when (reply.body.optString("via")) {
                    "queued" -> R.string.sent_queued
                    "resume" -> R.string.sent_resumed
                    else -> R.string.sent_conversation
                }))
                true
            }
            is Reply.Failed -> { notice(reply.notice); false }
        }
    }

    suspend fun continueAfterReset(sessionId: String) {
        when (val reply = call("POST", "/api/continue", JSONObject().put("sessionId", sessionId))) {
            is Reply.Ok -> notice(Notice(R.string.continue_scheduled))
            is Reply.Failed -> notice(reply.notice)
        }
    }

    suspend fun testNotification() {
        when (val reply = call("POST", "/api/test", JSONObject())) {
            is Reply.Ok -> notice(Notice(R.string.test_sent))
            is Reply.Failed -> notice(reply.notice)
        }
    }
}
