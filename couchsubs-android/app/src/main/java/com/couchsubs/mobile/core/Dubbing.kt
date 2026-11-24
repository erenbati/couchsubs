// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import java.text.Normalizer
import java.util.Locale

/**
 * Türkçe dublaj sesleri: masaüstündeki Pocket TTS seslerinin adları (Mac/iPhone VoiceCast.swift, Windows VoiceCast.cs).
 * Telefonda sesler telefonun kendi Türkçe sesidir (TextToSpeech; Windows'taki "Hızlı" dublaj); karakterler ton ve hızla
 * ayrılır ([pitch], [rate]; Windows WindowsVoiceModel.Tone ve Swift DubbingVoice.systemTone ile aynı değerler).
 */
enum class DubbingVoice(val id: String, val female: Boolean, val pitch: Float, val rate: Float) {
    FEMALE_1("female_1", true, 1.55f, 1.1f),
    FEMALE_2("female_2", true, 1.4f, 1.0f),
    FEMALE_3("female_3", true, 1.48f, 1.05f),
    MALE_1("male_1", false, 0.85f, 0.95f),
    MALE_2("male_2", false, 1.05f, 1.15f),
    MALE_3("male_3", false, 0.95f, 1.05f);

    companion object {
        fun of(id: String?): DubbingVoice? = entries.firstOrNull { it.id == id }
    }
}

/** Dublajın çalacağı yer: TV uygulaması ya da bu telefon (Swift DubbingOutput: tv / computer). */
enum class DubbingOutput(val id: String) {
    TV("tv"), PHONE("computer");

    companion object {
        fun of(id: String?): DubbingOutput = entries.firstOrNull { it.id == id } ?: TV
    }
}

/** Seslendirilecek bir cümle (Swift SpokenLine). */
data class SpokenLine(val english: String, val turkish: String, val speaker: String? = null, val newTurn: Boolean = false) {
    companion object {
        /**
         * Gösterilen satırın cümleleri: konuşan adı İngilizceden alınır ("ARTHUR: …"), Türkçedeki ad atılır; tireyle
         * başlayan satır yeni konuşmadır ("- Gidelim." / "- Bekle!").
         */
        fun of(source: String, translation: String): List<SpokenLine> {
            val speaker = SpeakerPrefix.split(source)?.name
            val text = if (speaker != null) SpeakerPrefix.split(translation)?.takeIf { it.name == speaker }?.body ?: translation else translation
            return text.split('\n').map { it.trim() }.filter { line -> line.any { it.isLetter() } }.map { line ->
                val dash = line.first() in "-–—"
                SpokenLine(source, if (dash) line.drop(1).trim() else line, if (dash) null else speaker, dash)
            }
        }
    }
}

/**
 * Karakterlere ses dağıtır (Swift VoiceCast ile aynı kural): her ad kalıcı olarak bir sese bağlanır; etiketsiz satırlar
 * anlatıcı sesiyle, tireyle değişen konuşmalar anlatıcı ve ikinci konuşan arasında sırayla okunur. Adından cinsiyeti
 * anlaşılmayan karakter kullanıcının seçtiği "Tanınmayan karakterlerin sesi"yle konuşur ([unknownFemale], varsayılan
 * erkek). Eskiden bilinmeyen ada altı sesin en az kullanılanı verilirdi; sıralamada kadın sesleri önde olduğundan listede
 * olmayan ilk üç karakter (GTA 6'da Jason, Cal, Boobie…) kadın sesiyle konuşuyordu. Ortak deneme dosyası:
 * fixtures/voice-cast.json.
 */
