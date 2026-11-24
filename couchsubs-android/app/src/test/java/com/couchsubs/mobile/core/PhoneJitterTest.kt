// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * X (22 Kas, GTA 6 telefonu): "yazılar sürekli oynuyor okumak çok zor, balonların içinde de aynı hata var". Aynı balon küçük
 * oynamada yerinde kalır ([PhoneSteady.steadyPositions]), panel el titremesiyle kaymaz ([PhoneSteady.steadyPose]), aynı
 * görünen gönderi yinelenmez ([PhoneSteady.samePicture]); gerçek kaydırmada hepsi birlikte bir kerede geçer (Mac
 * PhoneJitterTests.swift, Windows PhoneJitterTests.cs ile aynı vektörler).
 */
class PhoneJitterTest {
    private fun item(text: String, box: TextBox, line: Double = 0.03) =
        ScreenTranslation.Item(text, "Çevrildi: $text", box, line)

    @Test
    fun smallJitterKeepsEachBubbleWhereItWasDrawn() {
        val before = listOf(item("Thx amigo! U find", TextBox(0.62, 0.65, 0.75, 0.69)),
            item("New message", TextBox(0.64, 0.59, 0.75, 0.62)))
        val jiggled = listOf(before[0].copy(source = "Thx amigo! U flnd", box = TextBox(0.623, 0.655, 0.753, 0.695)),
            before[1].copy(box = TextBox(0.638, 0.586, 0.748, 0.616)))
        val still = PhoneSteady.steadyPositions(jiggled, before, 16.0 / 9)
        assertEquals(0.62, still[0].box.left, 1e-9)
        assertEquals(0.65, still[0].box.top, 1e-9)
        assertEquals(0.59, still[1].box.top, 1e-9)
        assertEquals(0.03, still[1].box.bottom - still[1].box.top, 1e-9)

        val scrolled = before.map { it.copy(box = it.box.copy(top = it.box.top - 0.02, bottom = it.box.bottom - 0.02)) }
        assertEquals(scrolled, PhoneSteady.steadyPositions(scrolled, before, 16.0 / 9))

        val one = listOf(jiggled[0].copy(box = jiggled[0].box.copy(top = 0.665, bottom = 0.705)), jiggled[1])
        val mixed = PhoneSteady.steadyPositions(one, before, 16.0 / 9)
        assertEquals(0.665, mixed[0].box.top, 1e-9)
        assertEquals(0.59, mixed[1].box.top, 1e-9)

        val other = listOf(jiggled[0], jiggled[1].copy(translation = "Başka"))
        assertEquals(other[1].box, PhoneSteady.steadyPositions(other, before, 16.0 / 9)[1].box)
    }

    @Test
    fun panelAnchorIgnoresHandShakeAndFollowsARealMove() {
        val pose = GamePhoneGeometry.Pose(0.70, 0.19, 0.70, 0.87)
        val shaken = GamePhoneGeometry.Pose(0.704, 0.186, 0.703, 0.874)
        assertEquals(pose, PhoneSteady.steadyPose(shaken, pose))
        val moved = GamePhoneGeometry.Pose(0.66, 0.19, 0.66, 0.87)
        assertEquals(moved, PhoneSteady.steadyPose(moved, pose))
        assertEquals(shaken, PhoneSteady.steadyPose(shaken, null))
    }

    @Test
    fun panelMessagesAreComparedByOrderAndTextNotByTheirFlowBoxes() {
        val card = item("", TextBox(0.2, 0.2, 0.5, 0.8)).copy(translation = ScreenPhoneCard.BACKDROP_TEXT,
            panel = ScreenPhoneCard.PanelPart.CARD)
        val message = item("Hi", TextBox(0.22, 0.3, 0.4, 0.34)).copy(panel = ScreenPhoneCard.PanelPart.THEIRS)
        val nudged = message.copy(box = message.box.copy(top = 0.304))
        assertTrue(PhoneSteady.samePicture(listOf(card, message), listOf(card, nudged)))
        assertFalse(PhoneSteady.samePicture(listOf(card, message), listOf(card, message.copy(translation = "Selam"))))
        assertFalse(PhoneSteady.samePicture(listOf(card, message), listOf(card.copy(box = card.box.copy(left = 0.21)), message)))
        assertFalse(PhoneSteady.samePicture(listOf(item("Hi", message.box)), listOf(item("Hi", nudged.box))))
    }

