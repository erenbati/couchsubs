// SPDX-License-Identifier: AGPL-3.0-only
// Havuzdan kendiliğinden oyun paketi (Cron Trigger, her gece 03:02–05:57 UTC arasında beş dakikada bir).
//
// Bir oyunun (title_id; kimlik yoksa src/games.js'teki anahtarıyla oyun adı) satırları en az MIN_INSTALLS farklı kurulumda aynı biçimde (aynı canon anahtarla) okunduysa
// tools/packs/poolpack.py'deki kurallarla temizlenir, Claude (Anthropic Messages API; ANTHROPIC_API_KEY secret'ı yoksa
// Workers AI) ile Türkçeye çevrilir ve R2'ye (couchsubs-packs kovası) `packs/pool-<oyun kimliği>.json.gz` olarak
// yazılır; index.json'a sürümü artırılarak girer. Uygulamalar paketi kendileri indirir (server/packs). D1, R2 ve
// Workers AI bu Worker'ın bağlarıdır; Claude'un tek kimlik bilgisi ANTHROPIC_API_KEY secret'ıdır
// (`wrangler secret put ANTHROPIC_API_KEY`).
//
// Elle hazırlanmış (uygulamayla gelen) paketler öncelikli: onlardaki anahtarlar (R2'de auto/known-keys.bin,
// scripts/build-known.mjs üretir) otomatik pakete hiç girmez, böylece iki paket aynı satırda çakışmaz; otomatik paket
// elle olanın eksiğini tamamlar.
//
// Workers Free planında çağrı başına CPU süresi 10 ms: iş küçük adımlara bölünür ve her tetiklemede bir adım yapılır
// (gecenin ilk tetiklemesi plan, sonrakiler oyun başına çeviri parçaları ve en son paket). Durum R2'de auto/state.json.

import { accepts } from "./filter.js";
import { STATS_KEY, canon, key } from "./index.js";
import { EXTRA_SUFFIX, gameKey, gameSlug } from "./games.js";

/** Bir satırın pakete girmesi için onu okuyan en az farklı kurulum sayısı. */
export const MIN_INSTALLS = 2;
/** Bir oyunun ilk paketi için en az çevrilmiş satır; paket bir kez çıktıktan sonra her yeni satır eklenir. */
export const MIN_LINES = 300;
/** Workers AI ile (ANTHROPIC_API_KEY yokken) bir tetiklemede en çok bu kadar yeni satır çevrilir (CPU sınırı). */
export const LINES_PER_RUN = 200;
/** Workers AI ile bir gecede en çok bu kadar satır çevrilir (Claude sınırları aşağıda, CLAUDE_LIMITS).
 *  Hesap: Workers AI Free planı günde 10.000 nöron verir (UTC 00:00'da sıfırlanır). Önceki sınır 3000 satırı "10.000
 *  nöronun yarısından azı" saymıştı, yani en çok ~1,67 nöron/satır. 5000 satır × 1,67 = ~8.333 nöron: günlük sınırın
 *  %83'ü, %17 pay kalır (satır başına gerçek nöron panelden ölçülmeli; yüksek çıkarsa bu sayı düşürülür). Başka bir
 *  yapay zekâ kullanımı yoktur. 5000 satır gecede 200'lük en az 25 tetikleme ister; cron 36 tetikleme verir
 *  (plan 1 + çeviri ~25–30 + en son paket). */
export const NIGHTLY_LIMIT = 5000;
/** Bir D1 sorgusunda okunan satır sayfası ve bir tetiklemede en çok kaç sayfa gezilir. Sayfalar anahtar imleciyle
 *  (installs azalan, key artan) ilerler; "ilk 5000 satır" penceresi yoktur, büyük oyunun tamamı sırayla gezilir. */
export const PAGE = 1500;
export const MAX_PAGES = 3;
/** Bir tetiklemede en çok bu kadar çevrilebilir satıra bakılır (çöp ve bilinen satırlar çeviri bütçesini yemesin,
 *  ama CPU da sınırlı kalsın). */
export const MAX_LOOK = 500;
/** Bir oyun bir gecede en çok bu kadar satır çevirir; sonra paketi kurulup sıra sonrakine geçer. Dev bir oyun
 *  (GTA 6: yüz binlerce satır) bütün geceyi alıp öteki oyunları aç bırakmasın; her gece büyür, yeni sürüm çıkar. */
export const JOB_NIGHTLY = 2000;
/** Workers AI isteği başına satır. */
export const BATCH = 40;
/** Claude ile (ANTHROPIC_API_KEY varken) sınırlar. Çeviri Message Batches ile gider (%50 indirim): bir tetikleme en çok
 *  linesPerRun satırı 100'lük isteklere bölüp tek batch olarak gönderir (1 alt istek), sonraki tetiklemeler sonucu
 *  toplar (durum + sonuç dosyası, batch başına 2 alt istek). Aynı anda en çok MAX_PENDING_BATCHES batch bekler.
 *  Maliyet sınırı (claude-opus-5-5, effort low, Batches: $2 / $10 MTok): 2026-11-21 ölçümünde (150 GTA 6 satırı) satır
 *  başına ~0,00047 $ (giriş ~50 jeton: sistem metni + satır, çıkış ~37 jeton: düşünme dahil). Gecelik 5500 satır ~2,6 $;
 *  NIGHT_BUDGET_USD (3 $) toplanan usage ve bekleyen istek rezervleriyle ayrıca durdurur. Dev oyun (GTA 6) gecede en çok 4000 satır alır. */
export const CLAUDE_LIMITS = Object.freeze({
  linesPerRun: 1000, nightly: 5500, jobNightly: 4000, maxLook: 1500, batch: 100,
});
/** Aynı anda bekleyen en çok batch (oyun başına önbellekte durur). */
export const MAX_PENDING_BATCHES = 3;
/** Gezinti bitmiş oyun, paketini kurmadan önce bekleyen batch'ini en çok bu kadar bekler (sonra paket kurulur; geç
 *  kalan batch ertesi gece toplanır). */
export const BATCH_WAIT_MS = 45 * 60 * 1000;
/** Gecelik Claude harcama sınırı (dolar; toplanan yanıtların usage'ından, Batches fiyatıyla). */
export const NIGHT_BUDGET_USD = 3;
/** claude-opus-5-5 Batches fiyatı ($/MTok): giriş, çıkış, önbellekten okuma, önbelleğe yazma. */
const BATCH_PRICE = Object.freeze({ in: 2, out: 10, cacheRead: 0.1, cacheWrite: 2.5 });
// Typical 100-line requests reserve about 5.6k output tokens, leaving headroom over measured usage; long lines raise it.
const CLAUDE_MIN_TOKENS = 512;
const LEGACY_CLAUDE_MAX_TOKENS = 32000;
const RESERVATION_INPUT_TOKEN_OVERHEAD = 256;
const AI_LIMITS = Object.freeze({
  linesPerRun: LINES_PER_RUN, nightly: NIGHTLY_LIMIT, jobNightly: JOB_NIGHTLY, maxLook: MAX_LOOK, batch: BATCH,
});
/** Çeviri sağlayıcısının sınırları: secret varsa Claude, yoksa Workers AI. */
export const limitsFor = (env) => (env?.ANTHROPIC_API_KEY ? CLAUDE_LIMITS : AI_LIMITS);
/** Gecenin son tetiklemesi (cron 2-57/5 UTC 03–05): çevrilen oyun bu gece büyüdüyse paketi kurup sürümü artırır. */
export const LAST_HOUR_UTC = 5;
export const LAST_MINUTE_UTC = 52;
export const MODEL = "@cf/zai-org/glm-5.3-flash";
export const CLAUDE_MODEL = "claude-opus-5-5";
/** Opus 5.5'te düşünme kapatılamaz; kısa satır çevirisi için en düşük düzey. temperature gönderilmez. */
export const CLAUDE_EFFORT = "low";
export const CLAUDE_URL = "https://api.anthropic.com/v1/messages";
export const CLAUDE_BATCHES_URL = "https://api.anthropic.com/v1/messages/batches";
export const SOURCE = `CouchSubs havuzu (en az ${MIN_INSTALLS} oyuncu) + Claude (${CLAUDE_MODEL}) / Workers AI (${MODEL})`;
/** Oyunu bilinmeyen satırların ortak paketi (title_id NULL). PS5'in keşif yanıtı çalışan oyunu bildirmediği için
 *  satırların çoğu oyunsuz gelir; uygulamalar sunucudaki her paketi indirdiğinden bu paket de herkese gider. Oyunu
 *  bilinen paketlerden sonra hazırlanır. */
export const GENERAL = "GENEL";
export const GENERAL_TITLE = "Ortak havuz (çeşitli oyunlar)";
/** Kimliksiz, yalnız adıyla gelen oyun ayrı paket için en az bu kadar farklı kurulumdan oy almalı (game_votes):
 *  tek kişinin yanlış seçimi paket açmasın. Oyu yetmeyen adın satırları ortak pakete gider. */