class VoiceCast(
    assignments: Map<String, DubbingVoice> = emptyMap(),
    var narrator: DubbingVoice = DubbingVoice.MALE_1,
    var partner: DubbingVoice = DubbingVoice.MALE_2,
    unknownFemale: Boolean = false,
) {
    private val map = LinkedHashMap(assignments)
    private var lastWasPartner = false

    /** Adından cinsiyeti anlaşılmayan yeni karakterin sesi kadın mı (Swift unknownGender). */
    var unknownFemale: Boolean = unknownFemale
        private set

    val assignments: Map<String, DubbingVoice> get() = map.toMap()

    /** Satırın sesi; yeni bir ad ilk kez görülünce ona bir ses ayrılır. */
    fun voiceFor(line: SpokenLine): DubbingVoice {
        line.speaker?.let { speaker ->
            lastWasPartner = false
            val key = key(speaker)
            map[key]?.let { return it }
            return pick(NameGender.guess(speaker) ?: unknownFemale).also { map[key] = it }
        }
        if (line.newTurn) lastWasPartner = !lastWasPartner
        return if (lastWasPartner) partner else narrator
    }

    fun assign(voice: DubbingVoice, name: String) { map[key(name)] = voice }

    /**
     * "Tanınmayan karakterlerin sesi". Anlatıcı ve tireli konuşmanın ikinci sesi de bu cinsiyette değilse o cinsiyetin
     * seslerine geçer (adı yazmayan satırın kim olduğu da bilinmez). Atanmış karakterlerin sesi değişmez.
     */
    fun setUnknownGender(female: Boolean) {
        unknownFemale = female
        val voices = DubbingVoice.entries.filter { it.female == female }
        if (narrator.female != female) narrator = voices[0]
        if (partner.female != female) partner = voices.first { it != narrator }
    }

    /**
     * Kural 1 → 2: eski varsayılan ikinci ses (Kadın 1) erkek sese döner; adından cinsiyeti anlaşılan karaktere karşı
     * cinsiyetten verilmiş ses ve tanınmayan ada verilmiş kadın sesi (eski sıralı dağıtımın izi) yeniden seçilir.
     */
    private fun upgradeRules() {
        if (narrator == DubbingVoice.MALE_1 && partner == DubbingVoice.FEMALE_1) partner = DubbingVoice.MALE_2
        val wrong = map.filter { (name, voice) -> (NameGender.guess(name) ?: unknownFemale) != voice.female }.keys.sorted()
        for (name in wrong) map.remove(name)
        for (name in wrong) map[name] = pick(NameGender.guess(name) ?: unknownFemale)
    }

    /** Yeni karakter için bu cinsiyetin en az kullanılan sesi; anlatıcı sesi en sona kalır. */
    private fun pick(female: Boolean): DubbingVoice {
        val candidates = DubbingVoice.entries.filter { it.female == female }
        val uses = HashMap<DubbingVoice, Int>()
        for (voice in map.values) uses[voice] = (uses[voice] ?: 0) + 1
        // Anlatıcı sesi en sona kalsın: etiketsiz satırlarla karışmasın.
        uses[narrator] = (uses[narrator] ?: 0) + 1
        return candidates.minWith(compareBy<DubbingVoice> { uses[it] ?: 0 }.thenBy { it.ordinal })
    }

    fun toJson(): String = JSONObject()
        .put("narrator", narrator.id).put("partner", partner.id)
        .put("unknownGender", if (unknownFemale) "female" else "male").put("rules", RULES)
        .put("assignments", JSONObject().apply { map.forEach { (name, voice) -> put(name, voice.id) } })
        .toString()

    companion object {
        /** Kaydın kural sürümü (Swift VoiceCast.rules). Daha eski kayıtta yanlış cinsiyetle verilmiş sesler düzeltilir. */
        const val RULES = 2

        fun key(name: String): String = name.uppercase(Locale.US)

        fun fromJson(text: String?): VoiceCast {
            if (text.isNullOrBlank()) return VoiceCast()
            return try {
                val json = JSONObject(text)
                val assigned = json.optJSONObject("assignments")
                val map = LinkedHashMap<String, DubbingVoice>()
                assigned?.keys()?.forEach { name -> DubbingVoice.of(assigned.optString(name))?.let { map[name] = it } }
                val cast = VoiceCast(map, DubbingVoice.of(json.optString("narrator")) ?: DubbingVoice.MALE_1,
                    DubbingVoice.of(json.optString("partner")) ?: DubbingVoice.MALE_2,
                    json.optString("unknownGender") == "female")
                if (json.optInt("rules", 1) < RULES) cast.upgradeRules()
                cast
            } catch (error: org.json.JSONException) {
                VoiceCast()
            }
        }
    }
}

