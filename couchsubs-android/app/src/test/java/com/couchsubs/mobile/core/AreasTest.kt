// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Altyazı alanının hazır seçimleri ve ek alanlar (Mac/iPhone AreaPresetTests ve RegionWatcherTests ile aynı durumlar). */
class AreasTest {
    @Test
    fun presetsMatchTheirRegions() {
        assertEquals(AreaPreset.BOTTOM, AreaPreset.matching(CropRegion()))
        assertEquals(AreaPreset.TOP, AreaPreset.matching(CropRegion(top = 0.03, bottom = 0.38, left = 0.14, right = 0.86)))
        assertEquals(AreaPreset.FULL, AreaPreset.matching(CropRegion(0.0, 1.0, 0.0, 1.0)))
        assertEquals(AreaPreset.CUSTOM, AreaPreset.matching(CropRegion(top = 0.5)))
        assertEquals(ExtraAreaPreset.PHONE, ExtraAreaPreset.matching(ExtraAreaPreset.PHONE.region))
        assertNull(ExtraAreaPreset.matching(CropRegion()))
    }

    @Test
    fun regionStaysInsideTheFrame() {
        val moved = CropRegion().moved(dx = 0.5, dy = 0.5)
        assertEquals(1.0, moved.bottom, 1e-9)
        assertEquals(1.0, moved.right, 1e-9)
        val small = CropRegion().resized(right = 0.0, bottom = 0.0)
        assertEquals(MINIMUM_REGION_SIZE, small.bottom - small.top, 1e-9)
        val vertical = CropRegion().withVertical(position = 90.0, height = 30.0)
        assertEquals(0.7, vertical.top, 1e-9)
        assertEquals(1.0, vertical.bottom, 1e-9)
    }

    @Test
    fun extraAreasRoundTripAndAreCapped() {
        val areas = (1..5).map { ExtraArea(name = "Alan $it", region = ExtraAreaPreset.QUEST.region, enabled = it % 2 == 1) }
        val read = ExtraArea.listFromJson(ExtraArea.listToJson(areas))
        assertEquals(ExtraArea.MAX_COUNT, read.size)
        assertEquals(areas.take(3), read)
        assertEquals(listOf("Alan 1", "Alan 3"), read.active().map { it.name })
        assertEquals(emptyList<ExtraArea>(), ExtraArea.listFromJson("bozuk"))
    }

    @Test
    fun paragraphsJoinWrappedLines() {
        val lines = listOf(TextLine("NEW OBJECTIVE"), TextLine("Meet Lamar at the"), TextLine("garage."), TextLine("Bring the car."))
        assertEquals(listOf("NEW OBJECTIVE", "Meet Lamar at the garage.", "Bring the car."), ScreenText.paragraphs(lines))
        assertTrue(ScreenText.isWords("Go home"))
        assertFalse(ScreenText.isWords("23m 9"))
    }

    private class Recorder : RegionSender {
        val sent = mutableListOf<Pair<String, String>>()
        var cleared = 0
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sent.add(id to text)
        }
        override fun clearRegions() {
            cleared++
        }
    }

    private fun signature(value: Int) = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT) { value.toByte() }

    @Test
    fun stableTextIsTranslatedOnceAndClearedWhenGone() {
        val recorder = Recorder()
        var text = "Meet Lamar at the garage."
        var now = 0L
        val watcher = RegionWatcher({ Reading.fromText(text) }, { "TR: $it" }, recorder, clock = { now })
        val area = ExtraArea(id = "q", name = "Görev", region = ExtraAreaPreset.QUEST.region)
        fun pass(value: Int) {
            assertTrue(watcher.offer(listOf(area), { RegionWatcher.Crop(Unit, signature(value)) }) { it.run() })
            now += 1000
        }
        pass(10) // ilk okuma: henüz kararlı değil
        assertEquals(emptyList<Pair<String, String>>(), recorder.sent)
        pass(10) // iz değişmedi: kararlı, çevrilir
        assertEquals(listOf("q" to "TR: Meet Lamar at the garage."), recorder.sent)
        pass(10) // aynı yazı yeniden çevrilmez
        assertEquals(1, recorder.sent.size)
        assertEquals(1, watcher.reads)
        text = ""
        pass(200)
        pass(200)
        assertEquals("q" to "", recorder.sent.last())
        watcher.reset()
        assertEquals(0, recorder.cleared)
    }

    @Test
    fun failedTranslationRetriesWithoutLosingPreviouslyShownText() {
        val recorder = Recorder()
        var text = "Talk to Arthur"
        var now = 0L
        var failures = 0
        val calls = mutableListOf<String>()
        val watcher = RegionWatcher({ Reading.fromText(text) }, {
            calls.add(it)
            if (failures > 0) { failures--; throw IllegalStateException("expected") }
            "TR: $it"
        }, recorder, clock = { now })
        val area = ExtraArea(id = "q", name = "Görev", region = ExtraAreaPreset.QUEST.region)
        fun pass(value: Int) {
            assertTrue(watcher.offer(listOf(area), { RegionWatcher.Crop(Unit, signature(value)) }) { it.run() })
            now += 1000
        }
        pass(10)
        pass(10)
        assertEquals(listOf("q" to "TR: Talk to Arthur"), recorder.sent)

        text = "Meet Arthur at the barn"
        failures = 1
        pass(90)
        pass(90)
        assertEquals(listOf("q" to "TR: Talk to Arthur"), recorder.sent)

        pass(90)
        assertEquals(listOf("Talk to Arthur", "Meet Arthur at the barn", "Meet Arthur at the barn"), calls)
        assertEquals(listOf("q" to "TR: Talk to Arthur", "q" to "TR: Meet Arthur at the barn"), recorder.sent)
    }

    @Test
    fun removedAreaIsClearedAndFrequencyIsLimited() {
        val recorder = Recorder()
        var now = 0L
        val watcher = RegionWatcher({ Reading.fromText("Quest updated.") }, { "TR: $it" }, recorder, clock = { now })
        val area = ExtraArea(id = "n", name = "Bildirim", region = ExtraAreaPreset.NOTIFICATION.region)
        val crop: (CropRegion) -> RegionWatcher.Crop? = { RegionWatcher.Crop(Unit, signature(5)) }
        watcher.offer(listOf(area), crop) { it.run() }
        now += 100
        assertFalse(watcher.offer(listOf(area), crop) { it.run() })
        now += 1000
        watcher.offer(listOf(area), crop) { it.run() }
        assertEquals(listOf("n" to "TR: Quest updated."), recorder.sent)
        now += 1000
        watcher.offer(emptyList(), crop) { it.run() }
        assertEquals("n" to "", recorder.sent.last())
        watcher.reset()
        assertEquals(0, recorder.cleared)
    }

    @Test
    fun serverSendsRegionEvents() {
        val frame = SubtitleServer.regionFrame("q", "Lamar ile garajda buluş.", TextBox(0.66, 0.03, 0.98, 0.3), 0.03)
        assertTrue(frame, frame.startsWith("event: region\n"))
        assertTrue(frame, frame.contains("\"id\":\"q\"") && frame.contains("\"line\":0.03"))
    }
}
