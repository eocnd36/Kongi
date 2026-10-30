package io.github.eocnd36.kongi

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

class PhoneCipherTest {
    private val key = ByteArray(32) { 7 }

    /** Mac 쪽 PhoneLinkTests.opensKnownBox가 여는 상자와 같아야 합니다. */
    @Test fun matchesMacFixture() {
        val box = PhoneCipher(key).seal("""{"t":1}""".toByteArray(), PhoneCipher.REQUEST, ByteArray(12) { it.toByte() })
        assertEquals(FIXTURE, Base64.getEncoder().encodeToString(box))
    }

    @Test fun roundTripsAndChecksContext() {
        val cipher = PhoneCipher(key)
        val box = cipher.seal("hello".toByteArray(), PhoneCipher.REQUEST)
        assertArrayEquals("hello".toByteArray(), cipher.open(box, PhoneCipher.REQUEST))
        assertThrows(Exception::class.java) { cipher.open(box, PhoneCipher.reply(box.copyOf(12))) }
        assertThrows(Exception::class.java) { PhoneCipher(ByteArray(32)).open(box, PhoneCipher.REQUEST) }
    }

    @Test fun parsesPairing() {
        val query = mapOf(
            "v" to "1", "id" to "kongi-1a2b", "n" to "Mac", "h" to "192.168.0.5,10.0.0.2", "p" to "47815",
            "k" to Base64.getUrlEncoder().withoutPadding().encodeToString(key),
        )
        val pairing = Pairing.parse("kongi", "pair") { query[it] }!!
        assertEquals(listOf("192.168.0.5", "10.0.0.2"), pairing.hosts)
        assertEquals(47815, pairing.port)
        assertArrayEquals(key, pairing.key)
        assertNull(Pairing.parse("https", "pair") { query[it] })
        // 바깥 주소가 섞이거나 주소가 없으면 받지 않습니다.
        assertNull(Pairing.parse("kongi", "pair") { if (it == "h") "192.168.0.5,203.0.113.7" else query[it] })
        assertNull(Pairing.parse("kongi", "pair") { if (it == "h") "" else query[it] })
        assertNull(Pairing.parse("kongi", "pair") { if (it == "h") "evil.example.com" else query[it] })
        assertNull(Pairing.parse("kongi", "pair") { if (it == "h") "172.32.0.1" else query[it] })
        assertNull(Pairing.parse("kongi", "pair") { if (it == "k") "c2hvcnQ" else query[it] })
    }

    companion object {
        const val FIXTURE = "AAECAwQFBgcICQoLY6OdUic4pH0N10v2jf6fuKBwoL+Siu0="
    }
}
