// SPDX-License-Identifier: AGPL-3.0-only
// "Koyu" zeminde (Zemin koyuluğu %100) bütün altyazı kutuları, önceki satırlar dahil, tam opak saf siyah mı? LG OLED C5'te
// (TV uygulaması 0.9.94) Koyu + siyah seçiliyken kutu karanlık sahnede gri görünüyordu: siyah seçeneği #101014 olarak
// çiziliyor, önceki satırların kutusu da %83 zemin × %75/%60 opaklıkla yarı saydam kalıyordu. Sayfa (tv-webos/index.html;
// Samsung ve Android TV de aynı sayfayı kullanır) gerçek Chromium'da sahte platform ve bağlantıyla açılır, üç hızlı
// altyazı gönderilir, kutuların hesaplanan zemini ve atalarının opaklık çarpımı ölçülür.
// node --test scripts/tv-solid-background.test.js — tarayıcı yolu: COUCHSUBS_TEST_BROWSER.
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

// Sahte platform ve bağlantı: TV'ye ya da ağa çıkılmaz. Olaylar sanal zamanda gelir (--virtual-time-budget).
const PRELUDE = `
window.COUCHSUBS_PLATFORM = {
  backKey: 461, init: function () {}, onRelaunch: function () {}, exit: function () {},
  launchParams: function () { return { server: 'http://192.0.2.1:47123' }; },
  showHdmi: function (port, host, onStatus) { onStatus('playing'); },
  findConsolePort: function (callback) { callback(1, 'PS5'); },
  localAddress: function (callback) { callback(null); }
};
window.XMLHttpRequest = function () { this.status = 0; this.responseText = ''; };
XMLHttpRequest.prototype.open = function () {};
XMLHttpRequest.prototype.send = function () {
  var xhr = this;
  setTimeout(function () {
    xhr.status = 200;
    xhr.responseText = JSON.stringify({ app: 'couchsubs', auth: 0, id: 'test' });
    if (xhr.onload) xhr.onload();
  }, 10);
};
window.EventSource = function () {
  var es = this;
  this.readyState = 1;
  this.listeners = {};
  window.__stream = this;
  setTimeout(function () { if (es.onopen) es.onopen(); }, 10);
};
EventSource.prototype.addEventListener = function (name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); };
EventSource.prototype.close = function () { this.readyState = 2; };
window.__send = function (name, data) {
  var list = (window.__stream && window.__stream.listeners[name]) || [];
  for (var i = 0; i < list.length; i++) list[i]({ data: JSON.stringify(data) });
};
`;

// Kutunun hesaplanan zemini ve kendisiyle atalarının opaklık çarpımı (ekranda görünen saydamlık).
const MEASURE = `
function __box(id) {
  var el = document.getElementById(id);
  var opacity = 1;
  for (var node = el; node && node.nodeType === 1; node = node.parentNode) opacity *= parseFloat(getComputedStyle(node).opacity);
  var span = el.querySelector('span.speaker');
  return { background: getComputedStyle(el).backgroundColor, opacity: Math.round(opacity * 100) / 100,
    color: getComputedStyle(el).color, speaker: span ? getComputedStyle(span).color : null,
    shown: getComputedStyle(el.parentNode).display !== 'none' };
}
function __measure() {
  return { text: __box('subtitle-text'), prev: __box('subtitle-prev-text'), prev2: __box('subtitle-prev2-text'),
    solid: document.body.className.indexOf('solid-bg') >= 0 };
}
`;

// style olayını gönderir, ardından üç hızlı altyazı: ilk ikisi üste (önceki ve iki önceki satır) çıkar.
function scene(style) {
  return `
setTimeout(function () { __send('style', ${JSON.stringify(style)}); }, 2000);
setTimeout(function () { __send('subtitle', { text: 'ARTHUR: Birinci satır burada.', duration: 8000,
  speakerNames: [{ name: 'ARTHUR', color: '#FF8040' }] }); }, 3000);
setTimeout(function () { __send('subtitle', { text: 'İkinci satır başka bir şey.', duration: 8000 }); }, 3200);
setTimeout(function () { __send('subtitle', { text: 'Üçüncü satır en altta.', duration: 8000 }); }, 3400);
setTimeout(function () { document.getElementById('__result').textContent = JSON.stringify(__measure()); }, 3600);
`;
}

