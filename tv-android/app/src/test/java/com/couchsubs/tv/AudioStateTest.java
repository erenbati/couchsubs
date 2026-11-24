// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.tv;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class AudioStateTest {
    @Test
    public void avReceiverOnArcIsShownWithRoute() {
        // Hi-Level + AV yükseltici: TV hoparlörü ve ARC bağlı, medya ARC'a gidiyor, TvView bir ses parçası bildirdi.
        assertEquals("snd v7/15 out spk,arc to arc atr 1/1",
                AudioState.text(7, 15, false, new int[] {2, 10}, new int[] {10}, 1, true));
    }

    @Test
    public void mutedNoTracksOldAndroid() {
        // Android 12 ve öncesi: gidilen çıkış bilinmez; TvView ses parçası bildirmedi.
        assertEquals("snd v0/100 muted out earc,bt",
                AudioState.text(0, 100, true, new int[] {29, 8, 29}, null, -1, false));
        assertEquals("snd out - to - atr 0/0", AudioState.text(0, 0, false, new int[0], new int[0], 0, false));
    }

    @Test
    public void unknownDeviceTypeKeepsNumber() {
        assertEquals("t99", AudioState.deviceName(99));
        assertEquals("spdif", AudioState.deviceName(14));
    }
}
