# Ekran çapası: telefona yapışık çeviri

Hedef (Sinan Bey): GTA 6'nın oyun içi telefonunda her mesajın çevirisi kendi balonunun yerinde, telefonun ekranının
üstünde; telefon el titremesiyle ya da karakter yürürken kıpırdadıkça çeviri telefona yapışık, titremeden onunla gider.
Aynısı görev kartı, harita kartı ve menü kutuları için.

## Sorun

Telefonun yeri yalnız OCR turunda (`GamePhoneTracker`, 330 ms'de bir) 400×225'lik kaba ızgarada bulunuyordu; balonların
kutuları da OCR'dan geliyordu. Aradaki karelerde telefon kıpırdasa da çeviri yerinde kalıyor, kayma eşiği
(`PhoneSteady.positionShare`, satır yüksekliğinin %25'i) aşılınca birden sıçrıyordu. Yazı boyu ve satır kırılımı her
okumada yeniden hesaplandığı için çeviri ayrıca büyüyüp küçülüyordu (#1154 paneli kilitledi, balonlar açıkta kaldı).

## Yöntem (`ScreenAnchor`, dört platform aynı)

1. **Başvuru**: OCR'ın telefonu (ya da kartı) bulduğu karede dörtgenin görüntüsü şablon olur (izleme karesi 960 piksel
   genişlik; kenardan %3 içeride, ≤2500 nokta/kat, en çok 4 katlı piramit).
2. **Her kare**: şablonun izdüşümsel dönüşümü (öteleme, ölçek, dönme, elde eğilen telefonun perspektifi; 8 değişken)
   ters bileşimli Lucas-Kanade ile bulunur. En kaba katta üç başlangıç denenir: önceki dönüşüm, sabit hızla öngörülen ve
   onun çevresinde ±3 piksellik (izleme karesinde ±24) tam piksel tarama; arabada sarsılan telefon karede 15–20 piksel
   gidebiliyor. Ağırlık sağlamdır: farkı 8 gri düzeye kadar tam, 24'e kadar azalan, ötesi sıfır (ekranda değişen yazı,
   önden geçen el izlemeyi çekmez). Parlaklık/karşıtlık her yinelemede eşitlenir (pozlama değişimi, ekran kararması).
3. **Şablon hiç güncellenmez**: değişen parçayı yeniden örneklemek denendi, eğimli kenarlardaki küçük kayma şablona
   işlenip birikti (yapay vakada 0,16 → 0,38 piksel); güncellemesiz hata 0,14'te sabit kaldı.
4. **Kayıp**: uyumlu nokta oranı %45'in altına inerse ya da dönüşüm akla yatkın değilse (ölçek 0,5–2 dışı, eksen oranı
   0,75–1,33 dışı, köşelerde %15'ten çok perspektif) çapa kaybolur; bir sonraki okumada yeniden kurulur. Telefon
   indirilirken izleyicinin bulanık kareye yapışıp telefonu "uzatması" böyle engellenir.
5. **Kararlılık** (`ScreenAnchor.Smoother`): dörtgenin hiçbir köşesi son gösterilenden 0,15 pikselden fazla oynamadıysa
   son gösterilen kalır (duran telefonda çeviri piksel piksel sabit), oynadıysa ham ölçüm gecikmesiz gösterilir; köşe
   bir karede dörtgen yüksekliğinin %12'sinden fazla sıçrarsa `jumped` (çapa yeniden kurulmalı). İstenen "2–3 karelik
   gecikmesiz kestirim" (son üç ölçümden geçen doğru) ölçüldü ve **alınmadı**: arabada sarsılan telefonda ivme yüzünden
   taşıyor, izleme hatasının en kötüsü 0,42'den 6,3 piksele, kareler arası kaymanın p95'i 0,21'den 3,5 piksele çıkıyordu;
   ham ölçüm zaten piksel altı kararlı.

Maliyet: kare başına 1,2–2 ms (Apple M serisi, tek çekirdek, Swift -O). Ortak deneme dosyası
`core/Tests/CouchSubsCoreTests/Fixtures/screen-anchor.json` (yapay kare: alt piksel öteleme, ölçek+dönme, perspektif,
pozlama değişimi, ekranın bir parçası değişiyor, telefon indirildi; ölü bölge ve sıçrama).

## Ölçüm (gerçek kayıt, GTA 6, 23 Kas, 1920×1072, 60 fps)

Kayıt depoda değildir. İki sahne: **A** fitness uygulaması, telefon elde, oyuncu ağırlık kaldırıyor (t = 2189–2192 sn, 179
kare); **B** mesajlaşma, araba sürerken telefon elde (t = 2535.7–2539.5 sn, 229 kare; telefon hızla sarsılıyor).
İzleyici yarım çözünürlükte (960) çalıştı; doğrulama asıl karede (1920), izleyiciden bağımsız: telefonun içindeki 6–8
belirgin yamanın (yazı, simge) başvuru görüntüsü normalize çapraz ilintiyle (±4 piksel tarama, parabolik alt piksel)
arandı ve izleyicinin öngördüğü yerle karşılaştırıldı. Doğrulamanın kendi gürültüsü de sayılara dahildir.

- **İzleme hatası**: çevirinin olması gereken yer ile gösterildiği yer arası (piksel, 1920 genişlikte).
- **Kareler arası kayma**: bu hatanın bir kareden ötekine değişimi (çevirinin telefona göre titremesi).
- **Önce**: çeviri 330 ms'lik turda, telefon eşikten (6,5 piksel ≈ satır yüksekliğinin %25'i) fazla kaymışsa yerine
  sıçrar, arada durur. OCR kutularının kendi oynaması hiç sayılmadı; yani önceki yöntem için iyimser.

