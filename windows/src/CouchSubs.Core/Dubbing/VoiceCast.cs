// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text;
using System.Text.Json.Serialization;

namespace CouchSubs.Core.Dubbing;

/// <summary>Dublaj sesleri: Pocket TTS Turkish'in hazır sesleri (yapay, gerçek kişi değil).</summary>
[JsonConverter(typeof(JsonStringEnumConverter<DubbingVoice>))]
public enum DubbingVoice { Female1, Female2, Female3, Male1, Male2, Male3 }

[JsonConverter(typeof(JsonStringEnumConverter<VoiceGender>))]
public enum VoiceGender { Female, Male }

public static class DubbingVoices
{
    public static readonly DubbingVoice[] All = Enum.GetValues<DubbingVoice>();

    /// <summary>Modeldeki dosya adı ("female_1").</summary>
    public static string FileName(this DubbingVoice voice) => voice switch
    {
        DubbingVoice.Female1 => "female_1",
        DubbingVoice.Female2 => "female_2",
        DubbingVoice.Female3 => "female_3",
        DubbingVoice.Male1 => "male_1",
        DubbingVoice.Male2 => "male_2",
        _ => "male_3",
    };

    public static VoiceGender Gender(this DubbingVoice voice) =>
        voice is DubbingVoice.Female1 or DubbingVoice.Female2 or DubbingVoice.Female3 ? VoiceGender.Female : VoiceGender.Male;

    public static DubbingVoice[] Of(VoiceGender gender) => All.Where(voice => voice.Gender() == gender).ToArray();
}

/// <summary>
/// Karakterlere ses dağıtır (Mac: VoiceCast.swift, Android: Dubbing.kt). Her konuşmacı adı kalıcı olarak bir sese bağlanır;
/// etiketsiz satırlar anlatıcı sesiyle, tireyle değişen konuşmalar iki ses arasında sırayla okunur. Adından cinsiyeti
/// anlaşılmayan karakter kullanıcının seçtiği "Tanınmayan karakterlerin sesi"yle konuşur (varsayılan erkek). Eskiden
/// bilinmeyen ada altı sesin en az kullanılanı verilirdi; sıralamada kadın sesleri önde olduğundan listede olmayan ilk üç
/// karakter (GTA 6'da Jason, Cal, Boobie…) kadın sesiyle konuşuyordu. Ortak deneme dosyası:
/// core/Tests/CouchSubsCoreTests/Fixtures/voice-cast.json.
/// </summary>
public sealed class VoiceCast : IJsonOnDeserialized
{
    /// <summary>Kaydın kural sürümü. Daha eski kayıtta yanlış cinsiyetle verilmiş sesler bir kez düzeltilir.</summary>
    public const int CurrentRules = 2;

    /// <summary>Adın büyük harfli biçimi → ses. Ayarlardan değiştirilebilir.</summary>
    public Dictionary<string, DubbingVoice> Assignments { get; init; } = new(StringComparer.Ordinal);
    public DubbingVoice Narrator { get; set; } = DubbingVoice.Male1;
    /// <summary>Tireli konuşmada sıradaki kişinin sesi.</summary>
    public DubbingVoice Partner { get; set; } = DubbingVoice.Male2;
    /// <summary>Adından cinsiyeti anlaşılmayan yeni karakterin sesi (Ayarlar › Türkçe dublaj).</summary>
    public VoiceGender UnknownGender { get; set; } = VoiceGender.Male;

    /// <summary>Kayda her zaman güncel sürüm yazılır; okunan eski kayıtta yoktur (0).</summary>
    public int Rules
    {
        get => CurrentRules;
        init => _loadedRules = value;
    }

    /// <summary>Okunan kaydın sürümü; alanı olmayan eski kayıtta 0 kalır (yeni nesnede kullanılmaz).</summary>
    private int _loadedRules;
    private bool _lastWasPartner;

    void IJsonOnDeserialized.OnDeserialized()
    {
        if (_loadedRules < CurrentRules) UpgradeRules();
    }

    public static string Key(string name) => name.ToUpperInvariant();

    /// <summary>Satırın sesi; yeni bir ad ilk kez görülünce ona bir ses ayrılır (değişti: true).</summary>
    public DubbingVoice VoiceFor(SpokenLine line, out bool assigned)
    {
        assigned = false;
        if (line.Speaker is { } speaker)
        {
            _lastWasPartner = false;
            var key = Key(speaker);
            if (Assignments.TryGetValue(key, out var known)) return known;
            var voice = Pick(NameGender.Guess(speaker) ?? UnknownGender);
            Assignments[key] = voice;
            assigned = true;
            return voice;
        }
        if (line.NewTurn) _lastWasPartner = !_lastWasPartner;
        return _lastWasPartner ? Partner : Narrator;
    }

