package io.github.eocnd36.kongi

import android.app.Notification
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.github.eocnd36.kongi.ui.AppModel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * GitHub 릴리스로 앱을 업데이트합니다.
 *
 * Mac과 안드로이드가 같은 릴리스 번호를 쓰므로 버전 대신 **APK 해시**로 비교합니다:
 * 최신 릴리스의 SHA256SUMS.txt에 적힌 Kongi.apk 해시가 지금 설치된 APK와 다르면 새 버전입니다.
 * 내려받은 APK도 그 해시와 같을 때만 설치합니다 (안드로이드도 서명 키가 같아야만 설치를 허락함).
 */
object Updates {
    private const val BASE = "https://github.com/eocnd36/Kongi/releases/latest/download/"
    private const val PREFS = "updates"
    const val NOTIFY = "notify"
    const val AUTO = "auto"
    private const val CHECK_EVERY = 6 * 3600_000L
    private const val NOTICE_ID = 50

    private val main by lazy { Handler(Looper.getMainLooper()) }
    @Volatile private var busy = false

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun enabled(context: Context, key: String) = prefs(context).getBoolean(key, key == NOTIFY)
    fun set(context: Context, key: String, on: Boolean) = prefs(context).edit().putBoolean(key, on).apply()

    /** 배포용으로 서명한 빌드만 (debug·데모 빌드는 해시가 늘 달라서) */
    private val supported get() = BuildConfig.BUILD_TYPE == "release"

    /** 켤 때·백그라운드 연결 중에 부릅니다. 6시간에 한 번만 실제로 확인합니다. */
    fun check(context: Context, force: Boolean = false) {
        val app = context.applicationContext
        val last = prefs(app).getLong("checkedAt", 0)
        if (!supported || busy || (!force && System.currentTimeMillis() - last < CHECK_EVERY)) return
        if (!force && !enabled(app, NOTIFY) && !enabled(app, AUTO)) return
        busy = true
        main.post { AppModel.updateStatus = UpdateStatus.Checking }
        Thread {
            val result = runCatching { latestHash() }
            prefs(app).edit().putLong("checkedAt", System.currentTimeMillis()).apply()
            busy = false
            val expected = result.getOrNull()
            val status = when {
                expected == null -> if (force) UpdateStatus.Failed else UpdateStatus.Idle
                expected.equals(installedHash(app), ignoreCase = true) -> UpdateStatus.UpToDate
                else -> UpdateStatus.Available
            }
            // 무엇이 바뀌었는지 (릴리스 노트). 못 받아도 업데이트는 그대로.
            val release = if (status == UpdateStatus.Available) runCatching { latestRelease() }.getOrNull() else null
            release?.let { prefs(app).edit().putString("version", it.first).putString("notes", it.second).apply() }
            // 앱을 다시 열었을 때도 "새 버전" 창을 띄울 수 있게 기억해 둡니다.
            if (status == UpdateStatus.Available) prefs(app).edit().putBoolean("available", true).apply()
            if (status == UpdateStatus.UpToDate) prefs(app).edit().putBoolean("available", false).apply()
            main.post {
                AppModel.updateStatus = status
                if (release != null) {
                    AppModel.updateVersion = release.first
                    AppModel.updateChanges = highlights(release.second)
                    AppModel.updatePrompt = enabled(app, NOTIFY) && release.first != dismissed(app)
                }
            }
            if (status != UpdateStatus.Available || expected == null) return@Thread
            when {
                enabled(app, AUTO) -> install(app, expected)
                enabled(app, NOTIFY) && prefs(app).getString("notified", null) != expected -> {
                    prefs(app).edit().putString("notified", expected).apply()
                    notifyAvailable(app)
                }
            }
        }.start()
    }