export const MIN_VOTERS = 2;
/** Bir ad grubunda en çok bu kadar yazım ("GTA 6", "Grand Theft Auto VI"…) sorguya girer. */
const MAX_VARIANTS = 20;

const STATE = "auto/state.json";
const KNOWN = "auto/known-keys.bin";
const cacheFile = (job) => {
  if (job.titleId) return `auto/tr/${job.titleId}.json`;
  // Long ASCII names can have the same truncated slug while their pack IDs differ.
  // Keep short ASCII cache paths compatible, but hash long and non-Latin identities.
  return `auto/tr/name-${jobPackId(job).slice(PACK_PREFIX.length)}.json`;
};

// poolpack.py ile aynı: konuşmacı etiketi, Türkçe harf, yazı tanıma çöpü.
const LABEL = /^[-•\s]*([A-Z][A-Za-z .'’-]{1,28}?)\s*[•:]\s+(?=\S)/;
const TURKISH = /[ğĞşŞıİ]/u;
const OCR_JUNK = /[$#@|\\{}<>~^_=]|[\p{L}\p{N}_][%&*][\p{L}\p{N}_]/u;
// Üç ve daha çok sözcüklü satırda en az bir yaygın İngilizce sözcük: bozuk okunmuş Türkçe arayüz ("Yeni ipuqlarl Var
// Daha Fazlaslnl") Türkçe harf taşımadığı için ayrıca elenir.
const ENGLISH = new Set(("the a an to of and or but with for from my your his her their our at in on by is are was were be " +
  "i you he she it we they me him us them this that what who where when why how not no yes do did don't can can't will " +
  "won't just get got go have has had all there here now up out if so like know want need come one some about").split(" "));

const PACK_PREFIX = "pool-";
const MAX_PACK_ID_LENGTH = 64;

function hashPackSuffix(value) {
  let hash = 14695981039346656037n;
  for (const character of value) {
    hash = BigInt.asUintN(64, (hash ^ BigInt(character.codePointAt(0))) * 1099511628211n);
  }
  return hash.toString(36).padStart(13, "0");
}

function prefixedPackId(suffix, identity = suffix) {
  const full = `${PACK_PREFIX}${suffix}`;
  if (full.length <= MAX_PACK_ID_LENGTH) return full;

  // Kimlik biçimini 64 karakterde tutarken uzun oyun adlarının aynı pakete çarpışmasını önle.
  const hash = hashPackSuffix(identity);
  const prefixLength = MAX_PACK_ID_LENGTH - PACK_PREFIX.length - hash.length - 1;
  return `${PACK_PREFIX}${suffix.slice(0, prefixLength)}-${hash}`;
}

/** Oyun kimliğinden paket kimliği: "PPSA01234" → "pool-ppsa01234" (server/packs'in kimlik biçimine uyar). */
export function packId(titleId) {
  const identity = String(titleId);
  return prefixedPackId(identity.toLowerCase().replace(/[^a-z0-9]+/g, "-"), identity);
}

/** İşin paket kimliği: oyun kimliği varsa ondan, yoksa adın anahtarından ("gta 6" → "pool-gta-6"). */
export function jobPackId(job) {
  if (job.titleId) return packId(job.titleId);
  const identity = String(job.gameKey);
  const slug = gameSlug(identity);
  if (/^[a-z0-9 ]+$/.test(identity)) return prefixedPackId(slug, identity);

  // Non-Latin characters disappear from the ASCII slug, so hash the full key to avoid collisions.
  const hash = hashPackSuffix(identity);
  const maxSlug = MAX_PACK_ID_LENGTH - PACK_PREFIX.length - hash.length - 1;
  const safeSlug = (slug || "game").slice(0, maxSlug).replace(/-+$/, "");
  return `${PACK_PREFIX}${safeSlug}-${hash}`;
}

/** Kimliksiz satırların oyun adları ("game" sütunu, yazımına göre sayılmış) anahtara göre birleşir; en az MIN_VOTERS
 *  kurulumun oyladığı anahtarlar iş olur. Görünen ad en çok satırı olan yazımdır. */
export function nameJobs(rows, votes) {
  const groups = new Map();
  for (const r of rows) {
    const k = gameKey(r.game);
    if (!k || gameSlug(k) === "genel") continue;
    const g = groups.get(k) ?? { titleId: null, gameKey: k, game: r.game, best: 0, lines: 0, games: [] };
    g.lines += r.lines;
    if (g.games.length < MAX_VARIANTS) g.games.push(r.game);
    if (r.lines > g.best) { g.best = r.lines; g.game = r.game; }
    groups.set(k, g);
  }
  return [...groups.values()]
    .filter((g) => (votes.get(g.gameKey) ?? 0) >= MIN_VOTERS)
    .map(({ best, ...g }) => g)
    .sort((a, b) => b.lines - a.lines);
}

async function allRows(stmt) {
  try { return (await stmt.all()).results ?? []; } catch (e) {
    // Geçiş çalışmadıysa (game_votes ya da game sütunu yok) ad grupları yoktur.
    if (/no such (table|column)/i.test(String(e?.message || e))) return [];
    throw e;
  }
}

/** Havuz satırının çevrilecek gövdesi (konuşmacı etiketi atılmış) ya da pakete uygun değilse null. */
export function cleanLine(text) {
  const raw = String(text ?? "").replace(/\s+/g, " ").trim();
  if (!accepts(raw)) return null;
  const m = LABEL.exec(raw);
  const body = m ? raw.slice(m[0].length).trim() : raw;
  if (TURKISH.test(body)) return null;
  const visible = [...body.replace(/ /g, "")];
  const letters = visible.filter((ch) => /\p{L}/u.test(ch)).length;
  if (OCR_JUNK.test(body) || letters * 2 < visible.length) return null;
  const words = body.split(" ").filter((w) => /\p{L}/u.test(w)).length;
  if (words < 2 || body.length > 300) return null;
  const lower = body.toLowerCase().split(/[^a-z']+/).filter(Boolean);
  if (lower.length >= 3 && !lower.some((w) => ENGLISH.has(w))) return null;
  return { body, labelled: body !== raw };
}

/** Elle hazırlanmış paketlerin anahtarları: sıralı 64 bit sayılar (küçük uçlu). */
export function isKnown(known, hex) {
  if (!known || !hex) return false;
  const value = BigInt("0x" + hex);
  let low = 0, high = known.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (known[mid] < value) low = mid + 1; else high = mid;
  }
  return low < known.length && known[low] === value;
}

const SYSTEM = (game) =>
  "You translate video game subtitles from English into natural, colloquial Turkish for CouchSubs, an app that shows " +
  "Turkish subtitles on the TV while people play" + (game ? ` ${game}` : "") + ".\n" +
  "Rules:\n- Translate every line; keep character, place, gang, vehicle and brand names as they are.\n" +
  "- Dialogue: use 'sen' between characters unless the scene is clearly formal. Tutorial hints: short imperative.\n" +
  "- Keep the tone, slang and swearing level; keep ellipses and question marks.\n" +
  "- These lines were read from the TV with OCR; if a word is clearly damaged, translate the most likely original.\n" +
  "- One Turkish line per item, no notes. Output only JSON: {\"items\":[{\"id\":\"0\",\"tr\":\"...\"}]}";

// Claude için oyun altyazısı kuralları. 2026-11-21 kalite testinde (150 GTA 6 satırı, Opus 5.5 kör puanlama) eski istemin
// "fucking = siktiğimin" eşlemesi kelimesi kelimesine küfür, "zenci", metne giren konuşmacı etiketleri ve çevrilmiş yazı
// tanıma çöpü üretiyordu; bu istem küfrü ve argoyu doğal Türkçe karşılığıyla ister, çöp satırı boş bırakır. Kural: küfür
// asla sansürlenmez; kaynaktaki her küfür Türkçede açıkça, en az aynı sertlikte yer alır (lanet/kahretsin/pislik yok). Metin yalnız
// oyuna göre değişir: bir oyunun bütün istekleri aynı sistem metniyle gider ve önbellekten (prompt caching) okunur.
const CLAUDE_SYSTEM = (game) => `You translate video game subtitles from English into Turkish for CouchSubs, an app that shows Turkish subtitles on the TV while people play` + (game ? ` ${game}` : "") + `. The lines were read from the TV screen with OCR, so some are damaged.

Write the Turkish a professional Turkish subtitler would write for this game: spoken, the way people in Turkey actually talk (street-level where the characters are). Keep the tone of every line: banter stays banter, threats stay threats, crude stays crude.

Swearing: never censor. Every swear word in the English appears in the Turkish, openly and at least as strong.
- Never drop a swear word, never soften it, never replace it with a euphemism ("lanet olası", "kahrolası", "kahretsin", "lanet olsun", "pislik", "Allah'ın belası", "lan" alone). Only a mild English word ("damn", "hell", "crap", "screw") may get a mild Turkish word.
- Translate the intent, never word by word: use the hard swearing a Turkish speaker would really say in that situation.
- "fucking" as an intensifier = "amına koyayım" at the start or end of the sentence ("I don't fucking know" = "Bilmiyorum amına koyayım"; "too fucking far" = "Çok uzak amına koyayım"); before a noun that is being cursed = "amına koyduğumun ..." ("my fucking car" = "amına koyduğumun arabası"); "siktiğimin" only where it sits naturally in Turkish ("this fucking job" = "siktiğimin işi"). If the noun form reads awkwardly, keep the swear as "amına koyayım" at the end ("Just one fucking guy?" = "Tek bir herif mi amına koyayım?"), never drop it.
- "fuck!" = "Siktir!"; "fuck you" = "Siktir git" / "Sikeyim seni"; "fuck off" = "Siktir git"; "what the fuck" = "Ne oluyor amına koyayım?"; "holy shit" = "Ha siktir!" / "Vay amına koyayım!"; "shit" as an outburst = "Siktir" / "Hay sikeyim", as a thing = "bok"; "motherfucker" = "orospu çocuğu" / "ananı sikeyim" (as an outburst); "son of a bitch" = "orospu çocuğu"; "asshole" = "göt herif" / "şerefsiz"; "bitch" at a person = "orospu" / "kaltak", about a man = "karı kılıklı" / "amcık", about a thing ("this bitch") = "bu orospu"; "cunt" = "amcık" / "orospu"; "dick" = "yarak", "dickhead" = "yarrak kafalı"; "pussy" (coward) = "amcık".
- "fuck with someone" meaning mess with = "birinin anasını sikmek" / "bulaşmak" with a swear kept ("Don't fuck with me" = "Bana bulaşma amına koyayım", "people to fuck with" = "anasını sikecek adamlar"); sexual "fuck" = "sikmek" / "sikişmek".
- "damn" = "Hay aksi" / "Lanet olsun", admiring "damn" = "Vay be"; "hell" = "Hay Allah" / "Ne cehennem".
- The n-word ("nigga", "niggas") between friends is an address: "kanka", "lan", "kardeşim" or drop it; about other people it means "guys/dudes": "herifler", "bunlar", "adamlar". Never translate it as "zenci".
- "bro", "homie", "dawg" = "kanka" / "kardeşim"; "man" / "dude" as address = "dostum" / "lan" / "ahbap" or drop.
- Street slang gets its meaning, not its words: "stay low" = "göze batma", "you got it fucked up" = "Yanlış anlamışsın amına koyayım", "on the flip" = "sonra görüşürüz", "boosting a car" = "araba çalmak", "get smoked" = "vurulmak".

Speaker labels and tags:
- OCR sometimes joins two subtitles, so a speaker label can appear inside a line ("Okay. Jason: Let's go."). Keep a character-name label exactly as it is, with its colon ("Jason:", "Dre'Quan:"), and translate only the speech.
- Generic labels: "Stranger:" = "Yabancı:", "Guard:" = "Gardiyan:", "Cop:" = "Polis:". Drop "Unknown Language:" and "In Spanish:" style prefixes and music tags ("[dark music]", "♪"); short sound or manner tags are translated ([laughing] = [gülerek]).

OCR damage:
- OCR swaps letters (ali = all, Iaw = law, Hels = He's, sorne = some, vehicte = vehicle): read the intended English first and never copy OCR damage into the Turkish.
- A line may be cut off: translate only what is there; never invent missing words.
- Drop stray fragments that are not part of the speech: random capital-letter strings, broken half-words, HUD codes and stray numbers ("J26 487", "DI", "Tsk"), phone numbers glued to dialogue.
- If nothing meaningful is left (pure OCR noise like "EML. S.", "LRR O..", "F I."), output an empty string "" for that item. A line with real words (dialogue, a sign, a menu, an ad) is always translated, even when parts are damaged.

Names: keep character, place, gang, brand, vehicle, shop, radio station, song and show names exactly as they are (in GTA for example Lucia, Jason, Vice City, Leonida, Port Gellhorn, Grassrivers, Ambrosia, VCPD, FIB, IAA, Ammu-Nation, Cluckin' Bell, DWNPLY, Ganado). Use Turkish suffixes with an apostrophe (Cal'in, Vicki'nin).

Form:
- "sen" between friends, family and enemies; "siz" only for clearly formal address. On-screen objectives and hints are short imperatives ("Arabaya bin.", "Cal'in evine git."). Big-caps UI words stay caps: Wasted = ÖLDÜN, Busted = YAKALANDIN, Mission Passed = GÖREV BAŞARILI.
- Keep the Turkish about as long as the English; a subtitle has to be read in a second or two. Keep the sentences of one item in order, as one line. Never merge, split, skip or move meaning between items.
- Keep punctuation style (…, ?!, quotes, dashes). Interjections become Turkish sounds (Ugh = Of, Huh = Ha?, Hmm = Hmm).
- Input: one item per line as \`id<TAB>English\`. Output only JSON: {"items":[{"id":"0","tr":"..."}]}, exactly one item per input id, no notes, no line breaks inside a translation.`;

const CLAUDE_SCHEMA = {
  type: "object",
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        properties: { id: { type: "string" }, tr: { type: "string" } },
        required: ["id", "tr"],
        additionalProperties: false,
      },
    },
  },
  required: ["items"],
  additionalProperties: false,
};

const claudeHeaders = (env) => ({
  "content-type": "application/json",
  "x-api-key": env.ANTHROPIC_API_KEY,
  "anthropic-version": "2023-06-01",
});

function claudeMaxTokens(items) {
  const estimate = items.length * 32 + items.reduce((sum, item) => sum + String(item?.en ?? "").length * 0.6, 0);
  return Math.min(LEGACY_CLAUDE_MAX_TOKENS, Math.max(CLAUDE_MIN_TOKENS, Math.ceil(estimate)));
}

/** Bir çeviri isteğinin gövdesi (Messages API; Batches'te `params`). Opus 5.5 düşünmeyi kapatamaz: `thinking`
 *  gönderilmez, effort low; temperature yok. */
export function claudeParams(items, game, maxTokens = claudeMaxTokens(items)) {
  return {
    model: CLAUDE_MODEL,
    max_tokens: maxTokens,
    system: [{ type: "text", text: CLAUDE_SYSTEM(game), cache_control: { type: "ephemeral" } }],
    output_config: { effort: CLAUDE_EFFORT, format: { type: "json_schema", schema: CLAUDE_SCHEMA } },
    messages: [{ role: "user", content: items.map((it, i) => `${i}\t${it.en}`).join("\n") }],
  };
}

/** Claude yanıtından id → Türkçe ("" = model satırı yazı tanıma çöpü saydı, çevrilmez). Yarım (max_tokens) ya da
 *  reddedilmiş yanıt alınmaz: satırlar sonraki geçişte yeniden denenir (fail sayacı). */
export function claudeReply(reply, items) {
  if (reply?.stop_reason !== "end_turn") {
    console.log("autopack: Claude yanıtı tamamlanmadı", reply?.stop_reason);
    return new Map();
  }
  const text = (reply.content ?? []).filter((b) => b?.type === "text").map((b) => b.text).join("");
  return parseReply({ response: text }, items, { allowSkip: true });
}

/** Yanıtın Batches fiyatıyla doları (usage'dan). */
export function batchCost(usage) {
  const u = usage ?? {};
  const n = (v) => (Number.isFinite(v) ? v : 0);
  return (n(u.input_tokens) * BATCH_PRICE.in + n(u.output_tokens) * BATCH_PRICE.out
    + n(u.cache_read_input_tokens) * BATCH_PRICE.cacheRead + n(u.cache_creation_input_tokens) * BATCH_PRICE.cacheWrite) / 1e6;
}

/** Bir batch'in üst sınır maliyeti: en yüksek input (cache write) ve output fiyatını kullanır. */
function batchReservation(reqs, game, maxTokens = null) {
  const encoder = new TextEncoder();
  let usd = 0;
  for (const items of Object.values(reqs ?? {})) {
    if (!Array.isArray(items) || items.length === 0) continue;
    const params = claudeParams(items, game, maxTokens ?? claudeMaxTokens(items));
    // Parametre gövdesi istemi, şemayı ve satırları içerir; 1.5 UTF-8 bayt/token tahmini ek payla kullanılır.
    const inputTokens = Math.ceil(encoder.encode(JSON.stringify(params)).length / 1.5) + RESERVATION_INPUT_TOKEN_OVERHEAD;
    usd += (inputTokens * BATCH_PRICE.cacheWrite + params.max_tokens * BATCH_PRICE.out) / 1e6;
  }
  return usd;
}

function reservationAmount(value) {
  const usd = Number.isFinite(value) ? value : value?.usd;
  return Number.isFinite(usd) && usd >= 0 ? usd : 0;
}

function reservedUsd(state) {
  return Object.values(state?.reservations ?? {}).reduce((sum, value) => sum + reservationAmount(value), 0);
}

function reservationJob(job) {
  const ref = { game: job.game ?? null };
  if (job.titleId) ref.titleId = job.titleId;
  else ref.gameKey = job.gameKey;
  return ref;
}

function requestsFor(todo, size) {
  const reqs = {};
  for (let i = 0; i < todo.length; i += size) reqs[`c${i}`] = todo.slice(i, i + size);
  return reqs;
}

function affordablePrefixLength(todo, game, size, availableUsd) {
  let accepted = 0;
  let reserved = 0;
  for (let offset = 0; offset < todo.length; offset += size) {
    const part = todo.slice(offset, offset + size);
    const fullCost = batchReservation({ c0: part }, game);
    if (reserved + fullCost <= availableUsd) {
      reserved += fullCost;
      accepted += part.length;
      continue;
    }
    let low = 0;
    let high = part.length;
    while (low < high) {
      const mid = Math.ceil((low + high) / 2);
      if (reserved + batchReservation({ c0: part.slice(0, mid) }, game) <= availableUsd) low = mid;
      else high = mid - 1;
    }
    return accepted + low;
  }
  return accepted;
}

/** Satırları Claude ile (Anthropic Messages API, eşzamanlı) çevirir; id → Türkçe. Hata ya da bozuk yanıtta boş. Gece işi
 *  Batches kullanır (submitBatch / collectBatches); bu yol elle denemeler içindir. */
export async function translateClaude(env, items, game) {
  let reply;
  try {
    const res = await fetch(CLAUDE_URL, {
      method: "POST", headers: claudeHeaders(env), body: JSON.stringify(claudeParams(items, game, LEGACY_CLAUDE_MAX_TOKENS)),
    });
    if (!res.ok) {
      console.log("autopack: Claude hatası", res.status, (await res.text()).slice(0, 300));
      return new Map();
    }
    reply = await res.json();
  } catch (e) {
    console.log("autopack: Claude çeviri hatası", String(e?.message || e));
    return new Map();
  }
  return claudeReply(reply, items);
}

/** Satırları 100'lük isteklere bölüp tek Message Batch olarak gönderir. Belirsiz ağ/5xx sonuçlarında başarısızlık işaretlenir. */
export async function submitBatch(env, todo, game, size, now) {
  const reqs = requestsFor(todo, size);
  const requests = [];
  for (const [id, part] of Object.entries(reqs)) {
    requests.push({ custom_id: id, params: claudeParams(part, game) });
  }
  const reservation = batchReservation(reqs, game);
  try {
    const res = await fetch(CLAUDE_BATCHES_URL, {
      method: "POST", headers: claudeHeaders(env), body: JSON.stringify({ requests }),
    });
    if (!res.ok) {
      console.log("autopack: Claude batch hatası", res.status, (await res.text()).slice(0, 300));
      // Anthropic 529 is an explicit overload rejection; other 5xx responses may follow an accepted POST.
      return { failure: true, ambiguous: res.status >= 500 && res.status !== 529, status: res.status };
    }
    const batch = await res.json();
    if (typeof batch?.id !== "string" || !batch.id) return { failure: true, ambiguous: true };
    console.log("autopack: Claude batch", batch.id, todo.length, "satır");
    return { id: batch.id, at: now.getTime(), reqs, reservedUsd: reservation };
  } catch (e) {
    console.log("autopack: Claude batch gönderilemedi", String(e?.message || e));
    return { failure: true, ambiguous: true };
  }
}

/** Bekleyen batch'lerden bitenleri önbelleğe yazar; settled, rezervi kapanan batch ID'lerini döner. */
export async function collectBatches(env, cache) {
  const out = { lines: 0, usd: 0, input: 0, output: 0, settled: [] };
  const keep = [];
  for (const b of cache.batches ?? []) {
    let status;
    try {
      const res = await fetch(`${CLAUDE_BATCHES_URL}/${b.id}`, { headers: claudeHeaders(env) });
      if (res.status === 404) {
        // Silinmiş/süresi geçmiş batch: satırlar bir başarısızlık sayar, sonraki geçişte yeniden denenir.
        failLines(cache, Object.values(b.reqs).flat());
        out.usd += Number.isFinite(b.reservedUsd) && b.reservedUsd >= 0 ? b.reservedUsd : 0;
        out.settled.push(b.id);
        continue;
      }
      if (!res.ok) { keep.push(b); continue; }
      status = await res.json();
    } catch { keep.push(b); continue; }
    if (status?.processing_status !== "ended" || typeof status.results_url !== "string") { keep.push(b); continue; }
    let text;
    try {
      const res = await fetch(status.results_url, { headers: claudeHeaders(env) });
      if (!res.ok) { keep.push(b); continue; }
      text = await res.text();
    } catch { keep.push(b); continue; }
    const seen = new Set();
    let batchUsd = 0;
    let unknownCost = false;
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let row;
      try { row = JSON.parse(line); } catch { continue; }
      const part = b.reqs[row?.custom_id];
      if (!Array.isArray(part) || seen.has(row.custom_id)) continue;
      seen.add(row.custom_id);
      const outcome = row.result?.type;
      const message = outcome === "succeeded" ? row.result.message : null;
      const usage = message?.usage;
      if (outcome === "succeeded") {
        if (Number.isFinite(usage?.input_tokens) && usage.input_tokens >= 0
          && Number.isFinite(usage?.output_tokens) && usage.output_tokens >= 0) {
          batchUsd += batchCost(usage);
          out.input += usage.input_tokens + (usage.cache_read_input_tokens ?? 0)
            + (usage.cache_creation_input_tokens ?? 0);
          out.output += usage.output_tokens;
        } else unknownCost = true;
      } else if (!["errored", "canceled", "expired"].includes(outcome)) unknownCost = true;
      out.lines += applyTranslations(cache, part, message ? claudeReply(message, part) : new Map());
    }
    // Sonuç dosyasında olmayan istekler (hata) de bir başarısızlık sayar.
    for (const [id, part] of Object.entries(b.reqs)) {
      if (!seen.has(id)) {
        failLines(cache, part);
        unknownCost = true;
      }
    }
    const reservation = Number.isFinite(b.reservedUsd) && b.reservedUsd >= 0 ? b.reservedUsd : 0;
    out.usd += unknownCost ? Math.max(batchUsd, reservation) : batchUsd;
    out.settled.push(b.id);
  }
  cache.batches = keep;
  return out;
}