/**
 * Addan cinsiyet tahmini (Swift NameGender ile aynı liste): oyun karakterleri (God of War, The Last of Us, GTA 6, GTA V,
 * RDR2, Cyberpunk 2077, The Witcher …), yaygın İngilizce, İspanyolca ve Türkçe adlar, unvanlar. Ad küçük harfe ve aksansız
 * biçime çevrilir ("AYŞE" → "ayse", "Dre'Quan" → "drequan"). Bilinmeyen ad null döner (true: kadın).
 */
object NameGender {
    private val female = setOf(
        "freya", "faye", "angrboda", "sif", "thrud", "ellie", "abby", "dina", "tess", "marlene", "riley", "aloy",
        "elisabet", "beta", "mary", "jane", "mj", "may", "rio", "hailey", "lara", "jill", "claire", "ada", "ashley",
        "tifa", "aerith", "yuffie", "jessie", "yuna", "lulu", "rikku", "ciri", "yennefer", "triss", "kassandra", "aya",
        "evie", "lydia", "anna", "emma", "olivia", "sophia", "isabella", "mia", "amelia", "harper", "evelyn",
        "abigail", "emily", "ella", "elizabeth", "sofia", "avery", "scarlett", "grace", "chloe", "victoria", "lily",
        "hannah", "zoe", "nora", "sarah", "rachel", "rebecca", "laura", "julia", "maria", "kate", "katie", "lucy",
        "alice", "eve", "helen", "linda", "susan", "karen", "nancy", "lisa", "betty", "margaret", "sandra", "kim",
        "mother", "mom", "mum", "queen", "princess", "lady", "girl", "woman", "sister", "aunt", "grandma", "witch",
        "goddess", "daughter", "wife", "lucia", "roxy", "amanda", "tracey", "tracy", "denise", "tanisha", "patricia",
        "molly", "maude", "debra", "tonya", "beverly", "sadie", "tilly", "beth", "edith", "beatrice", "catherine",
        "bonnie", "judy", "panam", "misty", "jessica", "jennifer", "amy", "melissa", "michelle", "stephanie", "nicole",
        "heather", "elena", "natalie", "samantha", "megan", "amber", "brittany", "danielle", "diana", "donna", "carol",
        "ruth", "sharon", "cynthia", "kathleen", "angela", "pamela", "martha", "debbie", "barbara", "dorothy", "ivy",
        "rose", "ruby", "daisy", "stella", "luna", "penelope", "violet", "aurora", "natasha", "nina", "vanessa",
        "monica", "jasmine", "jade", "kara", "clementine", "maya", "leah", "naomi", "tina", "wendy", "ana", "carmen",
        "rosa", "isabel", "valentina", "gabriela", "camila", "paula", "marta", "daniela", "alejandra", "anne", "mrs",
        "ms", "miss", "madam", "ayse", "fatma", "emine", "hatice", "zeynep", "elif", "meryem", "merve", "busra",
        "esra", "ozlem", "selin", "ece", "derya", "gul", "aylin", "ebru", "sevgi", "melek", "asli", "defne", "yasemin",
        "hulya", "sibel", "songul", "filiz", "dilek", "gamze", "tugba", "seda", "pinar", "irem", "buse", "cansu",
        "damla", "ceren", "nazli", "sena", "kubra", "rabia", "hacer", "sevda", "leyla", "nermin", "zehra", "gulsen",
        "hande", "bahar", "didem", "eda", "beren", "nisa", "azra", "ela", "anneanne", "babaanne", "abla", "kiz",
        "kadin", "hanim", "teyze", "hala", "kralice", "prenses",
    )
    private val male = setOf(
        "kratos", "atreus", "mimir", "baldur", "thor", "odin", "brok", "sindri", "tyr", "heimdall", "freyr", "durlin",
        "joel", "tommy", "bill", "henry", "jesse", "lev", "isaac", "owen", "manny", "jerry", "rost", "erend", "varl",
        "sylens", "kotallo", "peter", "miles", "harry", "otto", "kraven", "venom", "norman", "aaron", "ganke", "leon",
        "chris", "albert", "wesker", "ethan", "cloud", "barret", "zack", "sephiroth", "noctis", "tidus", "auron",
        "geralt", "jaskier", "alexios", "bayek", "ezio", "altair", "connor", "edward", "arthur", "dutch", "john",
        "micah", "hosea", "nathan", "nate", "drake", "sully", "jin", "khotun", "deacon", "boozer", "james", "robert",
        "michael", "william", "david", "richard", "joseph", "thomas", "charles", "daniel", "matthew", "anthony",
        "mark", "paul", "steven", "andrew", "kenneth", "kevin", "brian", "george", "jack", "jacob", "luke", "max",
        "father", "dad", "boy", "king", "prince", "lord", "sir", "man", "brother", "uncle", "grandpa", "son",
        "husband", "soldier", "guard", "captain", "commander", "general", "jason", "cal", "boobie", "drequan", "raul",
        "franklin", "trevor", "lamar", "lester", "jimmy", "dave", "steve", "wade", "ron", "chop", "devin", "simeon",
        "floyd", "stretch", "martin", "fabien", "solomon", "josh", "nigel", "gerald", "javier", "lenny", "sean",
        "kieran", "pearson", "swanson", "strauss", "trelawny", "josiah", "leopold", "reverend", "simon", "bronte",
        "colm", "cornwall", "milton", "marston", "johnny", "jackie", "takemura", "kerry", "viktor", "dexter", "goro",
        "saul", "vesemir", "lambert", "eskel", "regis", "justin", "brandon", "ryan", "tyler", "adam", "eric",
        "jonathan", "stephen", "larry", "frank", "scott", "gregory", "raymond", "patrick", "dennis", "walter",
        "harold", "douglas", "carl", "arnold", "roger", "joe", "juan", "carlos", "luis", "jose", "miguel", "antonio",
        "diego", "pablo", "marco", "ricardo", "jorge", "victor", "oscar", "tony", "nick", "mike", "bob", "tom", "ben",
        "dan", "phil", "ray", "rick", "shawn", "leo", "oliver", "noah", "liam", "logan", "lucas", "mason", "elijah",
        "alexander", "sebastian", "benjamin", "samuel", "gabriel", "julian", "carter", "wyatt", "dylan", "hunter",
        "eli", "marcus", "troy", "vince", "vincent", "sergio", "manuel", "rafael", "sal", "salvatore", "nico", "niko",
        "roman", "claude", "cj", "ryder", "mr", "ahmet", "ahmed", "mehmet", "mustafa", "ali", "hasan", "huseyin",
        "ibrahim", "ismail", "osman", "murat", "emre", "burak", "can", "kemal", "yusuf", "omer", "halil", "mahmut",
        "recep", "ramazan", "kadir", "serkan", "cem", "cengiz", "selim", "hakan", "sinan", "yasin", "eren", "efe",
        "arda", "kerem", "baris", "onur", "tolga", "volkan", "ugur", "umut", "furkan", "enes", "oguz", "erkan",
        "fatih", "levent", "tarik", "kaan", "orhan", "erdem", "emir", "berk", "yigit", "suleyman", "abdullah", "bekir",
        "veli", "kenan", "metin", "gokhan", "ozan", "bora", "tayfun", "baba", "dede", "amca", "dayi", "abi", "agabey",
        "oglan", "bey", "efendi", "kral", "prens", "asker", "komutan",
    )

    fun guess(name: String): Boolean? {
        val words = words(name)
        if (words.isEmpty()) return null
        val whole = words.joinToString(" ")
        if (whole in female) return true
        if (whole in male) return false
        // Çok sözcüklü adda sözcüklere bakılır ("OLD MAN", "Mary-Beth", "Mr. Wilson", "Guard Captain").
        for (word in words) {
            if (word in female) return true
            if (word in male) return false
        }
        return null
    }

    /** Adın sözcükleri: küçük harf, aksan ve kesme işareti atılmış, "ı" → "i"; harf dışındaki her şey ayırır. */
    fun words(name: String): List<String> {
        val folded = Normalizer.normalize(name.lowercase(Locale.ROOT), Normalizer.Form.NFD)
            .replace(MARKS, "").replace('ı', 'i')
        return folded.split(NON_LETTERS).filter { it.isNotEmpty() }
    }

    private val MARKS = Regex("[\\p{M}'’]")
    private val NON_LETTERS = Regex("[^\\p{L}]+")
}
