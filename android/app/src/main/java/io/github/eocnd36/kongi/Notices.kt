package io.github.eocnd36.kongi

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONObject

/**
 * 안드로이드 알림. 승인·질문은 Mac 상태의 requests를 보고 직접 띄우고 (허용·거부 버튼 포함),
 * 답이 끝나 목록에서 사라지면 거둡니다. 그 밖의 알림(작업 완료, 사용량)은 Mac이 notify로 보냅니다.
 */
object Notices {
    const val CHANNEL_REQUESTS = "requests"
    const val CHANNEL_ALERTS = "alerts"
    const val CHANNEL_LINK = "link"
    const val LINK_ID = 1
    private const val TAG_REQUEST = "request"

    private val shown = mutableSetOf<String>()
    private var alertId = 100

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_REQUESTS, context.getString(R.string.channel_requests), NotificationManager.IMPORTANCE_HIGH),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ALERTS, context.getString(R.string.channel_alerts), NotificationManager.IMPORTANCE_DEFAULT),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_LINK, context.getString(R.string.channel_link), NotificationManager.IMPORTANCE_MIN).apply {
                setShowBadge(false)
            },
        )
    }

    private fun allowed(context: Context) =
        Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun openApp(context: Context, sessionId: String? = null): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("session", sessionId)
        return PendingIntent.getActivity(
            context, sessionId?.hashCode() ?: 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    @Synchronized fun syncRequests(context: Context, state: JSONObject, foreground: Boolean) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val requests = state.optJSONArray("requests") ?: return
        val now = mutableSetOf<String>()
        for (index in 0 until requests.length()) {
            val request = requests.optJSONObject(index) ?: continue
            val id = request.optString("id")
            if (id.isEmpty()) continue
            now += id
            // 이미 띄웠거나 화면을 보고 있는 중이면 새로 띄우지 않습니다.
            if (id in shown || foreground) {
                shown += id
                continue
            }
            shown += id
            if (allowed(context)) manager.notify(TAG_REQUEST, id.hashCode(), requestNotification(context, request))
        }
        for (gone in shown - now) manager.cancel(TAG_REQUEST, gone.hashCode())
        shown.retainAll(now)
    }

    @Synchronized fun clearRequests(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        shown.forEach { manager.cancel(TAG_REQUEST, it.hashCode()) }
        shown.clear()
    }

    fun dismissRequest(context: Context, id: String) {
        context.getSystemService(NotificationManager::class.java).cancel(TAG_REQUEST, id.hashCode())
    }

    private fun requestNotification(context: Context, request: JSONObject): Notification {
        val id = request.optString("id")
        val project = request.optString("project")
        val builder = Notification.Builder(context, CHANNEL_REQUESTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFFA8E6B5.toInt())
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setContentIntent(openApp(context, request.optString("sessionId")))
            .setAutoCancel(true)
            .setSubText(project)
        if (request.optString("kind") == "permission") {
            val tool = request.optString("tool")
            builder.setContentTitle(context.getString(R.string.allow_tool, tool))
                .setContentText(request.optString("detail"))
                .setStyle(Notification.BigTextStyle().bigText(request.optString("detail")))
                .addAction(action(context, id, "deny", context.getString(R.string.deny)))
                .addAction(action(context, id, "allow", context.getString(R.string.allow)))
        } else {
            val question = request.optJSONArray("questions")?.optJSONObject(0)?.optString("question").orEmpty()
            builder.setContentTitle(context.getString(R.string.question))
                .setContentText(question)
                .setStyle(Notification.BigTextStyle().bigText(question))
        }
        return builder.build()
    }

    private fun action(context: Context, id: String, verb: String, title: String): Notification.Action {
        val intent = Intent(context, ActionReceiver::class.java).putExtra("request", id).putExtra("action", verb)
        val pending = PendingIntent.getBroadcast(
            context, (id + verb).hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Action.Builder(null, title, pending).build()
    }

    fun alert(context: Context, title: String, body: String) {
        if (!allowed(context)) return
        val notification = Notification.Builder(context, CHANNEL_ALERTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFFA8E6B5.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
            .build()
        synchronized(this) { alertId = if (alertId > 10_000) 100 else alertId + 1 }
        context.getSystemService(NotificationManager::class.java).notify(alertId, notification)
    }
}