/** Çevirileri önbelleğe yazar ("" = kalıcı atla); alınamayan satır bir başarısızlık sayar. Döner: yazılan satır. */
function applyTranslations(cache, part, got) {
  let n = 0;
  part.forEach((line, j) => {
    const tr = got.get(j);
    if (tr === "") {
      cache.skip[line.pool] = 2;
      delete cache.fail[line.pool];
    } else if (tr) {
      cache.lines[line.pool] = { k: line.k, en: line.en, tr };
      delete cache.fail[line.pool];
      n++;
    } else failLines(cache, [line]);
  });
  return n;
}

function failLines(cache, lines) {
  for (const line of lines) {
    // İki kez çevrilemeyen satır bırakılır (sonsuz döngü olmasın). 2 = bu geçişte kalıcı atla.
    if ((cache.fail[line.pool] = (cache.fail[line.pool] || 0) + 1) >= 2) {
      cache.skip[line.pool] = 2;
      delete cache.fail[line.pool];
    }
  }
}

/** Çeviri sağlayıcısı: ANTHROPIC_API_KEY secret'ı varsa Claude, yoksa Workers AI. */
export function translate(env, items, game) {
  return env.ANTHROPIC_API_KEY ? translateClaude(env, items, game) : translateWorkersAI(env, items, game);
}

