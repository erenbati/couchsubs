// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Kullanıcı bildirimi (X): konuşan adı ("Lucia: …") diyalogların yalnız ~%20'sinde gösteriliyor, kalanında düşüyordu.
 * Yazı tanıma oyunun renkli adını cümleden ayrı satır okuyabiliyor. Ad cümlenin üstünde ayrı satır kalınca, aynı kişi
 * konuşmayı sürdürdükçe değişmeden durduğu için görev/HUD satırı sayılıp atılıyor (ad yalnız konuşan değişince, ilk
 * replikte görünüyordu); aynı satırda ama kutusu kaymış okunan ad ise ayrı blok sayılıp hiç gösterilmiyordu
 * (Mac/iPhone: SpeakerNameRowsTests.swift, Windows: SpeakerNameRowsTests.cs).
 */
class SpeakerNameRowsTest {
    private val dialog = listOf(
        "Lucia" to "Could I have another ice water, please?", "Lucia" to "It is so hot out there today.",
        "Lucia" to "I think I need to sit down.", "Jason" to "Just be quiet. Donnie's up.",
        "Jason" to "We gotta go now, come on.", "Lucia" to "Okay, okay.",
    )

    private val expected = listOf(
        "Lucia: Çeviri 1.", "Lucia: Çeviri 2.", "Lucia: Çeviri 3.", "Jason: Çeviri 4.", "Jason: Çeviri 5.", "Lucia: Çeviri 6.",
    )

    /** Her replik 17 kare (150 ms arayla ~2,5 sn) ekranda; kutular bütün kareye oranla (gerçek kare gta6-08-jason'ın yerleri). */
    private fun replay(shape: (String, String) -> List<TextLine>): List<String> {
        val executor = Executors.newSingleThreadExecutor()
        val requested = Collections.synchronizedList(mutableListOf<String>())
        val sent = Collections.synchronizedList(mutableListOf<String>())
        val translator = object : TextTranslator {
            override fun translate(text: String): String {
                requested.add(text)
                return "Çeviri ${requested.size}."
            }
        }
        val sender = object : SubtitleSender {
            override fun sendSubtitle(text: String, durationMs: Int, box: TextBox?, replaces: Boolean) {
                sent.add(text)
            }
            override fun clear() {}
        }
        var time = 0L
        val pipeline = SubtitlePipeline(translator, sender, { time }, executor)
        try {
            for ((name, body) in dialog) {
                repeat(17) {
                    pipeline.process(Reading(shape(name, body)), TextBox(0.0, 0.0, 1.0, 1.0))
                    executor.submit {}.get(5, TimeUnit.SECONDS)
                    time += 150
                }
            }
            return sent.toList()
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun nameOnItsOwnRowAboveKeepsTheNameOnEveryLine() {
        val sent = replay { name, body ->
            listOf(TextLine("$name:", TextBox(0.47, 0.83, 0.53, 0.865)), TextLine(body, TextBox(0.33, 0.875, 0.67, 0.925)))
        }
        assertEquals(expected, sent)
    }

    @Test
    fun nameReadApartOnTheSameRowIsJoined() {
        val sent = replay { name, body ->
            listOf(TextLine("$name:", TextBox(0.338, 0.862, 0.397, 0.905)), TextLine(body, TextBox(0.47, 0.872, 0.665, 0.927)))
        }
        assertEquals(expected, sent)
    }

    @Test
    fun inlineNameStillWorks() {
        val sent = replay { name, body -> listOf(TextLine("$name: $body", TextBox(0.335, 0.87, 0.665, 0.927))) }
        assertEquals(expected, sent)
    }

    @Test
    fun nameOnlyLines() {
        assertEquals("Lucia", SpeakerPrefix.nameOnly("Lucia:"))
        assertEquals("JASON", SpeakerPrefix.nameOnly(" JASON : "))
        assertEquals("CO Wilson", SpeakerPrefix.nameOnly("CO Wilson："))
        assertEquals("Dre'Quan", SpeakerPrefix.nameOnly("Dre'Quan:"))
        for (line in listOf("Note:", "Objective:", "Lucia: Wait.", "lucia:", "10:", "Lucia", "Very Long Name Of Four:", "")) {
            assertNull(line, SpeakerPrefix.nameOnly(line))
        }
        // Büyük harfli ad ve iki noktadan sonra boşluksuz okuma da ad sayılır.
        assertEquals(SpeakerPrefix.Split("LUCIA", "COULD I HAVE ANOTHER?"), SpeakerPrefix.split("LUCIA: COULD I HAVE ANOTHER?"))
        assertEquals(SpeakerPrefix.Split("Lucia", "Could I have another?"), SpeakerPrefix.split("Lucia:Could I have another?"))
    }

    @Test
    fun joiningRowsAttachesTheNameToItsSentence() {
        val above = Reading(
            listOf(
                TextLine("Lucia:", TextBox(0.45, 0.60, 0.55, 0.70)),
                TextLine("We don't have a car,", TextBox(0.20, 0.72, 0.80, 0.82)),
                TextLine("food or clothes.", TextBox(0.30, 0.84, 0.70, 0.94)),
            ),
        )
        val joined = above.joiningRows()
        assertEquals(listOf("Lucia: We don't have a car,", "food or clothes."), joined.lines.map { it.text })
        // Kutu cümlenin satırıdır (yatayda adı da kapsar).
        assertEquals(TextBox(0.20, 0.72, 0.80, 0.82), joined.lines[0].box)

        // Yerleri bilinmeyen okuma: ad alttaki satıra katılır.
        assertEquals("JASON: What the hell was that?", Reading.fromText("JASON:\nWhat the hell was that?").joiningRows().text)

        // Ad değil ("Note:"), altında cümle yok, cümle çok uzakta, yatayda başka yerde ya da alttaki zaten adlı: dokunulmaz.
        val untouched = listOf(
            Reading(listOf(TextLine("Note:", TextBox(0.45, 0.60, 0.55, 0.70)), TextLine("The gate is shut.", TextBox(0.30, 0.72, 0.70, 0.82)))),
            Reading(listOf(TextLine("Lucia:", TextBox(0.45, 0.60, 0.55, 0.70)), TextLine("42", TextBox(0.45, 0.72, 0.55, 0.82)))),
            Reading(listOf(TextLine("Lucia:", TextBox(0.45, 0.20, 0.55, 0.30)), TextLine("Could I have another?", TextBox(0.30, 0.72, 0.70, 0.82)))),
            Reading(listOf(TextLine("Lucia:", TextBox(0.05, 0.60, 0.12, 0.70)), TextLine("Could I have another?", TextBox(0.30, 0.72, 0.70, 0.82)))),
            Reading(listOf(TextLine("Lucia:", TextBox(0.45, 0.60, 0.55, 0.70)), TextLine("Jason: Not now.", TextBox(0.30, 0.72, 0.70, 0.82)))),
        )
        for (reading in untouched) assertEquals(reading.lines.map { it.text }, reading.joiningRows().lines.map { it.text })
    }
}
