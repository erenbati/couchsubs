// SPDX-License-Identifier: AGPL-3.0-only
// Havuzdan kendiliğinden oyun paketi (Cron Trigger, her gece 03:07–04:57 UTC arasında on dakikada bir).
//
// Bir oyunun (title_id; kimlik yoksa src/games.js'teki anahtarıyla oyun adı) satırları en az MIN_INSTALLS farklı kurulumda aynı biçimde (aynı canon anahtarla) okunduysa
// tools/packs/poolpack.py'deki kurallarla temizlenir, Workers AI ile Türkçeye çevrilir ve R2'ye (couchsubs-packs kovası)
// `packs/pool-<oyun kimliği>.json.gz` olarak yazılır; index.json'a sürümü artırılarak girer. Uygulamalar paketi
// kendileri indirir (server/packs). Yeni kimlik bilgisi yoktur: D1, R2 ve Workers AI bu Worker'ın bağlarıdır.
//
// Elle hazırlanmış (uygulamayla gelen) paketler öncelikli: onlardaki anahtarlar (R2'de auto/known-keys.bin,
// scripts/build-known.mjs üretir) otomatik pakete hiç girmez, böylece iki paket aynı satırda çakışmaz; otomatik paket
// elle olanın eksiğini tamamlar.
//
// Workers Free planında çağrı başına CPU süresi 10 ms: iş küçük adımlara bölünür ve her tetiklemede bir adım yapılır
// (gecenin ilk tetiklemesi plan, sonrakiler oyun başına çeviri parçaları ve en son paket). Durum R2'de auto/state.json.

import { accepts } from "./filter.js";
import { canon, key } from "./index.js";
import { gameKey, gameSlug } from "./games.js";

/** Bir satırın pakete girmesi için onu okuyan en az farklı kurulum sayısı. */
export const MIN_INSTALLS = 2;
/** Bir oyunun ilk paketi için en az çevrilmiş satır; paket bir kez çıktıktan sonra her yeni satır eklenir. */
export const MIN_LINES = 300;
/** Bir tetiklemede en çok bu kadar yeni satır çevrilir (CPU sınırı). */
export const LINES_PER_RUN = 200;
/** Bir gecede en çok bu kadar satır çevrilir (Workers AI'ın günlük ücretsiz 10.000 nöronunun yarısından azı). */
export const NIGHTLY_LIMIT = 3000;
export const BATCH = 40;
export const MODEL = "@cf/google/gemma-4-26b-a4b-it";
export const SOURCE = `CouchSubs havuzu (en az ${MIN_INSTALLS} oyuncu) + Workers AI (${MODEL})`;
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
const cacheFile = (job) => (job.titleId ? `auto/tr/${job.titleId}.json` : `auto/tr/name-${gameSlug(job.gameKey)}.json`);