/** Satırları Workers AI ile çevirir; id → Türkçe. Yanıt bozuksa boş. */
export async function translateWorkersAI(env, items, game) {
  const user = items.map((it, i) => `${i}\t${it.en}`).join("\n");
  let reply;
  try {
    reply = await env.AI.run(MODEL, {
      messages: [{ role: "system", content: SYSTEM(game) }, { role: "user", content: user }],
      max_tokens: 6000,
      chat_template_kwargs: { enable_thinking: false },
    });
  } catch (e) {
    console.log("autopack: çeviri hatası", String(e?.message || e));
    return new Map();
  }
  return parseReply(reply, items);
}

/** Yanıttaki items → id → Türkçe. allowSkip: boş "tr" bilerek boş bırakılmış satırdır (yazı tanıma çöpü), "" olarak
 *  döner; yoksa boş satır alınmaz. */
export function parseReply(reply, items, { allowSkip = false } = {}) {
  let content = reply?.choices?.[0]?.message?.content ?? reply?.response;
  let parsed = content;
  if (typeof content === "string") {
    const text = content.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
    try { parsed = JSON.parse(text); } catch { return new Map(); }
  }
  const out = new Map();
  if (!Array.isArray(parsed?.items)) return out;
  const duplicates = new Set();
  for (const it of parsed.items) {
    const id = it?.id;
    if (typeof id !== "number" && !(typeof id === "string" && /^\d+$/.test(id))) continue;
    const i = Number(id);
    if (typeof it?.tr !== "string") continue;
    const tr = it.tr.replace(/\s+/g, " ").trim();
    if (!Number.isSafeInteger(i) || !items[i] || (!tr && !allowSkip)) continue;
    // Açıklama ya da birden çok satır yazmış, çok uzun ya da Türkçe değil: alınmaz.
    if (/[{}]/.test(tr) || tr.length > items[i].en.length * 3 + 40) continue;
    // Ambiguous AI IDs must not silently overwrite an earlier, different subtitle.
    if (duplicates.has(i)) continue;
    if (out.has(i)) {
      out.delete(i);
      duplicates.add(i);
      continue;
    }
    out.set(i, tr);
  }
  return out;
}

