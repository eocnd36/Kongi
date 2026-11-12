package io.github.eocnd36.kongi

import android.app.Notification
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.widget.Toast
import org.json.JSONObject

/**
 * 앱을 닫아도 Mac과의 연결을 유지해 승인 요청과 알림을 받는 백그라운드 연결 (사용자가 앱에서 켰을 때만).
 * 표시줄에 작은 상시 알림이 남습니다.
 */
class LinkService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        MacLink.init(this)
        val notification = status(MacLink.live)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(Notices.LINK_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(Notices.LINK_ID, notification)
        }
        MacLink.onLiveChange = { live ->
            getSystemService(android.app.NotificationManager::class.java).notify(Notices.LINK_ID, status(live))
        }
        MacLink.hold(TAG)
        // 백그라운드 연결 중에도 가끔 업데이트를 확인합니다 (6시간에 한 번만 실제로 확인).
        handler.post(updateCheck)
    }

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val updateCheck = object : Runnable {
        override fun run() {
            Updates.check(this@LinkService)
            handler.postDelayed(this, 3 * 3600_000L)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onDestroy() {
        handler.removeCallbacks(updateCheck)
        MacLink.onLiveChange = null
        MacLink.release(TAG)
        super.onDestroy()
    }

    private fun status(live: Boolean): Notification {
        val name = MacLink.pairing?.name?.takeIf { it.isNotEmpty() } ?: "Mac"
        return Notification.Builder(this, Notices.CHANNEL_LINK)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(if (live) R.string.link_title else R.string.link_waiting, name))
            .setContentIntent(Notices.openApp(this))
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "service"
        private const val PREF = "background"

        fun enabled(context: Context) =
            context.getSharedPreferences("link", Context.MODE_PRIVATE).getBoolean(PREF, false)

        fun setEnabled(context: Context, on: Boolean) {
            context.getSharedPreferences("link", Context.MODE_PRIVATE).edit().putBoolean(PREF, on).apply()
            if (on) start(context) else stop(context)
        }

        /** 화면이 보일 때 부릅니다 (안드로이드는 백그라운드에서 시작하는 걸 막습니다). */
        fun start(context: Context) {
            if (!enabled(context) || MacLink.pairing == null) return
            context.startForegroundService(Intent(context, LinkService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LinkService::class.java))
        }
    }
}

/** 알림의 허용·거부 버튼 */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("request") ?: return
        val action = intent.getStringExtra("action") ?: return
        MacLink.init(context)
        Notices.dismissRequest(context, id)
        val pending = goAsync()
        Thread {
            val (status, _) = MacLink.rpcBlocking("POST", "/api/requests/$id", JSONObject().put("action", action))
            if (status == 0) {
                android.os.Handler(context.mainLooper).post {
                    Toast.makeText(context, R.string.answer_failed, Toast.LENGTH_SHORT).show()
                }
            }
            pending.finish()
        }.start()
    }
}
