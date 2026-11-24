// SPDX-License-Identifier: AGPL-3.0-only
// LG TV (tv-webos/platform.js): kurulumdan sonra webOS eski sayfayı tutarsa (beta.89, Mac: TV'de 0.9.84 kurulu, açık
// uygulama 0.9.81'i gösteriyordu) sayfa diskteki appinfo.json'a bakıp bir kez yeniden yüklenir.
// Çalıştırma: node --test scripts/tv-webos-stale-reload.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..', 'tv-webos');
const code = fs.readFileSync(path.join(root, 'platform.js'), 'utf8');

// appinfo: XHR'nin döndürdüğü metin (null: istek hata verir). storage: localStorage (null: erişim hata verir).
function startTv(appinfo, storage = {}) {
  const requests = [];
  let reloads = 0;
  class XMLHttpRequest {
    open(method, url) { this.url = url; requests.push(url); }
    send() {
      if (appinfo === null) throw new Error('file access denied');
      this.readyState = 4;
      this.status = 0;
      this.responseText = appinfo;
      this.onreadystatechange();
    }
  }
  const localStorage = storage === null ? {
    getItem() { throw new Error('denied'); },
    setItem() { throw new Error('denied'); },
    removeItem() {}
  } : {
    getItem: (k) => (k in storage ? storage[k] : null),
    setItem: (k, v) => { storage[k] = String(v); },
    removeItem: (k) => { delete storage[k]; }
  };
  const window = { localStorage, location: { reload() { reloads++; } } };
  const context = { window, document: {}, XMLHttpRequest, JSON, Math, String, parseInt, setTimeout: () => 0, clearTimeout: () => {} };
  vm.createContext(context);
  vm.runInContext(code, context, { filename: 'platform.js' });
  return { platform: window.COUCHSUBS_PLATFORM, requests, reloads: () => reloads, storage };
}

test('webOS: kurulu paket sayfadan yeniyse sayfa yeniden yüklenir, aynı sürüm çifti için yalnız bir kez', () => {
  const storage = {};
  const tv = startTv('{"id":"com.couchsubs.tv","version":"0.9.84"}', storage);
  tv.platform.reloadIfStale('0.9.81');
  assert.strictEqual(tv.reloads(), 1);
  assert.match(tv.requests[0], /^appinfo\.json\?t=\d+$/);
  // Yeniden yüklenen sayfa yine eskiyse (webOS eski süreci tutuyor) döngüye girilmez.
  const again = startTv('{"id":"com.couchsubs.tv","version":"0.9.84"}', storage);
  again.platform.reloadIfStale('0.9.81');
  assert.strictEqual(again.reloads(), 0);
  // Sonraki güncellemede yine bir kez denenir.
  const next = startTv('{"id":"com.couchsubs.tv","version":"0.9.86"}', storage);
  next.platform.reloadIfStale('0.9.84');
  assert.strictEqual(next.reloads(), 1);
});

test('webOS: sayfa güncelse, sürümü sayısal olarak yüksekse ya da appinfo okunamazsa yeniden yüklenmez', () => {
  for (const [appinfo, page] of [
    ['{"version":"0.9.86"}', '0.9.86'],
    ['{"version":"0.9.9"}', '0.9.10'],
    ['{"version":"0.9.84"}', '0.9.86'],
    ['bozuk', '0.9.81'],
    ['{}', '0.9.81'],
    [null, '0.9.81']
  ]) {
    const tv = startTv(appinfo);
    tv.platform.reloadIfStale(page);
    assert.strictEqual(tv.reloads(), 0, `${appinfo} / ${page}`);
  }
  // Sayısal karşılaştırma: 0.9.10 > 0.9.9.
  const tv = startTv('{"version":"0.9.10"}');
  tv.platform.reloadIfStale('0.9.9');
  assert.strictEqual(tv.reloads(), 1);
});

test('webOS: kayıt tutulamıyorsa yeniden yüklenmez (döngü olmasın)', () => {
  const tv = startTv('{"version":"0.9.86"}', null);
  tv.platform.reloadIfStale('0.9.81');
  assert.strictEqual(tv.reloads(), 0);
});

test('app.js açılışta ve her öne gelişte (webOSRelaunch) sürümü denetler', () => {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const init = app.indexOf('platform.init();');
  assert.ok(init > 0);
  assert.match(app.slice(init, init + 200), /platform\.reloadIfStale\(APP_VERSION\)/);
  const relaunch = app.indexOf('platform.onRelaunch(function (raw) {');
  assert.ok(relaunch > 0);
  assert.match(app.slice(relaunch, relaunch + 300), /platform\.reloadIfStale\(APP_VERSION\)/);
});

test('TV uygulamasının sürümü appinfo.json, app.js, Tizen ve Android TV paketlerinde aynı', () => {
  const version = JSON.parse(fs.readFileSync(path.join(root, 'appinfo.json'), 'utf8')).version;
  assert.match(fs.readFileSync(path.join(root, 'app.js'), 'utf8'), new RegExp(`var APP_VERSION = '${version.replace(/\./g, '\\.')}';`));
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'tv-tizen', 'config.xml'), 'utf8'), new RegExp(`version="${version}"`));
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'tv-android', 'app', 'build.gradle'), 'utf8'), new RegExp(`versionName '${version}'`));
});