async function getJson(env, name) {
  const object = await env.PACKS.get(name);
  if (!object) return null;
  try { return JSON.parse(await object.text()); } catch { return null; }
}

// Kaybolan önbellek ilk çalıştırmada normaldir; mevcut ama bozuk önbelleği sıfırlamak mevcut paketi silebilir.
async function loadCache(env, job) {
  const object = await env.PACKS.get(cacheFile(job));
  if (!object) {
    // Yayınlanmış paketin önbelleği silindiyse sıfırdan oluşturmak mevcut çevirileri boş paketle değiştirir.
    const packs = await readIndex(env);
    if (packs.some((pack) => pack.id === jobPackId(job))) return null;
    return { lines: {}, skip: {}, fail: {} };
  }
  try {
    const cache = JSON.parse(await object.text());
    const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
    if (!record(cache) || !record(cache.lines) || !record(cache.skip)
      || (cache.fail != null && !record(cache.fail))) return null;
    // A parseable cache with a null line or malformed hash otherwise throws in
    // packBody/isKnown and stops the remaining nightly scheduler calls.
    if (!Object.entries(cache.lines).every(([pool, line]) =>
      /^[0-9a-f]{16}$/.test(pool) && record(line)
      && typeof line.k === "string" && /^[0-9a-f]{16}$/.test(line.k)
      && typeof line.en === "string" && line.en.trim().length > 0
      && typeof line.tr === "string" && line.tr.trim().length > 0)) return null;
    // Bekleyen Claude batch'leri: bozuk kayıt atılır (satırları sonraki geçişte yeniden denenir), önbellek korunur.
    const validBatch = (b) => record(b) && typeof b.id === "string" && b.id.length > 0 && Number.isFinite(b.at)
      && record(b.reqs) && Object.values(b.reqs).every((part) => Array.isArray(part) && part.every((line) =>
        record(line) && /^[0-9a-f]{16}$/.test(line.pool) && /^[0-9a-f]{16}$/.test(line.k) && typeof line.en === "string"));
    cache.batches = Array.isArray(cache.batches) ? cache.batches.filter(validBatch) : [];
    return cache;
  } catch { return null; }
}

const putJson = (env, name, value) =>
  env.PACKS.put(name, JSON.stringify(value), { httpMetadata: { contentType: "application/json" } });

async function loadKnown(env) {
  const object = await env.PACKS.get(KNOWN);
  if (!object) return null;
  const buffer = await object.arrayBuffer();
  // Boş veya yarım kalmış dosya (8'in katı olmayan boyut) bozuktur: elle hazırlanan çevirileri korumak için beklenir. Sıralama
  // her tetiklemede taranmaz (650 bin anahtar, Free planın 10 ms CPU sınırını aşar); dosyayı scripts/build-known.mjs
  // sıralı ve tekrarsız üretir.
  if (buffer.byteLength === 0 || buffer.byteLength % 8 !== 0) return null;
  return new BigUint64Array(buffer);
}

async function sha256Hex(data) {
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function gzip(text) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const sorted = (o) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));

/** Çeviri önbelleğinden paket gövdesi (elle hazırlanmış paketlerdeki anahtarlar hariç). */
export function packBody(id, title, cache, known, titleId = null) {
  const entries = {};
  const segments = {};
  for (const [pool, line] of Object.entries(cache.lines)) {
    if (isKnown(known, line.k)) continue;
    // Türkçesi İngilizcesiyle aynı (ad, ünlem): tam satır değil parça (build.py ile aynı).
    if (canon(line.tr) === canon(line.en)) segments[line.k] = line.tr; else entries[line.k] = line.tr;
    // Konuşmacı etiketli okunuş da aynı Türkçeye çıkar.
    if (pool !== line.k && !isKnown(known, pool)) segments[pool] = line.tr;
  }
  for (const k of Object.keys(segments)) if (k in entries) delete segments[k];
  const count = Object.keys(entries).length;
  // Oyun kimliği uygulamalara da gider: paketle tanınan oyun havuza kimliğiyle döner.
  const head = titleId ? { format: 2, id, title, titleId } : { format: 2, id, title };
  const body = JSON.stringify({ ...head, source: SOURCE, entries: sorted(entries), segments: sorted(segments) });
  return { body, count };
}

async function readIndex(env) {
  const index = await getJson(env, "index.json");
  // Eksik/bozuk indeks, boş bir indeks değildir: aksi halde sonraki paket mevcut listeyi siler.
  if (!Array.isArray(index?.packs)) throw new Error("autopack index unavailable or invalid");
  // An ambiguous or malformed index makes every client's pack list unavailable.
  // Never rewrite it or drop entries while trying to publish another pack.
  const ids = new Set();
  for (const pack of index.packs) {
    if (!pack || typeof pack !== "object" || typeof pack.id !== "string"
      || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(pack.id) || ids.has(pack.id)) {
      throw new Error("autopack index invalid or duplicate pack ID");
    }
    ids.add(pack.id);
  }
  return index.packs;
}

/** Paketin listedeki adı. Aynı oyunun elle hazırlanmış (auto olmayan) paketi listede varsa otomatik paket onun
 *  eksiğini tamamlar: adına " (ek satırlar)" eklenir ki listede iki kez aynı ad görünmesin. Ek, adın anahtarını da
 *  değiştirir; uygulamalar elle seçilen oyunu ada göre eşlediğinden (GamePacks.swift resolveLimit) seçim asıl pakete
 *  gider. Asıl paket yoksa ad değişmez: yalnız ek paketi olan oyunun seçimi bu paketi bulmaya devam eder. */
export function packTitle(job, packs) {
  if (job.titleId === GENERAL) return GENERAL_TITLE;
  const title = job.game || job.titleId;
  const id = jobPackId(job);
  const k = gameKey(title);
  const main = packs.some((p) => p && !p.auto && p.id !== id
    && ((k && typeof p.title === "string" && gameKey(p.title) === k) || (job.titleId && p.titleId === job.titleId)));
  return main ? title + EXTRA_SUFFIX : title;
}

async function buildPack(env, job, cache, known) {
  const id = jobPackId(job);
  const packs = await readIndex(env);
  // Ad gövdede de durduğundan ad değişince (asıl paket eklendi ya da kalktı) içerik özeti de değişir ve paket aynı
  // gece yeniden yazılır; listedeki ad böylece kendiliğinden güncellenir.
  const title = packTitle(job, packs);
  const { body, count } = packBody(id, title, cache, known, job.titleId === GENERAL ? null : job.titleId);
  const previous = packs.find((p) => p.id === id);
  // A syntactically valid but empty translation cache (or lines filtered into
  // segments only) can produce a pack clients reject: GamePack requires entries.
  // Never replace an already published working pack with that empty result.
  if (previous && count === 0) return { id, built: false, preserved: true, entries: count };
  if (!previous && count < MIN_LINES) return { id, built: false, entries: count };
  const contentSha = await sha256Hex(new TextEncoder().encode(body));
  if (previous && cache.contentSha === contentSha) {
    // The index may outlive an R2 object removed independently.
    // An unchanged source hash is only enough when the published file exists.
    const packKey = `packs/${id}.json.gz`;
    const published = env.PACKS.head
      ? await env.PACKS.head(packKey)
      : await env.PACKS.get(packKey);
    if (published) return { id, built: false, unchanged: true, entries: count };
  }
  const data = await gzip(body);
  const sha256 = await sha256Hex(data);
  // Önce dosya, sonra liste: liste hiçbir zaman olmayan dosyayı göstermez.
  await env.PACKS.put(`packs/${id}.json.gz`, data, {
    httpMetadata: { contentType: "application/gzip" }, customMetadata: { sha256 },
  });
  const fresh = await readIndex(env);
  const version = (fresh.find((p) => p.id === id)?.version ?? 0) + 1;
  const entry = { id, title, version, sha256, size: data.length, entries: count, auto: true };
  if (job.titleId) entry.titleId = job.titleId;
  else entry.game = job.gameKey;
  const list = fresh.filter((p) => p.id !== id).concat(entry).sort((a, b) => (a.id < b.id ? -1 : 1));
  await putJson(env, "index.json", { packs: list });
  cache.contentSha = contentSha;
  await putJson(env, cacheFile(job), cache);
  return { id, built: true, version, entries: count, size: data.length };
}

