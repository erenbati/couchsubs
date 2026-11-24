// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1202: telefon çevirisi kapalıyken telefon listesi altyazı yolunda sahne yazısı sayılınca oturumda bir kez ipucu
 * (Mac/iPhone ve Windows ile aynı durumlar).
 */
class GamePhoneHintTest {
    @Test
    fun phoneListReasonsAreRecognised() {
        assertTrue(GamePhoneHint.isPhoneList("eğik satır (tabela)"))
        assertTrue(GamePhoneHint.isPhoneList(InkTone.REASON))
        assertFalse(GamePhoneHint.isPhoneList("harfsiz sayı"))
        assertFalse(GamePhoneHint.isPhoneList("karenin ortasında kısa satır"))
    }

    @Test
    fun hintIsOfferedOncePerSessionOnlyInGta6WithThePhoneOff() {
        val hint = GamePhoneHint()
        assertFalse(hint.observe("eğik satır (tabela)", readsPhone = true, game = "GTA 6"))
        assertFalse(hint.observe("eğik satır (tabela)", readsPhone = false, game = "Red Dead Redemption 2"))
        assertFalse(hint.observe("eğik satır (tabela)", readsPhone = false, game = null))
        assertFalse(hint.observe("harfsiz sayı", readsPhone = false, game = "GTA 6"))
        assertTrue(hint.observe("eğik satır (tabela)", readsPhone = false, game = "GTA 6"))
        assertTrue(hint.offered)
        assertFalse(hint.observe(InkTone.REASON, readsPhone = false, game = "GTA 6"))
        hint.reset()
        assertTrue(hint.observe(InkTone.REASON, readsPhone = false, game = "GTA 6"))
    }
}
