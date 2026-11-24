// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Dublaj sesleri: Pocket TTS Turkish'in hazır sesleri (yapay, gerçek kişi değil).
public enum DubbingVoice: String, CaseIterable, Codable, Sendable {
    case female1 = "female_1", female2 = "female_2", female3 = "female_3"
    case male1 = "male_1", male2 = "male_2", male3 = "male_3"

    public enum Gender: String, CaseIterable, Codable, Sendable { case female, male }

    public var gender: Gender { rawValue.hasPrefix("female") ? .female : .male }

    public static func voices(_ gender: Gender) -> [DubbingVoice] { allCases.filter { $0.gender == gender } }

    /// Cihazın kendi Türkçe sesiyle ("Hızlı" dublaj: Windows'ta Microsoft Tolga, iPhone'da AVSpeechSynthesizer, Android'de
    /// TextToSpeech) karakterler ton ve hızla ayrılır; cihazda çoğunlukla tek Türkçe ses vardır. 1 = sesin kendi tonu ve
    /// hızı. Windows WindowsVoiceModel.Tone ve Android DubbingVoice.tone ile aynı değerler.
    public var systemTone: (pitch: Double, rate: Double) {
        switch self {
        case .female1: (1.55, 1.1)
        case .female2: (1.4, 1.0)
        case .female3: (1.48, 1.05)
        case .male1: (0.85, 0.95)
        case .male2: (1.05, 1.15)
        case .male3: (0.95, 1.05)
        }
    }
}

/// Karakterlere ses dağıtır. Her konuşmacı adı kalıcı olarak bir sese bağlanır (Kratos oyun boyunca aynı sesle konuşur);
/// etiketsiz satırlar anlatıcı sesiyle, tireyle değişen konuşmalar iki ses arasında sırayla okunur. Windows VoiceCast.cs
/// ve Android Dubbing.kt aynı kural; ortak deneme dosyası Tests/CouchSubsCoreTests/Fixtures/voice-cast.json.
///
/// Adından cinsiyeti anlaşılmayan karakter kullanıcının seçtiği "Tanınmayan karakterlerin sesi"yle konuşur (varsayılan
/// erkek). Eskiden bilinmeyen ada altı sesin en az kullanılanı verilirdi; sıralamada kadın sesleri önde olduğundan
/// listede olmayan ilk üç karakter (GTA 6'da Jason, Cal, Boobie…) kadın sesiyle konuşuyordu.
public struct VoiceCast: Codable, Equatable, Sendable {
    /// Kaydın kural sürümü. Daha eski kayıtta yanlış cinsiyetle verilmiş sesler bir kez düzeltilir (`upgradingRules`).
    public static let rules = 2

    /// Adın büyük harfli biçimi → ses. Ayarlardan değiştirilebilir.
    public private(set) var assignments: [String: DubbingVoice] = [:]
    public var narrator: DubbingVoice = .male1
    /// Tireli konuşmada sıradaki kişinin sesi.
    public var partner: DubbingVoice = .male2
    /// Adından cinsiyeti anlaşılmayan yeni karakterin sesi (Ayarlar › Türkçe dublaj › Tanınmayan karakterlerin sesi).
    public private(set) var unknownGender: DubbingVoice.Gender = .male
    private var lastWasPartner = false