    public void Assign(DubbingVoice voice, string name) => Assignments[Key(name)] = voice;

    /// <summary>
    /// "Tanınmayan karakterlerin sesi". Anlatıcı ve tireli konuşmanın ikinci sesi de bu cinsiyette değilse o cinsiyetin
    /// seslerine geçer (adı yazmayan satırın kim olduğu da bilinmez). Atanmış karakterlerin sesi değişmez.
    /// </summary>
    public void SetUnknownGender(VoiceGender gender)
    {
        UnknownGender = gender;
        var voices = DubbingVoices.Of(gender);
        if (Narrator.Gender() != gender) Narrator = voices[0];
        if (Partner.Gender() != gender) Partner = voices.First(voice => voice != Narrator);
    }

    public VoiceCast Copy() => new()
    {
        Assignments = new Dictionary<string, DubbingVoice>(Assignments, StringComparer.Ordinal),
        Narrator = Narrator,
        Partner = Partner,
        UnknownGender = UnknownGender,
    };

    /// <summary>
    /// Kural 1 → 2: eski varsayılan ikinci ses (Kadın 1) erkek sese döner; adından cinsiyeti anlaşılan karaktere karşı
    /// cinsiyetten verilmiş ses ve tanınmayan ada verilmiş kadın sesi (eski sıralı dağıtımın izi) yeniden seçilir.
    /// </summary>
    private void UpgradeRules()
    {
        if (Narrator == DubbingVoice.Male1 && Partner == DubbingVoice.Female1) Partner = DubbingVoice.Male2;
        var wrong = Assignments.Where(pair => (NameGender.Guess(pair.Key) ?? UnknownGender) != pair.Value.Gender())
            .Select(pair => pair.Key).Order(StringComparer.Ordinal).ToList();
        foreach (var name in wrong) Assignments.Remove(name);
        foreach (var name in wrong) Assignments[name] = Pick(NameGender.Guess(name) ?? UnknownGender);
        _loadedRules = CurrentRules;
    }

    /// <summary>Yeni karakter için bu cinsiyetin en az kullanılan sesi; anlatıcı sesi en sona kalır.</summary>
    private DubbingVoice Pick(VoiceGender gender)
    {
        var uses = DubbingVoices.All.ToDictionary(voice => voice, _ => 0);
        foreach (var voice in Assignments.Values) uses[voice]++;
        uses[Narrator]++;
        return DubbingVoices.All
            .Where(voice => voice.Gender() == gender)
            .OrderBy(voice => uses[voice]).ThenBy(voice => (int)voice)
            .First();
    }
}

/// <summary>
/// Addan cinsiyet tahmini (Mac ve Android ile aynı liste): oyun karakterleri (God of War, The Last of Us, GTA 6, GTA V,
/// RDR2, Cyberpunk 2077, The Witcher …), yaygın İngilizce, İspanyolca ve Türkçe adlar, unvanlar. Ad küçük harfe ve
/// aksansız biçime çevrilir ("AYŞE" → "ayse", "Dre'Quan" → "drequan"); bilinmeyen ad null döner.
/// </summary>
public static class NameGender
{
    private static readonly HashSet<string> Female = new(StringComparer.Ordinal)
    {
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
    };

    private static readonly HashSet<string> Male = new(StringComparer.Ordinal)
    {
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
    };

    public static VoiceGender? Guess(string name)
    {
        var words = Words(name);
        if (words.Count == 0) return null;
        var whole = string.Join(' ', words);
        if (Female.Contains(whole)) return VoiceGender.Female;
        if (Male.Contains(whole)) return VoiceGender.Male;
        // Çok sözcüklü adda sözcüklere bakılır ("OLD MAN", "Mary-Beth", "Mr. Wilson", "Guard Captain").
        foreach (var word in words)
        {
            if (Female.Contains(word)) return VoiceGender.Female;
            if (Male.Contains(word)) return VoiceGender.Male;
        }
        return null;
    }

    /// <summary>
    /// Adın sözcükleri: küçük harf, aksan ve kesme işareti atılmış, "ı" → "i"; harf dışındaki her şey ayırır. Önce ayrıştırılır:
    /// .NET küçük harfe çevirirken "İ"yi olduğu gibi bırakır, ayrıştırınca "I" + nokta olur.
    /// </summary>
    public static List<string> Words(string name)
    {
        var words = new List<string>();
        var current = new StringBuilder();
        foreach (var c in name.Normalize(NormalizationForm.FormD).ToLowerInvariant())
        {
            var category = CharUnicodeInfo.GetUnicodeCategory(c);
            if (category is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
                || c is '\'' or '’') continue;
            if (char.IsLetter(c)) current.Append(c == 'ı' ? 'i' : c);
            else if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) words.Add(current.ToString());
        return words;
    }
}