function render(style) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-solid-bg-test-'));
  try {
    for (const file of fs.readdirSync(root)) {
      if (/\.(js|css|png)$/.test(file) && file !== 'platform.js') fs.copyFileSync(path.join(root, file), path.join(temp, file));
    }
    fs.writeFileSync(path.join(temp, 'platform.js'), PRELUDE);
    let html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
    html = html.replace('<script src="app.js"></script>',
      `<script src="app.js"></script><pre id="__result"></pre><script>${MEASURE}${scene(style)}</script>`);
    fs.writeFileSync(path.join(temp, 'index.html'), html);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run',
      '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1920,1080',
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []), '--user-data-dir=' + path.join(temp, 'profile'),
      '--virtual-time-budget=4000', '--dump-dom', pathToFileURL(path.join(temp, 'index.html')).href],
    { encoding: 'utf8', timeout: 60000, windowsHide: true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="__result">([^<]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi');
    return JSON.parse(match[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&'));
  } finally {
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

const BLACK = 'rgb(0, 0, 0)';

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
test('Koyu + siyah: bütün kutular tam opak saf siyah, soluklaştırma yalnız yazıda', { skip: !browser && 'Chrome/Edge bulunamadı' }, (t) => {
  const r = render({ background: 100, backgroundColor: '#101014', textHex: '#FFFFFF' });
  t.diagnostic(JSON.stringify(r));
  assert.ok(r.solid, 'body.solid-bg');
  for (const name of ['text', 'prev', 'prev2']) {
    assert.ok(r[name].shown, name + ' görünmüyor');
    assert.equal(r[name].background, BLACK, name);
    assert.equal(r[name].opacity, 1, name + ' kutusu saydamlaşmamalı');
  }
  assert.equal(r.text.color, 'rgb(255, 255, 255)');
  // Önceki satırlar yazı renginde soluk: %75 ve %60 (opak siyah zeminde opaklıkla aynı sonuç).
  assert.equal(r.prev.color, 'rgb(191, 191, 191)');
  assert.equal(r.prev2.color, 'rgb(153, 153, 153)');
  // Konuşan adı (iki önceki satırda ARTHUR) da soluk boyanır: #FF8040 × 0.6.
  assert.equal(r.prev2.speaker, 'rgb(153, 77, 38)');
});

test('Koyu + lacivert: kutular opak lacivert, renk korunur', { skip: !browser && 'Chrome/Edge bulunamadı' }, (t) => {
  const r = render({ background: 100, backgroundColor: '#0E1A30', textHex: '#FFFFFF' });
  t.diagnostic(JSON.stringify(r));
  for (const name of ['text', 'prev', 'prev2']) {
    assert.equal(r[name].background, 'rgb(14, 26, 48)', name);
    assert.equal(r[name].opacity, 1, name);
  }
  // Beyaz yazı laciverte doğru %75 karışır.
  assert.equal(r.prev.color, 'rgb(195, 198, 203)');
});

test('Koyu değilken eski davranış: önceki satırlar yarı saydam, siyah seçeneği yine saf siyah', { skip: !browser && 'Chrome/Edge bulunamadı' }, (t) => {
  const r = render({ background: 90, backgroundColor: '#101014', textHex: '#FFFFFF' });
  t.diagnostic(JSON.stringify(r));
  assert.ok(!r.solid);
  assert.equal(r.text.background, 'rgba(0, 0, 0, 0.9)');
  assert.equal(r.text.opacity, 1);
  assert.equal(r.prev.background, 'rgba(0, 0, 0, 0.75)');
  assert.equal(r.prev.opacity, 0.75);
  assert.equal(r.prev2.opacity, 0.6);
  assert.equal(r.prev.color, 'rgb(255, 255, 255)');
});
