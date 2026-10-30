package io.github.eocnd36.kongi

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.URL
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Mac의 Kongi와 같은 Wi-Fi 안에서 주고받습니다.
 *
 * - 요청: `POST /rpc` 본문에 {m, p, b, t}를 봉인해 보내고, 봉인된 {s, b}를 받습니다.
 * - 실시간: `POST /events`로 연 스트림에서 봉인된 {e, d} (state, notify)를 받습니다.
 *
 * 화면(MainActivity)이나 백그라운드 연결(LinkService)이 붙잡고 있는 동안만 스트림을 엽니다.
 * Mac의 IP가 바뀌면 Bonjour(_kongi._tcp)로 다시 찾습니다.
 */
object MacLink {
    interface Listener {
        fun onState(json: String)
        fun onConnection(live: Boolean)
        fun onNotice(title: String, body: String)
    }

    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private val rpcPool = Executors.newFixedThreadPool(3)
    private val holders = mutableSetOf<String>()
    private var stream: Thread? = null
    private var generation = 0
    private val current = AtomicReference<HttpURLConnection?>(null)

    @Volatile var pairing: Pairing? = null
        private set
    @Volatile private var lastHost: String? = null
    @Volatile var live = false
        private set
    @Volatile var lastState: String? = null
        private set
    /** 화면이 보이는 중인지. 보일 때는 알림 대신 화면 안에서 알려 줍니다. */
    @Volatile var foreground = false

