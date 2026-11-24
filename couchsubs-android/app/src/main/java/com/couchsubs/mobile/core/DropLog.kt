// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Metin hattında bir satırın neden düşürüldüğü, bekletildiği ya da çevrilmediği: altyazı günlüğüne kısa, sınırlı bir
 * satır. Biçim: `düşen satır [Bileşen] neden: "metnin ilk 30 karakteri"`. Kullanıcı bildirimlerinde (GTA 6 telefon
 * mesajı bir kez çevrilip duruyor, görev satırı İngilizce kalıyor, periyodik kopmalar) hangi bileşenin satırı bıraktığı
 * günlükte görünsün diye. Gürültü yapmaz: aynı bileşen + neden + metin [REPEAT_MS] içinde yeniden yazılmaz; bir dakikada
 * en çok [PER_MINUTE] satır yazılır, aşan satırlar sayılır ve sonraki yazılan satırın sonunda bildirilir. Yalnız metin
 * yazılır; ekran karesi ya da görüntü yazılmaz. Mac/iPhone (DropLog.swift) ve Windows (DropLog.cs) aynı biçim, aynı sınırlar.
 *
 * [sink]: verilmezse uygulamanın kurduğu [DropLog.sink] (TranslationService logcat'e yazar; testlerde boş, hiçbir şey yazılmaz).
 */
class DropLog(private val clock: () -> Long = monotonicClock, private val sink: ((String) -> Unit)? = null) {
    private val seen = HashMap<String, Long>()
    private var windowStart: Long? = null
    private var written = 0
    private var suppressed = 0

    /** Yazılacak günlük satırı; aynı satır yakın zamanda yazıldıysa ya da dakikalık sınır dolduysa null. */
    @Synchronized
    fun line(component: String, reason: String, text: String): String? {
        val excerpt = logExcerpt(text, EXCERPT_LENGTH)
        val key = "$component|$reason|$excerpt"
        val time = clock()
        seen[key]?.let { if (time - it < REPEAT_MS) return null }
        val start = windowStart
        if (start != null && time - start < 60_000) {
            if (written >= PER_MINUTE) {
                suppressed++
                return null
            }
        } else {
            windowStart = time
            written = 0
        }
        written++
        seen[key] = time
        if (seen.size > MEMORY) {
            seen.entries.removeAll { time - it.value >= REPEAT_MS }
            if (seen.size > MEMORY) {
                seen.clear()
                seen[key] = time
            }
        }
        var line = "düşen satır [$component] $reason: $excerpt"
        if (suppressed > 0) {
            line += " (+$suppressed satır sınır yüzünden yazılmadı)"
            suppressed = 0
        }
        return line
    }

    /** Satırı (yazılacaksa) [log]'a, yoksa kurulurken verilen ya da uygulamanın günlüğüne yazar. */
    fun note(component: String, reason: String, text: String, log: ((String) -> Unit)? = null) {
        val line = line(component, reason, text) ?: return
        (log ?: sink ?: DropLog.sink)?.invoke(line)
    }

    companion object {
        /** Alıntının en uzun hâli (karakter). */
        const val EXCERPT_LENGTH = 30
        /** Aynı bileşen + neden + metin bu süre içinde yeniden yazılmaz. */
        const val REPEAT_MS = 60_000L
        /** Bir dakikada en çok yazılan satır. */
        const val PER_MINUTE = 20
        /** Hatırlanan en çok satır anahtarı (bellek sınırı). */
        const val MEMORY = 256

        /** Bileşenin kendi günlüğü yoksa satırların gittiği yer; uygulama açılışta kurar (Mac/iPhone `SubtitleLog`). */
        @Volatile var sink: ((String) -> Unit)? = null
    }
}