    /** 설정의 "업데이트" 버튼, 알림 누르기 */
    fun installNow(context: Context) {
        val app = context.applicationContext
        // 처음에는 "이 출처의 앱 설치 허용"을 한 번 켜야 합니다.
        if (!app.packageManager.canRequestPackageInstalls()) {
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return
        }
        if (busy) return
        busy = true
        main.post { AppModel.updateStatus = UpdateStatus.Installing }
        Thread {
            val expected = runCatching { latestHash() }.getOrNull()
            busy = false
            if (expected == null) main.post { AppModel.updateStatus = UpdateStatus.Failed } else install(app, expected)
        }.start()
    }

    /** 최신 릴리스의 (버전, 릴리스 노트) */
    private fun latestRelease(): Pair<String, String> {
        val json = org.json.JSONObject(String(download("https://api.github.com/repos/eocnd36/Kongi/releases/latest", limit = 500_000)))
        return json.optString("tag_name").removePrefix("v") to json.optString("body")
    }

    /** 릴리스 노트에서 바뀐 것 몇 줄: "What's new" 아래 목록의 굵은 제목 (Mac의 AppUpdate.highlights와 같은 규칙) */
    fun highlights(notes: String, limit: Int = 6): List<String> {
        var lines = notes.lines()
        val start = lines.indexOfFirst { it.startsWith("#") && it.lowercase().contains("new") }
        if (start >= 0) {
            lines = lines.drop(start + 1)
            val end = lines.indexOfFirst { it.startsWith("#") }
            if (end >= 0) lines = lines.take(end)
        }
        val result = mutableListOf<String>()
        for (line in lines) {
            if (!(line.startsWith("- ") || line.startsWith("* "))) continue
            var text = line.substring(2).trim()
            text = if (text.startsWith("**") && text.indexOf("**", 2) > 2) {
                text.substring(2, text.indexOf("**", 2))
            } else {
                text.replace("**", "").replace("`", "").substringBefore(" — ")
            }
            text = text.trim()
            if (text.isNotEmpty()) result += if (text.length > 80) text.take(79) + "…" else text
            if (result.size == limit) break
        }
        return result
    }

    /** 업데이트 뒤 처음 켰을 때: 이 버전의 바뀐 것 (한 번만) */
    fun takeInstalledNotes(context: Context): Pair<String, List<String>>? {
        val prefs = prefs(context)
        val version = prefs.getString("installing", null) ?: return null
        val notes = prefs.getString("notes", "").orEmpty()
        prefs.edit().remove("installing").apply()
        return if (version == BuildConfig.VERSION_NAME) version to highlights(notes) else null
    }

    /** 앱을 열 때: 지난번 확인에서 새 버전이 있었으면 그 상태를 되살립니다 (확인은 6시간에 한 번이라). */
    fun restore(context: Context) {
        val prefs = prefs(context)
        val version = prefs.getString("version", null)
        if (!supported || !prefs.getBoolean("available", false) || version == null || version == BuildConfig.VERSION_NAME) return
        AppModel.updateStatus = UpdateStatus.Available
        AppModel.updateVersion = version
        AppModel.updateChanges = highlights(prefs.getString("notes", "").orEmpty())
        AppModel.updatePrompt = enabled(context, NOTIFY) && version != dismissed(context)
    }

    /** 앱을 열 때 띄우는 "새 버전" 창을 이 버전에는 다시 띄우지 않음 */
    fun dismiss(context: Context, version: String) = prefs(context).edit().putString("dismissed", version).apply()
    fun dismissed(context: Context) = prefs(context).getString("dismissed", null)

    private fun latestHash(): String? {
        val sums = String(download(BASE + "SHA256SUMS.txt", limit = 64_000))
        return sums.lines().map { it.trim().split(Regex("\\s+")) }
            .firstOrNull { it.size == 2 && it[1].trimStart('*') == "Kongi.apk" }?.get(0)
            ?.takeIf { it.length == 64 }
    }

    private fun installedHash(context: Context) = sha256(File(context.applicationInfo.sourceDir).readBytes())