    @Test
    fun inkOnTheSameSideOfTheBubbleKeepsItsColor() {
        assertTrue(PhoneSteady.sameInk("#000000", "#584048", "#C8B0B8"))
        assertFalse(PhoneSteady.sameInk("#000000", "#FFFFFF", "#C8B0B8"))
        val before = item("Casa De Donnie", TextBox(0.65, 0.36, 0.77, 0.38)).copy(surface = TextSurface("#C8B0B8", "#000000"))
        val grey = before.copy(surface = TextSurface("#C8B0B8", "#584048"))
        assertEquals(before.surface, PhoneRegionSession.steady(listOf(grey), listOf(before))[0].surface)
    }

    @Test
    fun sideOfABubbleStaysWithItsIdentity() {
        val spot = TextBox(0.2, 0.2, 0.8, 0.3)
        val before = item("Casa De Donnie", TextBox(0.65, 0.36, 0.77, 0.38))
            .copy(phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.INCOMING, spot))
        val flipped = before.copy(phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.OUTGOING, spot))
        assertEquals(ScreenPhoneCard.Role.INCOMING, PhoneRegionSession.steady(listOf(flipped), listOf(before))[0].phone?.role)
    }

    @Test
    fun shortMessageWithPunctuationNoiseKeepsItsTranslation() {
        val known = mapOf("Ok." to "Tamam.", "Comprendo?" to "Anladın mı?")
        assertEquals("Tamam.", PhoneSteady.translation("ok", known))
        assertEquals("Anladın mı?", PhoneSteady.translation("Comprendo ?", known))
        assertNull(PhoneSteady.translation("Ok?", known))
        assertNull(PhoneSteady.translation("On", known))
        assertEquals("Yeni", PhoneSteady.translation("New rnessage", mapOf("New message" to "Yeni")))
    }

    // Yanda Panel'in yazı boyu ve yeri (#1152, GTA 6: "telefon titreyince panelin yazıları büyüyüp küçülüyor").

    private val still = GamePhoneGeometry.Pose(0.70, 0.19, 0.70, 0.87)

    private fun shaken(scale: Double = 1.0, dx: Double = 0.0, dy: Double = 0.0): GamePhoneGeometry.Pose {
        val cy = (still.topY + still.bottomY) / 2 + dy
        val half = (still.bottomY - still.topY) / 2 * scale
        return GamePhoneGeometry.Pose(still.topX + dx, cy - half, still.bottomX + dx, cy + half)
    }

    /** Yakın kamerada el titremesi: boy ±%8, ortası boyun ±%5'i; okunan satır yüksekliği ±%20. */
    private val shakes = listOf(
        doubleArrayOf(1.08, 0.004, -0.03, 1.2), doubleArrayOf(0.93, -0.006, 0.02, 0.82),
        doubleArrayOf(1.05, 0.003, 0.034, 1.15), doubleArrayOf(0.95, -0.002, -0.025, 0.85),
        doubleArrayOf(1.07, 0.005, 0.01, 1.18), doubleArrayOf(0.92, -0.004, -0.034, 0.8),
        doubleArrayOf(1.03, 0.006, 0.028, 1.1), doubleArrayOf(0.97, -0.006, -0.01, 0.9),
    )

    private fun chatItems(line: Double) = listOf(
        ScreenTranslation.Item("Where are you man", "Neredesin adamım bu saatte, herkes seni bekliyor",
            TextBox(0.75, 0.2, 0.9, 0.2 + line), line,
            phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.INCOMING, TextBox(0.1, 0.2, 0.8, 0.23))),
        ScreenTranslation.Item("On my way", "Yoldayım, beş dakikaya oradayım", TextBox(0.75, 0.4, 0.9, 0.4 + line), line,
            phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.OUTGOING, TextBox(0.1, 0.4, 0.8, 0.43))),
    )

    @Test
    fun panelKeepsItsSizeAndPlaceWhileThePhoneShakes() {
        val steady = PhonePanelSteady()
        val first = steady.steadyPose(still, 0)
        assertTrue(first.resized)
        assertEquals(0.02, steady.steadyLine(0.02, 0)!!, 0.0)
        val drawn = ScreenPhoneCard.layout(chatItems(0.02), ScreenPhoneCard.Handset(first.pose, 16.0 / 9), lockedLine = 0.02)
        shakes.forEachIndexed { turn, shake ->
            val now = (turn + 1) * 450L
            val placed = steady.steadyPose(shaken(shake[0], shake[1], shake[2]), now)
            assertEquals("tur $turn", still, placed.pose)
            assertFalse(placed.resized)
            val measured = ScreenPhoneCard.measuredLine(chatItems(0.02 * shake[3]))
            assertEquals(0.02 * shake[3], measured!!, 0.0)
            val line = steady.steadyLine(measured, now)
            assertEquals(0.02, line!!, 0.0)
            val laid = ScreenPhoneCard.layout(chatItems(0.02 * shake[3]), ScreenPhoneCard.Handset(placed.pose, 16.0 / 9),
                lockedLine = line)
            assertEquals("tur $turn", drawn, laid)
        }
    }

    @Test
    fun panelFollowsARealZoomAfterItLastsASecond() {
        val steady = PhonePanelSteady()
        steady.steadyPose(still, 0)
        steady.steadyLine(0.02, 0)
        val near = shaken(scale = 1.4)
        assertEquals(still, steady.steadyPose(near, 450).pose)
        assertEquals(still, steady.steadyPose(near, 900).pose)
        assertEquals(still, steady.steadyPose(still, 1350).pose)
        assertEquals(still, steady.steadyPose(near, 1800).pose)
        assertEquals(still, steady.steadyPose(near, 2250).pose)
        val zoomed = steady.steadyPose(near, 2800)
        assertEquals(near, zoomed.pose)
        assertTrue(zoomed.resized)
        assertEquals(0.028, steady.steadyLine(0.028, 2800)!!, 0.0)
        assertEquals(0.028, steady.steadyLine(0.025, 3250)!!, 0.0)
    }

    @Test
    fun panelFollowsARealMoveWithoutChangingItsTextSize() {
        val steady = PhonePanelSteady()
        steady.steadyPose(still, 0)
        steady.steadyLine(0.02, 0)
        val moved = shaken(dx = -0.2)
        assertEquals(still, steady.steadyPose(moved, 450).pose)
        val placed = steady.steadyPose(moved, 1450)
        assertEquals(moved, placed.pose)
        assertFalse(placed.resized)
        assertEquals(0.02, steady.steadyLine(0.023, 1450)!!, 0.0)
        assertEquals(moved, steady.steadyPose(shaken(1.06, -0.196, 0.02), 1900).pose)
    }

    @Test
    fun wrongFirstTextSizeIsCorrectedOnlyWhenTheNewSizeLasts() {
        val steady = PhonePanelSteady()
        assertEquals(0.014, steady.steadyLine(0.014, 0)!!, 0.0)
        assertEquals(0.014, steady.steadyLine(null, 200)!!, 0.0)
        assertEquals(0.014, steady.steadyLine(0.021, 450)!!, 0.0)
        assertEquals(0.014, steady.steadyLine(0.015, 900)!!, 0.0)
        assertEquals(0.014, steady.steadyLine(0.021, 1350)!!, 0.0)
        assertEquals(0.014, steady.steadyLine(0.022, 2000)!!, 0.0)
        assertEquals(0.021, steady.steadyLine(0.021, 2400)!!, 0.0)
        steady.reset()
        assertNull(steady.line)
        assertTrue(steady.steadyPose(shaken(dx = 0.1), 2500).resized)
    }
}
