package io.github.eocnd36.kongi

import android.content.Context
import android.net.Uri
import java.util.Base64

/**
 * Mac의 QR 코드에 담긴 연결 정보 (PhonePairing).
 * kongi://pair?v=1&id=<Mac 식별자>&n=<Mac 이름>&h=<IP,IP>&p=<포트>&k=<키>
 */
data class Pairing(
    val id: String,
    val name: String,
    val hosts: List<String>,
    val port: Int,
    val key: ByteArray,
) {
    companion object {
        const val SERVICE_TYPE = "_kongi._tcp"

        fun parse(text: String): Pairing? {
            val uri = runCatching { Uri.parse(text.trim()) }.getOrNull() ?: return null
            return parse(
                scheme = uri.scheme,
                host = uri.host,
                query = { uri.getQueryParameter(it) },
            )
        }

        /** Uri 없이도 시험할 수 있게 나눠 둡니다. */
        fun parse(scheme: String?, host: String?, query: (String) -> String?): Pairing? {
            if (scheme != "kongi" || host != "pair" || query("v") != "1") return null
            val id = query("id")?.takeIf { it.isNotEmpty() } ?: return null
            val port = query("p")?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val key = query("k")?.let { decodeKey(it) }?.takeIf { it.size == PhoneCipher.KEY_SIZE } ?: return null
            val hosts = query("h").orEmpty().split(",").map { it.trim() }.filter { it.isNotEmpty() }
            // 같은 Wi-Fi 안의 Mac만 받습니다. 바깥 주소가 섞인 코드는 Kongi가 만든 것이 아닙니다.
            if (hosts.isEmpty() || !hosts.all(::isPrivateIpv4)) return null
            return Pairing(id, query("n").orEmpty(), hosts, port, key)
        }

        /** 10/8, 172.16/12, 192.168/16 (Mac의 Kongi가 QR에 넣는 주소와 같은 범위) */
        fun isPrivateIpv4(host: String): Boolean {
            val parts = host.split(".")
            if (parts.size != 4) return false
            val bytes = parts.map { part -> part.toIntOrNull()?.takeIf { it in 0..255 && part == it.toString() } ?: return false }
            return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] in 16..31) || (bytes[0] == 192 && bytes[1] == 168)
        }

        private fun decodeKey(text: String): ByteArray? =
            runCatching { Base64.getUrlDecoder().decode(text) }.getOrNull()

        private const val PREFS = "pairing"

        fun load(context: Context): Pairing? {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val id = prefs.getString("id", null) ?: return null
            val key = prefs.getString("key", null)?.let {
                runCatching { Base64.getDecoder().decode(it) }.getOrNull()
            } ?: return null
            if (key.size != PhoneCipher.KEY_SIZE) return null
            return Pairing(
                id = id,
                name = prefs.getString("name", "").orEmpty(),
                hosts = prefs.getString("hosts", "").orEmpty().split(",").filter { it.isNotEmpty() },
                port = prefs.getInt("port", 0),
                key = key,
            )
        }

        fun clear(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        }
    }

    fun save(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("id", id)
            .putString("name", name)
            .putString("hosts", hosts.joinToString(","))
            .putInt("port", port)
            .putString("key", Base64.getEncoder().encodeToString(key))
            .apply()
    }

    override fun equals(other: Any?) =
        other is Pairing && id == other.id && name == other.name && hosts == other.hosts && port == other.port && key.contentEquals(other.key)

    override fun hashCode() = id.hashCode()
}