// poolpack.py ile aynı: konuşmacı etiketi, Türkçe harf, yazı tanıma çöpü.
const LABEL = /^[-•\s]*([A-Z][A-Za-z .'’-]{1,28}?)\s*[•:]\s+(?=\S)/;
const TURKISH = /[ğĞşŞıİ]/u;
const OCR_JUNK = /[$#@|\\{}<>~^_=]|[\p{L}\p{N}_][%&*][\p{L}\p{N}_]/u;
// Üç ve daha çok sözcüklü satırda en az bir yaygın İngilizce sözcük: bozuk okunmuş Türkçe arayüz ("Yeni ipuqlarl Var
// Daha Fazlaslnl") Türkçe harf taşımadığı için ayrıca elenir.
const ENGLISH = new Set(("the a an to of and or but with for from my your his her their our at in on by is are was were be " +
  "i you he she it we they me him us them this that what who where when why how not no yes do did don't can can't will " +
  "won't just get got go have has had all there here now up out if so like know want need come one some about").split(" "));

/** Oyun kimliğinden paket kimliği: "PPSA01234" → "pool-ppsa01234" (server/packs'in kimlik biçimine uyar). */
export function packId(titleId) {
  return "pool-" + String(titleId).toLowerCase().replace(/[^a-z0-9]+/g, "-");
}

/** İşin paket kimliği: oyun kimliği varsa ondan, yoksa adın anahtarından ("gta 6" → "pool-gta-6"). */
export function jobPackId(job) {
  return job.titleId ? packId(job.titleId) : "pool-" + gameSlug(job.gameKey);
}

/** Kimliksiz satırların oyun adları ("game" sütunu, yazımına göre sayılmış) anahtara göre birleşir; en az MIN_VOTERS
 *  kurulumun oyladığı anahtarlar iş olur. Görünen ad en çok satırı olan yazımdır. */
export function nameJobs(rows, votes) {
  const groups = new Map();
  for (const r of rows) {
    const k = gameKey(r.game);
    if (!k || !gameSlug(k) || gameSlug(k) === "genel") continue;
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

/** Satırları Workers AI ile çevirir; id → Türkçe. Yanıt bozuksa boş. */
export async function translate(env, items, game) {
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

export function parseReply(reply, items) {
  let content = reply?.choices?.[0]?.message?.content ?? reply?.response;
  let parsed = content;
  if (typeof content === "string") {
    const text = content.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
    try { parsed = JSON.parse(text); } catch { return new Map(); }
  }
  const out = new Map();
  for (const it of parsed?.items ?? []) {
    const i = Number(it?.id);
    const tr = typeof it?.tr === "string" ? it.tr.replace(/\s+/g, " ").trim() : "";
    if (!Number.isInteger(i) || !items[i] || !tr) continue;
    // Açıklama ya da birden çok satır yazmış, çok uzun ya da Türkçe değil: alınmaz.
    if (/[{}]/.test(tr) || tr.length > items[i].en.length * 3 + 40) continue;
    out.set(i, tr);
  }
  return out;
}

async function getJson(env, name) {
  const object = await env.PACKS.get(name);
  if (!object) return null;
  try { return JSON.parse(await object.text()); } catch { return null; }
}

const putJson = (env, name, value) =>
  env.PACKS.put(name, JSON.stringify(value), { httpMetadata: { contentType: "application/json" } });

async function loadKnown(env) {
  const object = await env.PACKS.get(KNOWN);
  if (!object) return null;
  const buffer = await object.arrayBuffer();
  // Bozuk veya sıralanmamış indeksle binary search doğru çalışmaz; elle hazırlanan çevirileri koru.
  if (buffer.byteLength % 8 !== 0) return null;
  const known = new BigUint64Array(buffer);
  for (let i = 1; i < known.length; i++) if (known[i] <= known[i - 1]) return null;
  return known;
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
  return (await getJson(env, "index.json"))?.packs ?? [];
}

async function buildPack(env, job, cache, known) {
  const id = jobPackId(job);
  const title = job.titleId === GENERAL ? GENERAL_TITLE : job.game || job.titleId;
  const { body, count } = packBody(id, title, cache, known, job.titleId === GENERAL ? null : job.titleId);
  const packs = await readIndex(env);
  const previous = packs.find((p) => p.id === id);
  if (!previous && count < MIN_LINES) return { id, built: false, entries: count };
  const contentSha = await sha256Hex(new TextEncoder().encode(body));
  if (previous && cache.contentSha === contentSha) return { id, built: false, unchanged: true, entries: count };
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

/** Bir adım: gecenin ilk çağrısında plan, sonra sıradaki oyunda çeviri parçası ya da paket. Sonucu döner ve yazar. */
export async function runAutopack(env, now = new Date()) {
  if (!env.PACKS || !env.AI) return { phase: "disabled" };
  const night = now.toISOString().slice(0, 10);
  let state = await getJson(env, STATE);
  if (state?.night !== night) {
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
    const namedLines = named.reduce((sum, g) => sum + g.lines, 0);
    titles.push({ titleId: GENERAL, game: null, lines: Math.max(0, (general?.lines ?? 0) - namedLines) });
    // Ham satır sayısı temizlikten önce: eşiğin altındaki oyun beklemeye kalır (paketi zaten varsa güncellenir).
    const queue = titles.filter((t) => t.lines >= MIN_LINES || packs.some((p) => p.id === jobPackId(t)));
    // Ortak paket, kendi paketi hazırlanan adların satırlarını almaz.
    const namedGames = named.filter((g) => queue.includes(g)).flatMap((g) => g.games);
    state = { night, titles, queue, namedGames, translated: 0, done: [] };
    await putJson(env, STATE, state);
    return { phase: "plan", titles: titles.length, queued: queue.length };
  }
  const job = state.queue[0];
  if (!job) return { phase: "idle", done: state.done };

  const known = await loadKnown(env);
  if (!known) return { phase: "waiting", reason: "auto/known-keys.bin yok" };
  const cache = (await getJson(env, cacheFile(job))) ?? { lines: {}, skip: {}, fail: {} };
  cache.fail ??= {};
  const separate = new Set(state.namedGames ?? []);
  let rows;
  if (job.titleId === GENERAL) {
    if (separate.size) {
      // Oyuna ayrılan satırları LIMIT'ten önce süz; aksi halde en çok okunan 5000 ad satırı ortak havuzu aç bırakır.
      // Oyun adlarını JSON tek bir bağlı parametreyle taşıyarak D1 değişken sayısı sınırına takılmayız.
      ({ results: rows } = await env.DB.prepare(
        "SELECT key, text FROM lines WHERE title_id IS NULL AND installs>=? " +
        "AND (game IS NULL OR game NOT IN (SELECT value FROM json_each(?))) " +
        "ORDER BY installs DESC, last_seen DESC LIMIT 5000"
      ).bind(MIN_INSTALLS, JSON.stringify([...separate])).all());
    } else {
      ({ results: rows } = await env.DB.prepare(
        "SELECT key, text FROM lines WHERE title_id IS NULL AND installs>=? ORDER BY installs DESC, last_seen DESC LIMIT 5000"
      ).bind(MIN_INSTALLS).all());
    }
  } else if (job.titleId) {
    ({ results: rows } = await env.DB.prepare(
      "SELECT key, text FROM lines WHERE title_id=? AND installs>=? ORDER BY installs DESC LIMIT 5000"
    ).bind(job.titleId, MIN_INSTALLS).all());
  } else {
    const games = (job.games?.length ? job.games : [job.game]).slice(0, MAX_VARIANTS);
    ({ results: rows } = await env.DB.prepare(
      `SELECT key, text FROM lines WHERE title_id IS NULL AND game IN (${games.map(() => "?").join(",")}) AND installs>=? ` +
      "ORDER BY installs DESC LIMIT 5000"
    ).bind(...games, MIN_INSTALLS).all());
  }

  const budget = Math.min(LINES_PER_RUN, NIGHTLY_LIMIT - state.translated);
  const todo = [];
  let looked = 0;
  for (const r of rows) {
    if (looked >= budget) break;
    if (cache.lines[r.key] || cache.skip[r.key]) continue;
    looked++;
    const clean = cleanLine(r.text);
    const k = clean ? (clean.labelled ? await key(clean.body) : r.key) : "";
    if (!clean || !k || isKnown(known, k) || isKnown(known, r.key)) {
      cache.skip[r.key] = 1;
      continue;
    }
    todo.push({ pool: r.key, k, en: clean.body });
  }

  if (looked > 0) {
    for (let i = 0; i < todo.length; i += BATCH) {
      const chunk = todo.slice(i, i + BATCH);
      const got = await translate(env, chunk, job.game);
      chunk.forEach((line, j) => {
        const tr = got.get(j);
        if (tr) {
          cache.lines[line.pool] = { k: line.k, en: line.en, tr };
          delete cache.fail[line.pool];
        } else if ((cache.fail[line.pool] = (cache.fail[line.pool] || 0) + 1) >= 2) {
          // İki kez çevrilemeyen satır bırakılır (sonsuz döngü olmasın).
          cache.skip[line.pool] = 1;
          delete cache.fail[line.pool];
        }
      });
    }
    state.translated += todo.length;
    await putJson(env, cacheFile(job), cache);
    await putJson(env, STATE, state);
    return { phase: "translate", titleId: job.titleId, game: job.gameKey, looked, translated: todo.length };
  }

  // Çevrilecek yeni satır kalmadı (ya da gecenin sınırı doldu): paket.
  const result = await buildPack(env, job, cache, known);
  state.queue.shift();
  state.done.push({ ...job, ...result });
  await putJson(env, STATE, state);
  return { phase: "build", titleId: job.titleId, game: job.gameKey, ...result };
}
