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

    @Test fun picksThePhoneLanguage() {
        val notes = "### What's new in 2.2.3\n- 🚨 **Fixed** — x\n- **Faster**\n\n### [ko] 2.2.3의 새로운 점\n- **빨라짐** — y\n\n### [zh-Hant] 新功能\n- **更快**"
        assertEquals(listOf("빨라짐"), Updates.highlights(notes, language = "ko"))
        assertEquals(listOf("更快"), Updates.highlights(notes, language = "zh-Hant"))
        assertEquals(listOf("🚨 Fixed", "Faster"), Updates.highlights(notes, language = "fr"))
        assertEquals("zh-Hant", Updates.noteLanguage(java.util.Locale.forLanguageTag("zh-TW")))
        assertEquals("zh-Hans", Updates.noteLanguage(java.util.Locale.forLanguageTag("zh-CN")))
        assertEquals("pt-BR", Updates.noteLanguage(java.util.Locale.forLanguageTag("pt-PT")))
    }
}