    /** 내려받고, 해시를 확인하고, 시스템 설치 창(또는 조용한 설치)으로 넘깁니다. 백그라운드 스레드에서. */
    private fun install(context: Context, expected: String) {
        main.post { AppModel.updateStatus = UpdateStatus.Installing }
        val apk = runCatching { download(BASE + "Kongi.apk", limit = 80_000_000) }.getOrNull()
        if (apk == null || !sha256(apk).equals(expected, ignoreCase = true)) {
            main.post { AppModel.updateStatus = UpdateStatus.Failed }
            return
        }
        // 설치 권한이 아직 없으면 (자동 업데이트일 때) 알림으로 알리고 끝냅니다.
        if (!context.packageManager.canRequestPackageInstalls()) {
            main.post { AppModel.updateStatus = UpdateStatus.Available }
            notifyAvailable(context)
            return
        }
        // 다시 열렸을 때 "무엇이 바뀌었는지"를 보여 주려고 적어 둡니다.
        prefs(context).getString("version", null)?.let { prefs(context).edit().putString("installing", it).apply() }
        runCatching {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            // Android 12+: 이 앱이 직접 설치한 적이 있으면 다음부터는 묻지 않고 설치됩니다.
            if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            val id = installer.createSession(params)
            installer.openSession(id).use { session ->
                session.openWrite("Kongi.apk", 0, apk.size.toLong()).use { out ->
                    out.write(apk)
                    session.fsync(out)
                }
                val intent = Intent(context, UpdateReceiver::class.java)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                session.commit(PendingIntent.getBroadcast(context, id, intent, flags).intentSender)
            }
        }.onFailure { main.post { AppModel.updateStatus = UpdateStatus.Failed } }
    }

    private fun download(url: String, limit: Int): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("User-Agent", "Kongi-Android/${BuildConfig.VERSION_NAME}")
        try {
            check(connection.responseCode == 200) { "HTTP ${connection.responseCode}" }
            val bytes = connection.inputStream.use { it.readNBytesCompat(limit + 1) }
            check(bytes.size <= limit) { "too large" }
            return bytes
        } finally {
            connection.disconnect()
        }
    }

    private fun java.io.InputStream.readNBytesCompat(max: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (out.size() < max) {
            val read = read(buffer, 0, minOf(buffer.size, max - out.size()))
            if (read < 0) break
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun notifyAvailable(context: Context) {
        val changes = highlights(prefs(context).getString("notes", "").orEmpty(), limit = 4)
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("update", true)
        val pending = PendingIntent.getActivity(context, NOTICE_ID, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        Notices.show(
            context, NOTICE_ID,
            Notification.Builder(context, Notices.CHANNEL_ALERTS)
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(0xFFA8E6B5.toInt())
                .setContentTitle(context.getString(R.string.update_available))
                .setContentText(if (changes.isEmpty()) context.getString(R.string.update_tap) else changes.joinToString(" · "))
                .setStyle(Notification.BigTextStyle().bigText(
                    (changes.map { "• $it" } + context.getString(R.string.update_tap)).joinToString("\n"),
                ))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build(),
        )
    }

    /** 설치가 끝나거나 사용자 확인이 필요할 때 시스템이 부릅니다. */
    class UpdateReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    @Suppress("DEPRECATION")
                    val confirm = (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        else intent.getParcelableExtra(Intent.EXTRA_INTENT)) ?: return
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    // 화면을 보고 있으면 바로 설치 창을, 아니면 알림으로 (백그라운드에서는 창을 띄울 수 없음)
                    if (MacLink.foreground) context.startActivity(confirm) else notifyAvailable(context)
                }
                PackageInstaller.STATUS_SUCCESS -> Unit // 앱이 새 버전으로 다시 시작됩니다.
                else -> main.post { AppModel.updateStatus = UpdateStatus.Failed }
            }
        }
    }
}

enum class UpdateStatus { Idle, Checking, UpToDate, Available, Installing, Failed }