| Sahne | Ölçü | Önce (ortanca / p95 / en kötü) | Sonra (ortanca / p95 / en kötü) | Hedef |
|---|---|---|---|---|
| A | izleme hatası | 1,57 / 8,33 / 10,43 | **0,14 / 0,35 / 0,68** | ≤ 1 |
| A | kareler arası kayma | 0,07 / 0,77 / 10,43 | **0,03 / 0,35 / 0,99** | ≤ 0,5 |
| B | izleme hatası | 4,03 / 55,27 / 83,47 | **0,15 / 0,30 / 0,42** | ≤ 1 |
| B | kareler arası kayma | 0,04 / 8,54 / 47,87 | **0,02 / 0,21 / 0,50** | ≤ 0,5 |

İzleme hatası her karede 1 pikselin altında. Kareler arası kaymanın p95'i 0,35'in altında; A'daki tek en kötü değer
(0,99) doğrulamanın düşük karşıtlıklı bir yamasındaki gürültüdür (aynı karede öteki yamalar 0,3'ün altında).

Yeniden üretmek (`tools/screen-anchor/`):

```sh
ffmpeg -ss 2186 -t 16 -i video.mp4 -vf "scale=960:536,format=gray" -f rawvideo segA.gray
ffmpeg -ss 2186 -t 6 -i video.mp4 -vf format=gray -f rawvideo segAf.gray
swiftc -O -o izle tools/screen-anchor/main.swift core/Sources/CouchSubsCore/ScreenAnchor.swift
swiftc -O -o altin tools/screen-anchor/altin.swift
./izle segA.gray 180 370 110 180 320 | head -179 > a.txt
OUT=1 K=2 ./altin segAf.gray 1920 1072 a.txt 180 370 110 180 320 826 214 1040 384 1006 620 986 764 820 592 770 830 > p.txt
python3 tools/screen-anchor/olc.py p.txt 6.5
# B: -ss 2533 (-t 9 / -t 6.6), başlangıç 160, dörtgen 545 85 212 410,
#    yamalar 1266 256 1462 248 1172 700 1366 784 1300 842 1470 860 1300 450 1160 566
```

Görev kartı, harita kartı ve menü kutuları ekrana sabittir; çapa orada birim dönüşümde kalır (çeviri piksel piksel
sabit), yalnız kart açılıp kapanınca ya da kayınca kaybolur. Oradaki titremenin kaynağı OCR kutusunun oynamasıydı
(ScreenStyleLock #1162 ve ScreenPresence #1166 kapatıyor); yerleşim çapaya kilitlenince o da biter.

## Bağlama (sonraki aşamalar)

1. **Çekirdek** (bu aşama): `ScreenAnchor` (Swift/C#/Kotlin), ortak vakalar, eşitlik denetimi, ölçüm aracı.
2. **Akış** (sunucuda, dört uygulama aynı): her uygulama her karede zaten `SubtitleServer.observe(frame)` çağırıyor
   (ScreenPresence); izleyici orada çalışır (kare `Gray.fromRGBA` ile 960 ene). Telefon okuması (`PhoneRegionSession`,
   Windows/Android eşleri) okuduğu karede sunucuya sorar: çapa yoksa o kare ve telefonun dörtgeniyle (`Pose.bounds`)
   kurulur, birim dönüşüm döner; varsa o anki dönüşüm döner. Okuma balon kutularını bu dönüşümün tersiyle **başvuru
   koordinatına** çevirip gönderir; böylece her okuma aynı koordinatta olur, aynı mesajın yeri ve yazı boyu başvuruda
   kilitlenir (`PhoneSteady.steadyPositions` telefonun hareketinden arınmış kutularla çalışır, eşik çok küçülebilir).
   `region` olayı `anchor` (kuşak numarası ve başvuru dörtgeni) taşır; sunucu her karede, ölü bölgeyi aşan değişimde
   küçük bir `anchor` olayı (kuşak + 8 sayı, kareye oranla) yayınlar; çapa kaybolunca `anchor` `lost` ile gider ve
   balon çevirileri hemen gizlenir, sonraki okuma çapayı yeniden kurar.
3. **Çizim**: TV (`tv-webos/app.js`, Tizen ve Android TV aynı sayfa) balon katmanını tek kapta tutar, kabın
   `transform`'u `matrix3d` (perspektifsiz `matrix`); Mac/iPhone `CATransform3D`, Windows `MatrixTransform` (perspektif
   payı küçük, afin yaklaşık), Android `Matrix.setPolyToPoly`. Yazı boyu ve satır kırılımı başvuruda bir kez hesaplanır.
4. **Yerinde çizim**: balonun düz zemini özgün yazının üstüne aynı renkle çizilir (#1142 sil-ve-yeniden-çiz), çeviri
   balonun renginde, sabit boyda.

## Mac: "Ekranı yerinde Türkçe çiz" (deneysel, önce yalnız Mac)

Sinan Bey kararı (24 Kas): önce yalnız Mac'te, telefon önce; görev kartları ve menüler ikinci aşamada. Ayar Ayarlar ›
Alanlar › "GTA 6 phone messages" kartında **Ekranı Yerinde Türkçe Çiz (Deneysel)**, Mac'te varsayılan açık
(`UserSettings.drawScreenInPlace`; öbür platformlar henüz okumaz, eşitlik denetiminde izinli). Yalnız oyun görüntüsü
bu Mac'teki bir pencereden (PS Remote Play, chiaki-ng, seçilen OBS/oyun penceresi) okunurken çalışır; PS5'ten doğrudan
okurken eski davranış.

- **Çapa** (`PhoneAnchorSession`, core/PhoneAnchor.swift): telefon okuması (`PhoneRegionSession.read`) çapayı o karede,
  telefonun o karede bulunan dörtgeniyle kurar (`place`); kuruluysa o karenin dönüşümü 90 karelik geçmişten alınır.
  Pencere yakalaması bu ayarla saniyede 30 kare verir; her kare kopyalanmadan çapaya gider (`feed`, okuma yine en çok
  saniyede 10). Okumadaki telefon çapanın yerinden dörtgen yüksekliğinin %25'inden uzaksa çapa yeniden kurulur.
- **OCR yalnız yazı değişince**: sayfanın bölgesi çapanın o karedeki yerine taşınıp karşılaştırılır; telefon yalnız
  kıpırdadı diye yeniden okunmaz. Çapa kaybolunca sonraki tur mutlaka okur (çapa yeniden kurulur).
- **Türkçe ikiz** (`PhoneTwin`, core/PhoneTwin.swift; silme/çizme #1142'nin `TextErase`'i): telefonun ekranı başvuru
  dörtgenine düzleştirilir, her çevrilen yazının yalnız harf noktaları silinir, Türkçe aynı yere, özgün renk ve
  kalınlıkta çizilir. Katman yalnız yazı kutularında opaktır; simge, avatar, fotoğraf ve kutuların dışı oyunun canlı
  görüntüsüdür. Kutu başına zemin kararı: çevre şeridinin dokusu ≤ 14 ise tam silme, değilse zemin renginde sıkı kutu
  (günlükte "silindi, yerine çizildi" / "desenli zemin, zemin renginde kutu"). Silme ve çizim yalnız yazı değişince.
- **Çizim** (mac/CouchSubs/UI/PhoneTwinOverlay.swift): oyun penceresinin tam üstünde tıklama geçiren saydam panel;
  ikiz her karede `ProjectionTransform` (çapanın 3×3 izdüşüm matrisi) ile telefonun üstüne yansıtılır. Çapa kaybolunca
  ya da kuşak değişince ikiz hemen kalkar. Yayın penceresi de aynı katmanı çizer.
- **Günlük**: "çapa kuruldu (kuşak N; telefon …)", "çapa kayboldu (kuşak N; neden)" (dakikada en çok 12 satır), 10 sn'de
  bir "çapa: kuşak N, … kare, uyum ort %…, kare başı ort … ms (en çok … ms)", her ikizde "telefon Türkçe çizildi (…)"
  (dakikada en çok 6).

### Sunucu olayı (TV için tasarım; Mac göndericisi uygulandı, TV henüz okumuyor)

- `region` (`id: "game-phone"`) blokları çapanın **başvuru koordinatında**dır ve `anchor: {"gen": N, "ref": {left, top,
  right, bottom}}` taşır.
- `anchor` olayı, gösterilen dönüşüm her değiştiğinde (ölü bölgeyi aşan karede): `{"gen": N, "m": [a, b, c, d, dx, dy,
  g, h]}`. Dönüşüm kareye oranlıdır; merkez `ref`'in ortasıdır (cx, cy): u = x − cx, v = y − cy, w = 1 + g u + h v,
  x' = cx + (a u + b v + dx) / w, y' = cy + (c u + d v + dy) / w. CSS'te kabın `transform`'u bundan kurulan `matrix3d`.
- Çapa kaybolunca `{"gen": N, "lost": true}`: o kuşağın balonları hemen gizlenir. Son `anchor` olayı yeni bağlanan TV'ye
  bölgelerden sonra yinelenir. Olayı tanımayan TV blokları başvuru yerinde (çapanın kurulduğu okumadaki yerde) gösterir.

Not: TV'de çeviri, oyunu TV'ye doğrudan veren konsolun görüntüsünün üstünde durur; çapa, Remote Play/yakalama gecikmesi
(tipik 50–100 ms) kadar geriden gelir. Titreme biter, ama hızlı sarsıntıda gecikme kadar geride kalabilir; bilgisayar ve
telefon ekranındaki yayın penceresinde (aynı kare) gecikme yoktur.

## Varsayılan önerisi

Ölçüme göre "Balonların Üstünde" çapayla titremesiz hâle gelir (izleme hatası < 1 piksel). Bağlama ve yerinde çizim
(aşama 2–4) birleşip gerçek kayıtla TV çiziminde doğrulanınca **"Balonların Üstünde" varsayılan olsun** önerilir;
o güne kadar varsayılan "Yanda Panel" kalmalı.
