package io.github.eocnd36.kongi

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.platform.LocalContext
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import io.github.eocnd36.kongi.ui.AppModel
import io.github.eocnd36.kongi.ui.HomeScreen
import io.github.eocnd36.kongi.ui.KongiTheme
import io.github.eocnd36.kongi.ui.Notice
import io.github.eocnd36.kongi.ui.PairConfirmDialog
import io.github.eocnd36.kongi.ui.PairScreen
import io.github.eocnd36.kongi.ui.Screen
import io.github.eocnd36.kongi.ui.SessionScreen
import io.github.eocnd36.kongi.ui.SettingsScreen

/**
 * 화면은 Jetpack Compose로 그립니다 (ui 패키지). 네트워크는 모두 MacLink가 맡고,
 * 소식은 AppModel(Compose 상태)로 넘겨 화면이 저절로 다시 그려지게 합니다.
 */
class MainActivity : ComponentActivity(), MacLink.Listener {
    private val scanner = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let { pairWith(it, confirm = false) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        MacLink.init(this)
        if (BuildConfig.DEMO) {
            setContent { KongiTheme { App() } }
            return
        }
        AppModel.refreshPairing(LinkService.enabled(this))
        setContent { KongiTheme { App() } }
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        // 업데이트 알림을 눌렀을 때
        if (intent?.getBooleanExtra("update", false) == true) {
            intent.removeExtra("update")
            Updates.installNow(this)
        }
        intent?.getStringExtra("session")?.let { session ->
            if (MacLink.pairing != null) AppModel.openSession(session)
        }
        val data: Uri = intent?.data ?: return
        // 링크는 아무 웹 페이지나 열 수 있으므로, 연결을 바꾸기 전에 꼭 묻습니다.
        if (data.scheme == "kongi") pairWith(data.toString(), confirm = true)
    }

    override fun onStart() {
        super.onStart()
        if (BuildConfig.DEMO) return
        MacLink.listener = this
        MacLink.foreground = true
        MacLink.hold(TAG)
        LinkService.start(this)
        AppModel.onConnection(MacLink.live)
        Updates.check(this)
    }

    override fun onStop() {
        if (BuildConfig.DEMO) return super.onStop()
        MacLink.foreground = false
        if (MacLink.listener === this) MacLink.listener = null
        MacLink.release(TAG)
        super.onStop()
    }

    // MARK: pairing

    /**
     * `confirm`: 카메라 앱·링크로 들어온 코드는 Mac 이름과 주소를 보여 주고 확인을 받습니다.
     * 앱 안에서 직접 찍은 코드도 이미 연결된 Mac을 바꾸는 경우에는 묻습니다.
     */
    private fun pairWith(text: String, confirm: Boolean) {
        val pairing = Pairing.parse(text)
        if (pairing == null) {
            AppModel.notice(Notice(R.string.bad_code))
            return
        }
        val existing = MacLink.pairing
        if (existing != null && existing.key.contentEquals(pairing.key) && existing.id == pairing.id) return
        if (!confirm && existing == null) acceptPairing(pairing) else AppModel.pendingPairing = pairing
    }

    private fun acceptPairing(pairing: Pairing) {
        AppModel.pendingPairing = null
        MacLink.pair(pairing)
        AppModel.refreshPairing(LinkService.enabled(this))
        AppModel.notice(Notice(text = getString(R.string.paired, pairing.name.ifEmpty { "Mac" })))
        askForNotifications()
    }

    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }

    private fun scan() {
        scanner.launch(
            ScanOptions()
                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt(getString(R.string.scan_prompt))
                .setBeepEnabled(false)
                .setOrientationLocked(false),
        )
    }

    private fun setBackground(on: Boolean) {
        if (on) askForNotifications()
        LinkService.setEnabled(this, on)
        AppModel.background = on
    }

    private fun unpair() {
        MacLink.unpair()
        AppModel.refreshPairing(LinkService.enabled(this))
    }

    // MARK: MacLink → screen

    override fun onState(json: String) = AppModel.onState(json)
    override fun onConnection(live: Boolean) = AppModel.onConnection(live)
    override fun onNotice(title: String, body: String) = AppModel.notice(Notice(text = if (body.isEmpty()) title else "$title · $body"))

    // MARK: UI

    @Composable
    private fun App() {
        val snackbar = remember { SnackbarHostState() }
        val context = LocalContext.current
        LaunchedEffect(Unit) {
            AppModel.notices.collect { notice ->
                val text = notice.text ?: notice.res?.let(context::getString) ?: return@collect
                snackbar.currentSnackbarData?.dismiss()
                snackbar.showSnackbar(text)
            }
        }
        BackHandler(enabled = AppModel.screen != Screen.Home) { AppModel.back() }
        if (BuildConfig.DEMO) LaunchedEffect(Unit) { io.github.eocnd36.kongi.ui.Demo.play() }

        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            val paired = AppModel.pairing != null && !AppModel.needsRepair
            val screen = if (paired) AppModel.screen else null
            AnimatedContent(
                targetState = screen,
                transitionSpec = {
                    // 안쪽 화면은 오른쪽에서 밀려 들어오고, 뒤로 가면 오른쪽으로 빠집니다.
                    val forward = targetState != Screen.Home && targetState != null
                    if (forward) {
                        (slideInHorizontally(tween(260)) { it / 4 } + fadeIn(tween(200))) togetherWith fadeOut(tween(120))
                    } else {
                        fadeIn(tween(200)) togetherWith (slideOutHorizontally(tween(240)) { it / 4 } + fadeOut(tween(160)))
                    }
                },
                label = "screen",
            ) { target ->
                when (target) {
                    null -> PairScreen(onScan = ::scan, snackbar = snackbar)
                    Screen.Home -> HomeScreen(snackbar)
                    is Screen.Session -> SessionScreen(target.id, snackbar)
                    Screen.Settings -> SettingsScreen(
                        snackbar = snackbar,
                        version = BuildConfig.VERSION_NAME,
                        onBackground = ::setBackground,
                        onScan = ::scan,
                        onUnpair = ::unpair,
                    )
                }
            }
        }
        AppModel.pendingPairing?.let { pairing ->
            PairConfirmDialog(pairing, onConfirm = { acceptPairing(pairing) }, onDismiss = { AppModel.pendingPairing = null })
        }
    }

    companion object {
        private const val TAG = "screen"
    }
}