    private enum CodingKeys: String, CodingKey { case assignments, narrator, partner, unknownGender, rules }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try values.decodeIfPresent([String: DubbingVoice].self, forKey: .assignments) ?? [:]
        narrator = (try? values.decodeIfPresent(DubbingVoice.self, forKey: .narrator)) ?? .male1
        partner = (try? values.decodeIfPresent(DubbingVoice.self, forKey: .partner)) ?? .male2
        unknownGender = (try? values.decodeIfPresent(DubbingVoice.Gender.self, forKey: .unknownGender)) ?? .male
        let rules = (try? values.decodeIfPresent(Int.self, forKey: .rules)) ?? 1
        if rules < Self.rules { upgradingRules() }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(assignments, forKey: .assignments)
        try values.encode(narrator, forKey: .narrator)
        try values.encode(partner, forKey: .partner)
        try values.encode(unknownGender, forKey: .unknownGender)
        try values.encode(Self.rules, forKey: .rules)
    }

    public static func key(_ name: String) -> String { name.uppercased(with: Locale(identifier: "en_US")) }

    /// Satırın sesi; yeni bir ad ilk kez görülünce ona bir ses ayrılır.
    public mutating func voice(for line: SpokenLine) -> DubbingVoice {
        if let speaker = line.speaker {
            lastWasPartner = false
            let key = Self.key(speaker)
            if let voice = assignments[key] { return voice }
            let voice = pick(for: NameGender.guess(speaker) ?? unknownGender)
            assignments[key] = voice
            return voice
        }
        if line.newTurn { lastWasPartner.toggle() }
        return lastWasPartner ? partner : narrator
    }

    public mutating func assign(_ voice: DubbingVoice, to name: String) { assignments[Self.key(name)] = voice }

    /// "Tanınmayan karakterlerin sesi". Anlatıcı ve tireli konuşmanın ikinci sesi de bu cinsiyette değilse o cinsiyetin
    /// seslerine geçer (adı yazmayan satırın kim olduğu da bilinmez). Atanmış karakterlerin sesi değişmez.
    public mutating func setUnknownGender(_ gender: DubbingVoice.Gender) {
        unknownGender = gender
        let voices = DubbingVoice.voices(gender)
        if narrator.gender != gender { narrator = voices[0] }
        if partner.gender != gender { partner = voices.first { $0 != narrator }! }
    }

    /// Kural 1 → 2: eski varsayılan ikinci ses (Kadın 1) erkek sese döner; adından cinsiyeti anlaşılan karaktere karşı
    /// cinsiyetten verilmiş ses ve tanınmayan ada verilmiş kadın sesi (eski sıralı dağıtımın izi) yeniden seçilir.
    private mutating func upgradingRules() {
        if narrator == .male1, partner == .female1 { partner = .male2 }
        let wrong = assignments.filter { name, voice in
            (NameGender.guess(name) ?? unknownGender) != voice.gender
        }.keys.sorted()
        for name in wrong { assignments[name] = nil }
        for name in wrong { assignments[name] = pick(for: NameGender.guess(name) ?? unknownGender) }
    }

    /// Yeni karakter için bu cinsiyetin en az kullanılan sesi; anlatıcı sesi en sona kalır.
    private func pick(for gender: DubbingVoice.Gender) -> DubbingVoice {
        var uses: [DubbingVoice: Int] = [:]
        for voice in assignments.values { uses[voice, default: 0] += 1 }
        // Anlatıcı sesi en sona kalsın: etiketsiz satırlarla karışmasın.
        uses[narrator, default: 0] += 1
        return DubbingVoice.voices(gender).min { (uses[$0] ?? 0, $0.order) < (uses[$1] ?? 0, $1.order) }!
    }
}

private extension DubbingVoice {
    var order: Int { Self.allCases.firstIndex(of: self)! }
}

/// Addan cinsiyet tahmini: oyun karakterleri (God of War, The Last of Us, GTA 6, GTA V, RDR2, Cyberpunk 2077, The Witcher
/// …), yaygın İngilizce, İspanyolca ve Türkçe adlar, unvanlar. Ad küçük harfe ve aksansız biçime çevrilir ("AYŞE" →
/// "ayse", "Dre'Quan" → "drequan"); bilinmeyen ad nil döner. Windows VoiceCast.cs ve Android Dubbing.kt'de aynı liste.
public enum NameGender {
    private static let female: Set<String> = [
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
    ]
    private static let male: Set<String> = [
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
    ]

    public static func guess(_ name: String) -> DubbingVoice.Gender? {
        let words = self.words(name)
        guard !words.isEmpty else { return nil }
        let whole = words.joined(separator: " ")
        if female.contains(whole) { return .female }
        if male.contains(whole) { return .male }
        // Çok sözcüklü adda sözcüklere bakılır ("OLD MAN", "Mary-Beth", "Mr. Wilson", "Guard Captain").
        for word in words {
            if female.contains(word) { return .female }
            if male.contains(word) { return .male }
        }
        return nil
    }

    /// Adın sözcükleri: küçük harf, aksan ve kesme işareti atılmış, "ı" → "i"; harf dışındaki her şey ayırır.
    static func words(_ name: String) -> [String] {
        var folded = String.UnicodeScalarView()
        for scalar in name.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            if scalar == "'" || scalar == "\u{2019}" { continue }
            folded.append(scalar == "ı" ? "i" : scalar)
        }
        return String(folded).split { !$0.isLetter }.map(String.init)
    }
}
