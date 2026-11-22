// SPDX-License-Identifier: AGPL-3.0-only
// Elle hazırlanmış paketlerin (varsayılan: core/Sources/CouchSubsCore/Resources/packs) bütün anahtarlarını (entries +
// segments) sıralı 64 bit sayılar olarak yazar. Havuzdan otomatik paket (src/autopack.js) bu anahtarları atlar: elle
// hazırlanmış paket öncelikli. Yeni elle paket R2'ye konunca yeniden üretilip yüklenir:
//   node scripts/build-known.mjs [paket-klasörü] > known-keys.bin
//   npx wrangler r2 object put couchsubs-packs/auto/known-keys.bin --file known-keys.bin --remote
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";

const dir = process.argv[2] ?? fileURLToPath(new URL("../../../core/Sources/CouchSubsCore/Resources/packs", import.meta.url));
const keys = new Set();
for (const name of readdirSync(dir).filter((n) => n.endsWith(".json.gz") && !n.startsWith("pool-"))) {
  const pack = JSON.parse(gunzipSync(readFileSync(join(dir, name))).toString("utf8"));
  for (const k of [...Object.keys(pack.entries ?? {}), ...Object.keys(pack.segments ?? {})]) {
    // BigUint64Array silently truncates keys beyond 64 bits. Refuse malformed input
    // before emitting a known-keys file that cannot protect manual translations.
    if (!/^[0-9a-f]{16}$/i.test(k)) throw new Error("Invalid 64-bit subtitle key in " + name + ": " + k);
    keys.add(BigInt("0x" + k));
  }
}
// If the private packs were not fetched, emitting an empty file would silently
// remove protection for manual translations after upload to R2.
if (keys.size === 0) throw new Error("No manual subtitle keys found; refusing empty known-keys index");
const list = BigUint64Array.from([...keys].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)));
process.stderr.write(`${list.length} anahtar\n`);
process.stdout.write(Buffer.from(list.buffer));
