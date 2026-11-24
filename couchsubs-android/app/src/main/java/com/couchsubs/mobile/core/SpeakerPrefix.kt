// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale

/**
 * Altyazının başındaki konuşan adı ("ARTHUR: We need to go.", "Dutch：Easy."). Ad çeviriye gitmez: motorlar adı
 * çeviriyor ya da cümlenin içine katıyordu, paket anahtarı da çoğu zaman adsız tutuluyor. Hat önce adlı satırı, sonra
 * adsız cümleyi pakette arar; motora yalnız cümle gider, ad gösterirken geri eklenir ya da (ayar kapalıysa) atılır.
 * Mac/iPhone (SpeakerPrefix.swift) ve Windows (SpeakerPrefix.cs) aynı kuralları uygular.
 */
object SpeakerPrefix {
    data class Split(val name: String, val body: String)

    const val MAX_NAME_LENGTH = 24

    /** En çok üç sözcük, her sözcük büyük harfle başlar (BÜYÜK HARF ya da Baş Harf Büyük), rakam yok; ardından ":" ya da "：". */
    private val pattern = Regex("^(\\p{Lu}[\\p{L}'’.\\-]*(?: \\p{Lu}[\\p{L}'’.\\-]*){0,2}) ?[:：]\\s*")

    /** Baştaki konuşan adı ve cümle; ad yoksa (saat "10:30", adres "https://", oran "16:9", "Note:" gibi başlıklar) null. */
    fun split(text: String): Split? {
        val trimmed = text.trim()
        val match = pattern.find(trimmed) ?: return null
        val name = match.groupValues[1]
        val body = trimmed.substring(match.range.last + 1).trim()
        if (!isName(name)) return null
        if (body.none { it.isLetter() } || body.startsWith("/")) return null
        return Split(name, body)
    }

    /**
     * Tek başına okunan konuşan adı ("Lucia:", "JASON :"): ardında cümle yok; ad değilse ("Note:", "10:") null. Yazı
     * tanıma renkli adı cümleden ayrı satır okuyabiliyor; ad cümleye katılmazsa düşüyordu ([Reading.joiningRows]).
     * Mac (SpeakerPrefix.nameOnly) ve Windows (SpeakerPrefix.NameOnly) ile aynı.
     */
    fun nameOnly(text: String): String? {
        val trimmed = text.trim()
        val match = pattern.find(trimmed) ?: return null
        if (match.range.last + 1 != trimmed.length) return null
        val name = match.groupValues[1]
        return if (isName(name)) name else null
    }

    /** Ad uzunluğu aşılmamış ve tek sözcükse oyun başlığı ("Note", "Objective") değil. */
    private fun isName(name: String): Boolean =
        name.length <= MAX_NAME_LENGTH && (name.contains(' ') || name.lowercase(Locale.ROOT) !in SubtitleSegmenter.notNames)

    /**
     * Gösterilecek metin: çeviri [source]'un baştaki adıyla başlar ("ARTHUR: Gitmeliyiz."); [show] kapalıysa İngilizcede
     * konuşan adı olan satır başları atılır, yalnız Türkçe cümle kalır ("Hedef: …" gibi Türkçe başlık kalır).
     */
    fun present(translation: String, source: String, show: Boolean): String {
        var text = translation
        val prefix = split(source)
        if (prefix != null && split(text)?.name != prefix.name) text = "${prefix.name}: $text"
        if (show) return text
        val names = source.split('\n').mapNotNull { split(it)?.name }.toSet() + listOfNotNull(prefix?.name)
        return text.split('\n').joinToString("\n") { line ->
            val found = split(line)
            if (found != null && found.name in names) found.body else line
        }
    }
}