/** Herkese açık sayıların gecelik özeti (R2 auto/stats.json; GET /v1/stats yalnız bunu okur). Ağır sorgu (bütün
 *  sightings'i tarayan COUNT DISTINCT) yalnız burada, gecede bir kez ve kendi tetiklemesinde çalışır; süre sınırına
 *  takılırsa önceki özetteki sayılar korunur (approx işareti), tetiklemeyi ve gece işini düşürmez. */
export async function computeStats(env, now) {
  const previous = await getJson(env, STATS_KEY);
  let { lines, installs } = previous ?? {};
  let confirmed = previous?.confirmed;
  let approx = false;
  try {
    const seen = await env.DB.prepare(
      "SELECT COUNT(DISTINCT key) AS lines, COUNT(DISTINCT install) AS installs FROM sightings"
    ).first();
    lines = seen?.lines ?? lines;
    installs = seen?.installs ?? installs;
  } catch (e) {
    approx = true;
    console.log("autopack: özet (sightings) sayılamadı", String(e?.message || e));
  }
  try {
    const row = await env.DB.prepare("SELECT COUNT(*) AS confirmed FROM lines WHERE installs>=?").bind(MIN_INSTALLS).first();
    confirmed = row?.confirmed ?? confirmed;
  } catch (e) {
    approx = true;
    console.log("autopack: özet (lines) sayılamadı", String(e?.message || e));
  }
  // Hiç eski özet yoksa ve ağır sorgu başarısızsa: onaylanmış satırlar alt sınırdır.
  const out = {
    lines: Number.isFinite(lines) ? lines : (Number.isFinite(confirmed) ? confirmed : 0),
    confirmed: Number.isFinite(confirmed) ? confirmed : 0,
    installs: Number.isFinite(installs) ? installs : 0,
    updated: now.toISOString(),
  };
  if (approx) out.approx = true;
  await putJson(env, STATS_KEY, out);
  return out;
}

/** Gecenin son tetiklemesi mi (cron 2-57/5 UTC 03–05)? Çevrilen oyunun paketi en geç bu tetiklemede kurulur. */
export function isFinalTick(now) {
  return now.getUTCHours() > LAST_HOUR_UTC
    || (now.getUTCHours() === LAST_HOUR_UTC && now.getUTCMinutes() >= LAST_MINUTE_UTC);
}

/** Oyunun satırlarından imleçten sonraki bir sayfa: installs azalan, key artan (anahtar imleci; sabit sıra). */
async function fetchPage(env, job, separate, cursor) {
  const after = cursor ? " AND (installs<? OR (installs=? AND key>?))" : "";
  const cur = cursor ? [cursor.n, cursor.n, cursor.k] : [];
  const tail = ` ORDER BY installs DESC, key LIMIT ${PAGE}`;
  let sql, args;
  if (job.titleId === GENERAL) {
    if (separate.size) {
      // Oyuna ayrılan satırları sayfadan önce süz; aksi halde en çok okunan satırlar ortak havuzu aç bırakır.
      // Oyun adlarını JSON tek bir bağlı parametreyle taşıyarak D1 değişken sayısı sınırına takılmayız.
      sql = "SELECT key, text, installs FROM lines WHERE title_id IS NULL AND installs>=? " +
        "AND (game IS NULL OR game NOT IN (SELECT value FROM json_each(?)))" + after + tail;
      args = [MIN_INSTALLS, JSON.stringify([...separate]), ...cur];
    } else {
      sql = "SELECT key, text, installs FROM lines WHERE title_id IS NULL AND installs>=?" + after + tail;
      args = [MIN_INSTALLS, ...cur];
    }
  } else if (job.titleId) {
    sql = "SELECT key, text, installs FROM lines WHERE title_id=? AND installs>=?" + after + tail;
    args = [job.titleId, MIN_INSTALLS, ...cur];
  } else {
    const games = (job.games?.length ? job.games : [job.game]).slice(0, MAX_VARIANTS);
    sql = `SELECT key, text, installs FROM lines WHERE title_id IS NULL AND game IN (${games.map(() => "?").join(",")}) ` +
      "AND installs>=?" + after + tail;
    args = [...games, MIN_INSTALLS, ...cur];
  }
  return (await env.DB.prepare(sql).bind(...args).all()).results ?? [];
}

