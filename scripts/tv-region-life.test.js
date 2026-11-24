// SPDX-License-Identifier: AGPL-3.0-only
// #1198: ek alanın (otomatik ekran yazısı, ayar menüsü, tabela) çevirisi gönderici yenilemezse ya da temizlemezse TV'de
// REGION_LIFE_MS sonra kendiliğinden kalkar; telefon kartı kalmaz. Göndericinin "keep" yenilemesi alanı yeniden çizmez,
// katmanların sırasını değiştirmez, yalnız ömrünü uzatır (tv-webos/app.js showRegion, expireRegions). Gerçek Chromium.
// node --test scripts/tv-region-life.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const root = path.join(__dirname, '..', 'tv-webos');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));

const surface = { background: '#1c2340', foreground: '#ffffff', flat: true };
const style = { bold: false, condensed: false, align: 'left', upper: false };
const block = (text, left, top, right, bottom) => ({ text, box: { left, top, right, bottom }, line: bottom - top, surface, style });

function render() {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const start = app.indexOf('  var screenTimer = null;');
  const end = app.indexOf('\n  //', app.indexOf('  function hideScreen()', start));
  const regionStart = app.indexOf('  var regionBoxes = {};');
  const regionEnd = app.indexOf('\n  //', app.indexOf('  function hideRegions()', regionStart));
  const validStart = app.indexOf('  function validBox(box)');
  const validEnd = app.indexOf('\n  //', validStart);
  assert.ok(start > 0 && end > start && validStart > 0 && validEnd > validStart && regionStart > 0 && regionEnd > regionStart,
    'TV işlevleri bulunamadı');
  assert.ok(app.indexOf('setInterval(function () { expireRegions(Date.now()); }, 1000);') > 0, 'Ömür denetimi kurulmamış');
  assert.ok(app.indexOf("onEvent('region-sync', syncRegions);") > 0, 'region-sync dinlenmiyor');
  const fillStart = app.indexOf('  function fillText(');
  const fillEnd = app.indexOf('\n  }\n', fillStart) + 4;
  const needsFill = [app.slice(start, end), app.slice(validStart, validEnd), app.slice(regionStart, regionEnd)]
    .every(part => part.indexOf('function fillText(') < 0);
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-region-life-test-'));
  try {
    const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}
      body { margin:0; background:#3040a0; }</style>
      <div id="regions" class="hidden"></div><div id="screen" class="hidden"></div><pre id="result"></pre><script>
      function $(id) { return document.getElementById(id); }
      function hideSubtitle() {}
      var diag = { regions: 0, big: 0 };
      ${app.slice(validStart, validEnd)}
      ${needsFill ? app.slice(fillStart, fillEnd) : ''}
      ${app.slice(start, end)}
      ${app.slice(regionStart, regionEnd)}
      var clock = 1000000;
      Date.now = function () { return clock; };
      var result = {};
      var menu = ${JSON.stringify(block('Ses Ayarları', 0.1, 0.1, 0.3, 0.14))};
      var sign = ${JSON.stringify(block('Benzin İstasyonu', 0.6, 0.3, 0.8, 0.34))};
      var phone = ${JSON.stringify(block('Neredesin?', 0.7, 0.6, 0.9, 0.65))};
      showRegion({ id: 'auto-1', text: 'm', box: menu.box, blocks: [menu] });
      showRegion({ id: 'auto-2', text: 's', box: sign.box, blocks: [sign] });
      showRegion({ id: 'game-phone', text: 'p', box: phone.box, blocks: [phone] });
      var first = regionBoxes['auto-1'];
      var stamp = first.couchsubsStamp;
      // Gönderici auto-1'i 5 sn'de bir yeniler: aynı öğe kalır, katman sırası değişmez.
      clock += 5000; showRegion({ id: 'auto-1', text: 'm', box: menu.box, blocks: [menu], keep: true });
      clock += 5000; showRegion({ id: 'auto-1', text: 'm', box: menu.box, blocks: [menu], keep: true });
      result.sameElement = regionBoxes['auto-1'] === first;
      result.sameStamp = regionBoxes['auto-1'].couchsubsStamp === stamp;
      clock += 4999;
      result.before = expireRegions(clock);
      clock += 1;
      // auto-2 15 sn'dir yenilenmedi: kalkar. Yenilenen auto-1 ve telefon kartı kalır.
      result.expired = expireRegions(clock);
      result.left = Object.keys(regionBoxes).sort();
      // Yenileme gelmezse auto-1 de kalkar; telefon kartı hiç kalkmaz.
      clock += 15000;
      result.later = expireRegions(clock);
      result.phoneLeft = Object.keys(regionBoxes);
      // Kalkmış alanın yenilemesi (TV bir an kopmuştu) alanı yeniden çizer.
      showRegion({ id: 'auto-1', text: 'm', box: menu.box, blocks: [menu], keep: true });
      result.redrawn = !!regionBoxes['auto-1'] && regionBoxes['auto-1'] !== first;
      // İçeriği farklı yenileme de yeniden çizilir.
      var drawn = regionBoxes['auto-1'];
      showRegion({ id: 'auto-1', text: 'm2', box: sign.box, blocks: [sign], keep: true });
      result.changed = regionBoxes['auto-1'] !== drawn && regionBoxes['auto-1'].textContent;
      // Yeniden bağlanınca: listede olmayan alan (kaçan temizleme) kalkar, listedeki kalır.
      showRegion({ id: 'auto-3', text: 's', box: sign.box, blocks: [sign] });
      result.synced = syncRegions({ ids: ['auto-1', 'game-phone'] });
      result.afterSync = Object.keys(regionBoxes).sort();
      result.emptySync = syncRegions({ ids: [] }).sort();
      $('result').textContent = JSON.stringify(result);
      </script>`;
    const file = path.join(temp, 'test.html');
    fs.writeFileSync(file, html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080',
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--dump-dom', pathToFileURL(file).href], { encoding: 'utf8', timeout: 30000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([^<]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi');
    return JSON.parse(match[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&#39;/g, "'"));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

test('yenilenmeyen ek alan 15 sn sonra TV\'den kalkar; yenileme yeniden çizmez; telefon kartı kalır; yeniden bağlanınca gösterilmeyen alan kalkar', { skip: !browser && 'Chromium/Chrome bulunamadı' }, () => {
  const r = render();
  assert.equal(r.sameElement, true);
  assert.equal(r.sameStamp, true);
  assert.deepEqual(r.before, []);
  assert.deepEqual(r.expired, ['auto-2']);
  assert.deepEqual(r.left, ['auto-1', 'game-phone']);
  assert.deepEqual(r.later, ['auto-1']);
  assert.deepEqual(r.phoneLeft, ['game-phone']);
  assert.equal(r.redrawn, true);
  assert.equal(r.changed, 'Benzin İstasyonu');
  assert.deepEqual(r.synced, ['auto-3']);
  assert.deepEqual(r.afterSync, ['auto-1', 'game-phone']);
  assert.deepEqual(r.emptySync, ['auto-1', 'game-phone']);
});
