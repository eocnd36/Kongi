package io.github.eocnd36.kongi

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mac의 UpdateNotesTests와 같은 경우들 */
class UpdatesTest {
    @Test fun picksTheHeadlines() {
        val notes = """
            **Kongi is a Dynamic Island** — intro.

            ### What's new in 2.2

            - **Automatic updates on the Mac** — Settings → General.
            - **The Android app updates itself** — Settings → Updates.
              - nested detail
            - Plain line — with detail

            **Android:** install by hand once.
        """.trimIndent()
        assertEquals(
            listOf("Automatic updates on the Mac", "The Android app updates itself", "Plain line"),
            Updates.highlights(notes),
        )
        assertEquals(listOf("one", "two"), Updates.highlights("- one\n- two\n- three", limit = 2))
        assertEquals(emptyList<String>(), Updates.highlights("no list here"))
    }
}