    var listener: Listener? = null
    var onLiveChange: ((Boolean) -> Unit)? = null

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        pairing = Pairing.load(app)
        lastHost = app.getSharedPreferences("link", Context.MODE_PRIVATE).getString("host", null)
        Notices.createChannels(app)
    }

    fun pair(new: Pairing) {
        new.save(app)
        pairing = new
        lastHost = null
        candidate = null
        lastState = null
        Notices.clearRequests(app)
        restart()
    }

    fun unpair() {
        Pairing.clear(app)
        pairing = null
        lastState = null
        Notices.clearRequests(app)
        restart()
        LinkService.stop(app)
    }

    @Synchronized fun hold(tag: String) {
        holders += tag
        if (stream == null) startStream()
    }

    @Synchronized fun release(tag: String) {
        holders -= tag
        if (holders.isEmpty()) stopStream()
    }

    @Synchronized private fun restart() {
        stopStream()
        if (holders.isNotEmpty()) startStream()
    }

    private fun startStream() {
        val mine = ++generation
        stream = Thread({ runStream(mine) }, "kongi-stream").also { it.start() }
    }

    private fun stopStream() {
        generation++
        stream?.interrupt()
        stream = null
        current.getAndSet(null)?.disconnect()
        setLive(false)
    }

    private fun stillCurrent(mine: Int) = synchronized(this) { mine == generation }

    // MARK: stream

    private fun runStream(mine: Int) {
        var failures = 0
        while (stillCurrent(mine)) {
            val pairing = pairing ?: return
            val opened = try {
                openEvents(pairing, mine)
            } catch (_: InterruptedException) {
                return
            } catch (_: Exception) {
                false
            }
            setLive(false)
            if (!stillCurrent(mine)) return
            failures = if (opened) 0 else failures + 1
            // 몇 번 실패하면 Mac이 IP를 바꿨을 수 있으니 Bonjour로 다시 찾습니다.
            if (failures == 2 || failures % 6 == 0) discover(pairing)
            try {
                Thread.sleep(minOf(2_000L * failures, 15_000L).coerceAtLeast(1_000L))
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    /**
     * 스트림을 한 번 열어 끊길 때까지 읽습니다. Mac이 맞다고 확인됐으면(첫 업데이트가 키로 열렸으면) true.
     * 주소는 키로 연 응답이 온 뒤에만 기억합니다. 같은 Wi-Fi의 다른 기기가 흉내 내도 넘어가지 않습니다.
     */
    private fun openEvents(pairing: Pairing, mine: Int): Boolean {
        val cipher = PhoneCipher(pairing.key)
        var forbidden = false
        for (host in hosts(pairing)) {
            if (!stillCurrent(mine)) return false
            val sealed = cipher.seal(envelope("POST", "/events", null).toByteArray(), PhoneCipher.REQUEST)
            val nonce = sealed.copyOfRange(0, PhoneCipher.NONCE_SIZE)
            val connection = open(host, pairing.port, "/events", sealed, readTimeout = 70_000) ?: continue
            current.set(connection)
            try {
                val code = runCatching { connection.responseCode }.getOrDefault(0)
                if (code == 403 && trusted(host, pairing)) forbidden = true
                if (code != 200) continue
                val reader = BufferedReader(InputStreamReader(connection.inputStream, Charsets.UTF_8))
                val data = StringBuilder()
                var verified = false
                while (stillCurrent(mine)) {
                    val line = reader.readLine() ?: break
                    when {
                        line.startsWith("data: ") -> data.append(line, 6, line.length)
                        line.isEmpty() && data.isNotEmpty() -> {
                            val opened = handleEvent(cipher, nonce, data.toString())
                            data.setLength(0)
                            if (!verified) {
                                // Mac은 스트림을 열자마자 상태를 보냅니다. 열리지 않으면 다른 기기입니다.
                                if (!opened) break
                                verified = true
                                remember(host)
                                setLive(true)
                            }
                        }
                    }
                }
                if (verified) return true
            } catch (_: Exception) {
                // 다음 주소로
            } finally {
                current.compareAndSet(connection, null)
                connection.disconnect()
            }
        }
        if (forbidden) {
            // 키가 바뀌었습니다 (Mac에서 "다시 연결"을 눌렀음). 다시 찍어야 합니다.
            post { listener?.onState("""{"unpaired":true}""") }
            Thread.sleep(30_000)
        }
        return false
    }

    /** 키로 열린 업데이트였으면 true */
    private fun handleEvent(cipher: PhoneCipher, nonce: ByteArray, text: String): Boolean {
        val plain = runCatching { cipher.open(Base64.getDecoder().decode(text), PhoneCipher.event(nonce)) }.getOrNull() ?: return false
        val event = runCatching { JSONObject(String(plain, Charsets.UTF_8)) }.getOrNull() ?: return false
        val data = event.optJSONObject("d") ?: return true
        when (event.optString("e")) {
            "state" -> {
                val json = data.toString()
                lastState = json
                Notices.syncRequests(app, data, foreground)
                post { listener?.onState(json) }
            }
            "notify" -> {
                val title = data.optString("title")
                val body = data.optString("body")
                if (foreground) post { listener?.onNotice(title, body) } else Notices.alert(app, title, body)
            }
        }
        return true
    }

    // MARK: requests

    /** 요청 하나를 보내고 (상태 코드, 응답 JSON)을 돌려줍니다. 백그라운드 스레드에서 부르세요. */
    fun rpcBlocking(method: String, path: String, body: JSONObject?): Pair<Int, String> {
        val pairing = pairing ?: return 401 to """{"error":"unpaired"}"""
        val cipher = PhoneCipher(pairing.key)
        // 요청 하나는 한 번만 봉인해 모든 주소에 같은 바이트를 보냅니다. Mac은 같은 nonce를 한 번만 받으므로,
        // 앞 주소에서 처리됐는데 답만 못 받았어도 다음 주소에서 두 번 실행되지 않습니다.
        val sealed = cipher.seal(envelope(method, path, body).toByteArray(), PhoneCipher.REQUEST)
        val nonce = sealed.copyOfRange(0, PhoneCipher.NONCE_SIZE)
        var forbidden = false
        // 앞 주소가 요청을 받아 갔으면 뒤의 403은 "이미 받은 요청"일 수 있어 연결 해제로 보지 않습니다.
        var delivered = false
        for (host in hosts(pairing)) {
            val connection = open(host, pairing.port, "/rpc", sealed, readTimeout = 20_000) ?: continue
            try {
                when (connection.responseCode) {
                    200 -> {
                        // 키로 열리는 답만 Mac의 답입니다. 열리지 않으면 다른 기기이니 다음 주소로.
                        val plain = runCatching { cipher.open(connection.inputStream.readBytes(), PhoneCipher.reply(nonce)) }.getOrNull()
                        if (plain == null) {
                            // 다른 기기가 받아 갔습니다. Mac에 전달했을 수도 있으니 받아 간 것으로 칩니다.
                            delivered = true
                            continue
                        }
                        remember(host)
                        val reply = JSONObject(String(plain, Charsets.UTF_8))
                        return reply.optInt("s", 500) to (reply.optJSONObject("b") ?: JSONObject()).toString()
                    }
                    403 -> if (trusted(host, pairing) && !delivered) forbidden = true
                }
                delivered = true
            } catch (_: Exception) {
                delivered = true
            } finally {
                connection.disconnect()
            }
        }
        return if (forbidden) 401 to """{"error":"unpaired"}""" else 0 to """{"error":"offline"}"""
    }

    fun rpc(method: String, path: String, body: JSONObject?, done: (Int, String) -> Unit) {
        rpcPool.execute {
            val (status, json) = rpcBlocking(method, path, body)
            post { done(status, json) }
        }
    }

    private fun envelope(method: String, path: String, body: JSONObject?): String =
        JSONObject()
            .put("m", method)
            .put("p", path)
            .put("b", body ?: JSONObject())
            .put("t", System.currentTimeMillis() / 1000.0)
            .toString()

    /** 확인된 주소, Bonjour 후보, QR의 주소 순서. 같은 Wi-Fi 안의 주소만 씁니다. */
    private fun hosts(pairing: Pairing): List<String> =
        (listOfNotNull(lastHost, candidate) + pairing.hosts).filter(Pairing::isPrivateIpv4).distinct()

    /** 거절(403)을 믿어도 되는 주소: QR에 있었거나 키로 확인된 적이 있는 주소 */
    private fun trusted(host: String, pairing: Pairing) = host == lastHost || host in pairing.hosts

    /** 주소 하나로 요청을 보내고 응답 머리까지 받습니다. 연결이 안 되면 null. */
    private fun open(host: String, port: Int, path: String, body: ByteArray, readTimeout: Int): HttpURLConnection? {
        val connection = (URL("http", host, port, path).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 3_000
            this.readTimeout = readTimeout
            doOutput = true
            useCaches = false
            setRequestProperty("Content-Type", "application/octet-stream")
            setFixedLengthStreamingMode(body.size)
        }
        return try {
            connection.outputStream.use { it.write(body) }
            connection.responseCode
            connection
        } catch (_: Exception) {
            connection.disconnect()
            null
        }
    }

    /** 키로 연 응답이 온 주소만 부릅니다. */
    private fun remember(host: String) {
        if (candidate == host) candidate = null
        if (host == lastHost) return
        lastHost = host
        app.getSharedPreferences("link", Context.MODE_PRIVATE).edit().putString("host", host).apply()
    }

    // MARK: discovery

    @Volatile private var discovering = false
    /** Bonjour로 찾은 주소. 이름은 누구나 흉내 낼 수 있으므로 키로 연 응답이 오기 전까지는 후보일 뿐입니다. */
    @Volatile private var candidate: String? = null

    /** Bonjour로 같은 이름의 Mac을 찾아 후보 주소로 둡니다 (최대 8초). */
    private fun discover(pairing: Pairing) {
        if (discovering) return
        discovering = true
        val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceName != pairing.id) return
                @Suppress("DEPRECATION")
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, error: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        @Suppress("DEPRECATION")
                        val host = info.host
                        val address = (host as? Inet4Address)?.hostAddress ?: return
                        if (Pairing.isPrivateIpv4(address)) candidate = address
                    }
                })
            }
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onStartDiscoveryFailed(type: String, error: Int) { discovering = false }
            override fun onStopDiscoveryFailed(type: String, error: Int) {}
        }
        runCatching { nsd.discoverServices(Pairing.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { discovering = false; return }
        main.postDelayed({
            runCatching { nsd.stopServiceDiscovery(listener) }
            discovering = false
        }, 8_000)
    }

    private fun setLive(value: Boolean) {
        if (live == value) return
        live = value
        post {
            listener?.onConnection(value)
            onLiveChange?.invoke(value)
        }
    }

    private fun post(block: () -> Unit) {
        main.post(block)
    }
}