/** Bir adım: gecenin ilk çağrısında plan, sonra sıradaki oyunda çeviri parçası ya da paket. Sonucu döner ve yazar. */
export async function runAutopack(env, now = new Date()) {
  if (!env.PACKS || (!env.AI && !env.ANTHROPIC_API_KEY)) return { phase: "disabled" };
  const limits = limitsFor(env);
  const night = now.toISOString().slice(0, 10);
  let state = await getJson(env, STATE);
  // A parseable but incomplete R2 state must not stall every remaining run of this night.
  // Replanning is safe: per-game translation caches are persisted separately.
  const validJob = (job) => job && typeof job === "object" && !Array.isArray(job)
    && ((typeof job.titleId === "string" && job.titleId.length > 0)
      || (job.titleId == null && typeof job.gameKey === "string" && job.gameKey.length > 0));
  const validState = state && Array.isArray(state.queue) && state.queue.every(validJob)
    && Array.isArray(state.done) && Number.isSafeInteger(state.translated) && state.translated >= 0
    && (state.namedGames == null || (Array.isArray(state.namedGames)
      && state.namedGames.every((game) => typeof game === "string")));
  const reservationsFromCaches = async (previous) => {
    const reservations = {};
    if (previous?.reservations && typeof previous.reservations === "object" && !Array.isArray(previous.reservations)) {
      for (const [id, amount] of Object.entries(previous.reservations)) {
        const usd = Number.isFinite(amount) ? amount : amount?.usd;
        if (typeof id === "string" && Number.isFinite(usd) && usd >= 0) reservations[id] = amount;
      }
    }
    const jobs = [
      ...(Array.isArray(previous?.titles) ? previous.titles : []),
      ...(Array.isArray(previous?.queue) ? previous.queue : []),
      ...(Array.isArray(previous?.done) ? previous.done : []),
    ]
      .filter(validJob);
    const unique = new Map(jobs.map((job) => [cacheFile(job), job]));
    const caches = await Promise.all([...unique.values()].map(async (job) => [job, await getJson(env, cacheFile(job))]));
    for (const [job, cache] of caches) {
      for (const batch of Array.isArray(cache?.batches) ? cache.batches : []) {
        if (!batch || typeof batch.id !== "string") continue;
        const entry = reservations[batch.id];
        const amount = Number.isFinite(entry) ? entry : entry?.usd;
        if (Number.isFinite(amount) && entry?.id === batch.id && validJob(entry?.job)) continue;
        const cachedUsd = Number.isFinite(batch.reservedUsd) && batch.reservedUsd >= 0
          ? batch.reservedUsd : batchReservation(batch.reqs, job.game, LEGACY_CLAUDE_MAX_TOKENS);
        reservations[batch.id] = {
          usd: Number.isFinite(amount) && amount >= 0 ? amount : cachedUsd,
          at: batch.at,
          id: batch.id,
          job: reservationJob(job),
        };
      }
      const pending = cache?.pendingBatch;
      if (pending?.attemptKey) {
        const tracked = reservations[pending.attemptKey]
          ?? Object.values(reservations).find((entry) => entry?.attemptKey === pending.attemptKey);
        if (!tracked) {
          // No durable state intent means the provider call was never made; retry from the saved cursor.
          if (pending.before && typeof pending.before === "object") Object.assign(cache, pending.before);
          delete cache.pendingBatch;
          await putJson(env, cacheFile(job), cache);
        }
      }
    }
    return reservations;
  };
  const withPendingJobs = (queue, reservations) => {
    const seen = new Set(queue.filter(validJob).map((job) => cacheFile(job)));
    const collectOnly = [];
    for (const reservation of Object.values(reservations ?? {})) {
      const job = reservation?.job;
      if (!validJob(job)) continue;
      const file = cacheFile(job);
      if (seen.has(file)) continue;
      seen.add(file);
      collectOnly.push({ ...job, collectOnly: true });
    }
    return queue.concat(collectOnly);
  };
  const reservationMapValid = state?.reservations && typeof state.reservations === "object"
    && !Array.isArray(state.reservations) && Object.values(state.reservations).every((entry) => {
      const usd = Number.isFinite(entry) ? entry : entry?.usd;
      return Number.isFinite(usd) && usd >= 0;
    });
  // İlk dağıtımda eski batch kayıtları da hesaba katılır. Rezerv defteri sonraki gecelere taşınır.
  if (state && (state.reservationVersion !== 1 || !reservationMapValid
    || state.night !== night || !validState)) {
    state.reservations = await reservationsFromCaches(state);
    state.reservationVersion = 1;
    if (state.night === night && validState) {
      state.queue = withPendingJobs(state.queue, state.reservations);
      await putJson(env, STATE, state);
    }
  }
  if (state?.night !== night || !validState) {
    const { results } = await env.DB.prepare(
      "SELECT title_id, MAX(game) AS game, COUNT(*) AS lines FROM lines WHERE title_id IS NOT NULL AND installs>=? " +
      "GROUP BY title_id ORDER BY lines DESC LIMIT 50"
    ).bind(MIN_INSTALLS).all();
    const packs = await readIndex(env);
    const titles = results.map((r) => ({ titleId: r.title_id, game: r.game, lines: r.lines }));
    // Kimliksiz ama adıyla gelen oyunlar: adın anahtarına göre birleşir, en az iki kurulumun oyladığı ayrı iş olur.
    const voted = await allRows(env.DB.prepare(
      "SELECT game_key, COUNT(*) AS installs FROM game_votes GROUP BY game_key HAVING COUNT(*)>=?"
    ).bind(MIN_VOTERS));
    const votes = new Map(voted.map((r) => [r.game_key, r.installs]));
    const named = votes.size ? nameJobs(await allRows(env.DB.prepare(
      "SELECT game, COUNT(*) AS lines FROM lines WHERE title_id IS NULL AND game IS NOT NULL AND installs>=? " +
      "GROUP BY game ORDER BY lines DESC LIMIT 300"
    ).bind(MIN_INSTALLS)), votes).slice(0, 30) : [];
    titles.push(...named);
    const general = await env.DB.prepare("SELECT COUNT(*) AS lines FROM lines WHERE title_id IS NULL AND installs>=?")
      .bind(MIN_INSTALLS).first();
    // Named jobs may fail to reach the cleaned MIN_LINES threshold. Keep a general job
    // scheduled until they have actually published; only then can their rows be excluded.
    titles.push({ titleId: GENERAL, game: null, lines: general?.lines ?? 0 });
    // Ham satır sayısı temizlikten önce: eşiğin altındaki oyun beklemeye kalır (paketi zaten varsa güncellenir).
    let queue = titles.filter((t) => t.lines >= MIN_LINES || packs.some((p) => p.id === jobPackId(t)));
    // Ortak paket, kendi paketi hazırlanan adların satırlarını almaz.
    const namedGames = named.filter((g) => queue.includes(g)).flatMap((g) => g.games);
    // Listedeki adı değişecek otomatik paket ("(ek satırlar)" eklenecek ya da kalkacak) çevirisiz, en başta yeniden
    // yazılır: büyük bir oyunun çevirisi bütün geceyi alıp sıra ona hiç gelmeyebilir.
    const retitle = queue.filter((t) => {
      const listed = packs.find((p) => p.id === jobPackId(t));
      return listed?.auto && listed.title !== packTitle(t, packs);
    });
    queue = retitle.map((t) => ({ ...t, retitle: true })).concat(queue.filter((t) => !retitle.includes(t)));
    queue = withPendingJobs(queue, state?.reservations);
    state = {
      night, titles, queue, namedGames, translated: 0, done: [], usd: 0,
      reservationVersion: 1, reservations: state?.reservations ?? {},
    };
    await putJson(env, STATE, state);
    // Plan yazıldıktan sonra gecelik özet: ağır sorgu çevirinin önüne geçmez, hatası geceyi düşürmez.
    let summary = null;
    try { summary = await computeStats(env, now); } catch (e) {
      console.log("autopack: özet yazılamadı", String(e?.message || e));
    }
    return { phase: "plan", titles: titles.length, queued: queue.length, stats: summary };
  }
  const job = state.queue[0];
  if (!job) return { phase: "idle", done: state.done };

  const known = await loadKnown(env);
  if (!known) return { phase: "waiting", reason: "auto/known-keys.bin yok" };
  const cache = await loadCache(env, job);
  const releaseMissingJobReservations = () => {
    let usd = 0;
    for (const [id, entry] of Object.entries(state.reservations ?? {})) {
      if (!validJob(entry?.job) || cacheFile(entry.job) !== cacheFile(job)) continue;
      usd += reservationAmount(entry);
      delete state.reservations[id];
    }
    state.usd = (state.usd ?? 0) + usd;
    return usd;
  };
  if (!cache) {
    const usd = releaseMissingJobReservations();
    if (!job.collectOnly) {
      if (usd) await putJson(env, STATE, state);
      return { phase: "waiting", reason: "auto/translation cache invalid" };
    }
    state.queue.shift();
    state.done.push({ ...job, collectedOnly: true, missingCache: true });
    await putJson(env, STATE, state);
    return { phase: "settled", titleId: job.titleId, game: job.gameKey, usd };
  }
  cache.fail ??= {};
  cache.batches ??= [];
  state.reservations ??= {};
  let reservationChanged = false;

  const pending = cache.pendingBatch;
  if (pending?.attemptKey) {
    const matches = Object.entries(state.reservations).find(([id, entry]) =>
      id === pending.attemptKey || entry?.attemptKey === pending.attemptKey);
    const entry = matches?.[1];
    if (!entry) {
      // The state intent was not durable, so submitBatch was never called.
      if (pending.before && typeof pending.before === "object") Object.assign(cache, pending.before);
      delete cache.pendingBatch;
      reservationChanged = true;
    } else if (entry.id) {
      if (!cache.batches.some((batch) => batch.id === entry.id)) {
        cache.batches.push({ id: entry.id, at: pending.at, reqs: pending.reqs, reservedUsd: reservationAmount(entry) });
      }
      delete cache.pendingBatch;
      reservationChanged = true;
    } else if (entry.attempt) {
      // POST outcome is unknown and Anthropic has no idempotency key; count the reserve and never resend it.
      const usd = Math.max(reservationAmount(entry), reservationAmount(pending.reservedUsd));
      const attemptedLines = Object.values(pending.reqs ?? {}).reduce((sum, lines) =>
        sum + (Array.isArray(lines) ? lines.length : 0), 0);
      state.usd = (state.usd ?? 0) + usd;
      for (const lines of Object.values(pending.reqs ?? {})) if (Array.isArray(lines)) failLines(cache, lines);
      if (!job.collectOnly && Number.isFinite(entry.at) && new Date(entry.at).toISOString().slice(0, 10) === night) {
        state.translated += attemptedLines;
        job.did = (job.did ?? 0) + attemptedLines;
      }
      delete state.reservations[matches[0]];
      delete cache.pendingBatch;
      reservationChanged = true;
    }
  }

  for (const batch of cache.batches) {
    const existing = state.reservations[batch.id];
    const existingUsd = reservationAmount(existing);
    const cachedUsd = Number.isFinite(batch.reservedUsd) && batch.reservedUsd >= 0
      ? batch.reservedUsd : batchReservation(batch.reqs, job.game, LEGACY_CLAUDE_MAX_TOKENS);
    const amount = existingUsd > 0 ? existingUsd : cachedUsd;
    if (!validJob(existing?.job) || existing.id !== batch.id) {
      state.reservations[batch.id] = { usd: amount, at: batch.at, id: batch.id, job: reservationJob(job) };
      reservationChanged = true;
    }
    if (batch.reservedUsd !== amount) {
      batch.reservedUsd = amount;
      reservationChanged = true;
    }
  }

  const cacheBatchIds = new Set(cache.batches.map((batch) => batch.id));
  for (const [id, entry] of Object.entries(state.reservations)) {
    if (!validJob(entry?.job) || cacheFile(entry.job) !== cacheFile(job)) continue;
    if (entry.attempt) {
      // Without the marker, a completed-but-unpersisted ambiguous attempt cannot be distinguished from a pre-POST failure.
      state.usd = (state.usd ?? 0) + reservationAmount(entry);
      delete state.reservations[id];
      reservationChanged = true;
    } else if (!entry.id || !cacheBatchIds.has(entry.id)) {
      // Cache was saved but the matching state update failed; settle conservatively to release the reservation.
      state.usd = (state.usd ?? 0) + reservationAmount(entry);
      delete state.reservations[id];
      reservationChanged = true;
    }
  }
  // Claude: önce bekleyen batch'lerden bitenleri topla (çeviri Batches ile gider, sonuç sonraki tetiklemelerde gelir).
  const claude = Boolean(env.ANTHROPIC_API_KEY);
  let collected = null;
  if (!claude && cache.batches.length) {
    let usd = 0;
    for (const batch of cache.batches) {
      usd += reservationAmount(state.reservations[batch.id] ?? batch.reservedUsd);
      failLines(cache, Object.values(batch.reqs).flat());
      delete state.reservations[batch.id];
    }
    state.usd = (state.usd ?? 0) + usd;
    cache.batches = [];
    reservationChanged = true;
  }
  if (claude && cache.batches.length) {
    collected = await collectBatches(env, cache);
    state.usd = (state.usd ?? 0) + collected.usd;
    for (const id of collected.settled) {
      if (Object.hasOwn(state.reservations, id)) {
        delete state.reservations[id];
        reservationChanged = true;
      }
    }
    state.claudeIn = (state.claudeIn ?? 0) + collected.input;
    state.claudeOut = (state.claudeOut ?? 0) + collected.output;
    state.collected = (state.collected ?? 0) + collected.lines;
    if (collected.lines) cache.touched = night;
  }
  const overBudget = claude && (state.usd ?? 0) + reservedUsd(state) >= NIGHT_BUDGET_USD;
  const saveCollected = async () => {
    if (!collected && !reservationChanged) return;
    await putJson(env, cacheFile(job), cache);
    await putJson(env, STATE, state);
  };
  if (job.collectOnly && cache.batches.length === 0) {
    const usd = releaseMissingJobReservations();
    await saveCollected();
    state.queue.shift();
    state.done.push({ ...job, collectedOnly: true, usd });
    await putJson(env, STATE, state);
    return { phase: "settled", titleId: job.titleId, game: job.gameKey, usd };
  }
  // Exclude named rows only when their individual pack was actually published or
  // confirmed unchanged. An unbuilt named pack must fall back into the general pool.
  const published = new Set(state.done
    .filter((finished) => finished?.gameKey && (finished.built || finished.unchanged))
    .flatMap((finished) => finished.games?.length ? finished.games : [finished.game]));
  const separate = new Set((state.namedGames ?? []).filter((name) => published.has(name)));
  const want = Math.min(limits.linesPerRun, limits.nightly - state.translated, limits.jobNightly - (job.did ?? 0));
  const todo = [];
  let looked = 0;
  let scanned = 0;
  // Gezinti ya da gecelik pay bitti, gecenin son tetiklemesi (bu gece çevrilen paket kurulur) ya da yalnız yeniden
  // adlandırma: çeviri yok, paket kurulur.
  let exhausted = job.retitle || job.collectOnly || cache.passNight === night || want <= 0 || overBudget
    || (isFinalTick(now) && cache.touched === night);
  // Bekleyen batch sınırı doluysa bu tetiklemede yeni satır gönderilmez (gezinti de ilerlemez).
  const full = claude && cache.batches.length >= MAX_PENDING_BATCHES;
  const before = { cursor: cache.cursor, skip: cache.skip, passNight: cache.passNight };
  // Anahtar imleci: installs azalan, key artan sırada kaldığımız yerden devam eder. İmlecin gerisindeki satırlara bu
  // geçişte bir daha bakılmaz, o yüzden atlananlar (bilinen, çöp) skip'e yazılmaz; önbellek ve D1 okuması küçük kalır.
  for (let page = 0; !exhausted && !full && page < MAX_PAGES && todo.length < want && looked < limits.maxLook; page++) {
    const rows = await fetchPage(env, job, separate, cache.cursor);
    let stopped = false;
    for (const r of rows) {
      if (todo.length >= want || looked >= limits.maxLook) { stopped = true; break; }
      cache.cursor = { n: r.installs, k: r.key };
      scanned++;
      if (cache.lines[r.key] || cache.skip[r.key]) continue;
      looked++;
      const clean = cleanLine(r.text);
      const k = clean ? (clean.labelled ? await key(clean.body) : r.key) : "";
      if (!clean || !k || isKnown(known, k) || isKnown(known, r.key)) continue;
      todo.push({ pool: r.key, k, en: clean.body, cursor: { n: r.installs, k: r.key } });
    }
    // Sayfa dolu değilse ve hepsi işlendiyse imleç sona ulaştı: gezinti bitti, sonraki geçiş baştan başlar.
    if (!stopped && rows.length < PAGE) {
      exhausted = true;
      cache.cursor = null;
      cache.skip = Object.fromEntries(Object.entries(cache.skip).filter(([, v]) => v === 2));
      cache.passNight = night;
    }
  }

  if (todo.length > 0 && claude) {
    const available = NIGHT_BUDGET_USD - (state.usd ?? 0) - reservedUsd(state);
    const affordable = affordablePrefixLength(todo, job.game, limits.batch, available);
    if (affordable < todo.length) {
      // Bütçeye sığan ön eki gönder; cursor geri kalan satırları sonraki tetiklemeye bırakır.
      if (affordable > 0) {
        todo.length = affordable;
        cache.cursor = todo[affordable - 1].cursor;
        cache.skip = before.skip;
        cache.passNight = before.passNight;
      } else {
        // Bütçeye sığan satır yok; cursor ilerleyip satırları atlamasın.
        Object.assign(cache, before);
        exhausted = true;
        todo.length = 0;
      }
    }
  }

  if (todo.length > 0 && claude) {
    const attemptKey = `attempt:${crypto.randomUUID()}`;
    const reqs = requestsFor(todo, limits.batch);
    const reservation = batchReservation(reqs, job.game);
    cache.pendingBatch = { attemptKey, at: now.getTime(), reqs, reservedUsd: reservation, before };
    state.reservations[attemptKey] = {
      usd: reservation, at: now.getTime(), job: reservationJob(job), attempt: true, attemptKey,
    };
    // Hem cursor hem rezerv POST'tan önce kalıcı olmalı; aksi halde R2 hatası aynı batch'i tekrar gönderebilir.
    await putJson(env, cacheFile(job), cache);
    await putJson(env, STATE, state);

    const batch = await submitBatch(env, todo, job.game, limits.batch, now);
    if (batch?.failure) {
      if (batch.ambiguous) {
        // POST kabul edilmiş olabilir; intent ve rezerv kalsın, sonraki çağrı tekrar göndermesin.
        await putJson(env, STATE, state);
        return { phase: "error", titleId: job.titleId, game: job.gameKey, collected: collected?.lines ?? 0 };
      }
      // Kesin ret: cursor'ı geri al ve rezervi bırak.
      delete state.reservations[attemptKey];
      delete cache.pendingBatch;
      Object.assign(cache, before);
      await putJson(env, cacheFile(job), cache);
      await putJson(env, STATE, state);
      return { phase: "error", titleId: job.titleId, game: job.gameKey, collected: collected?.lines ?? 0 };
    }
    delete state.reservations[attemptKey];
    state.reservations[batch.id] = {
      usd: batch.reservedUsd, at: batch.at, id: batch.id, attemptKey, job: reservationJob(job),
    };
    state.translated += todo.length;
    job.did = (job.did ?? 0) + todo.length;
    // ID'yi cache'i değiştirmeden önce yaz: sonradan cache PUT başarısız olursa pending intent'ten onarılabilir.
    await putJson(env, STATE, state);
    delete cache.pendingBatch;
    cache.batches.push(batch);
    await putJson(env, cacheFile(job), cache);
    return { phase: "submit", titleId: job.titleId, game: job.gameKey, looked, submitted: todo.length,
      batch: batch.id, collected: collected?.lines ?? 0 };
  }

  if (todo.length > 0) {
    // Workers AI: eşzamanlı, sırayla.
    for (let i = 0; i < todo.length; i += limits.batch) {
      const chunk = todo.slice(i, i + limits.batch);
      applyTranslations(cache, chunk, await translateWorkersAI(env, chunk, job.game));
    }
    state.translated += todo.length;
    job.did = (job.did ?? 0) + todo.length;
    cache.touched = night;
    await putJson(env, cacheFile(job), cache);
    await putJson(env, STATE, state);
    return { phase: "translate", titleId: job.titleId, game: job.gameKey, looked, translated: todo.length };
  }

  // Yeni çevrilecek satır çıkmadı ama gezinti sürüyor (önbellekte olanlar atlandı): imleci kaydet, paket kurma.
  if (!exhausted && !full && scanned > 0 && cache.cursor) {
    await putJson(env, cacheFile(job), cache);
    if (collected || reservationChanged) await putJson(env, STATE, state);
    return { phase: "scan", titleId: job.titleId, game: job.gameKey, scanned, collected: collected?.lines ?? 0 };
  }

  // Bekleyen batch var: gezinti sürüyorsa (yer açılmasını bekliyor) ya da bitti ama batch henüz taze ise beklenir.
  // Gecenin son tetiklemesinde paket kurulur; geç kalan batch ertesi gece toplanır.
  if (job.collectOnly && cache.batches.length) {
    await saveCollected();
    if (state.queue.length > 1) {
      state.queue.shift();
      state.queue.push(job);
      await putJson(env, STATE, state);
    }
    return { phase: "wait", titleId: job.titleId, game: job.gameKey, pending: cache.batches.length,
      collected: collected?.lines ?? 0 };
  }

  if (cache.batches.length && !isFinalTick(now)) {
    const oldest = Math.min(...cache.batches.map((b) => b.at));
    if (!exhausted || now.getTime() - oldest < BATCH_WAIT_MS) {
      await saveCollected();
      return { phase: "wait", titleId: job.titleId, game: job.gameKey, pending: cache.batches.length,
        collected: collected?.lines ?? 0 };
    }
  }

  // Toplanan çeviriler paketten önce önbelleğe (paket değişmese de kaybolmasın).
  await saveCollected();
  // Çevrilecek yeni satır kalmadı (ya da gecenin sınırı doldu): paket.
  const result = await buildPack(env, job, cache, known);
  state.queue.shift();
  state.done.push({ ...job, ...result });
  if (cache.batches.length && !state.queue.some((queued) => validJob(queued) && cacheFile(queued) === cacheFile(job))) {
    state.queue.push({ ...reservationJob(job), collectOnly: true });
  }
  await putJson(env, STATE, state);
  return { phase: "build", titleId: job.titleId, game: job.gameKey, ...result, collected: collected?.lines ?? 0 };
}
