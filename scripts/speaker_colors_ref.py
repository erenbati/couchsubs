# SPDX-License-Identifier: AGPL-3.0-only
# Konuşana göre renk (v3) başvuru uygulaması ve ortak test vektörü. Windows, Mac/iPhone ve Android'deki
# SpeakerColorBook aynı sırayla verilen adlara AYNI rengi vermek zorunda; testleri docs/speaker-colors-vectors.json'u okur.
# Palet: koyu altyazı zemininde okunaklı (kontrast >= 6,5:1) on renk, OKLCH ton çemberinde 36 derece arayla (25, 61, ... 349).
# Eski paletin yarısı mavi, pembe ya da mor tonuydu (on renkten üçü mavi, ikisi pembe/mor; hepsi soluk): adların çoğu
# pembe/mavi çıkıyor, kişiler ayırt edilmiyordu (X bildirimi). Tonlar tamsayı tablodur (HUES): platformlar renkten ton
# hesaplamaz, kayan nokta farkı çıkmaz.
# Kurallar: ad anahtarı = kırpılmış, sondaki noktalaması atılmış, küçük harf. OCR yakın okuması aynı kişi: karışan harfler
# (l/1/| → i, 0 → o, rn → m) eşitlenince aynıysa ya da ikisi de >= 5 harfken Levenshtein <= 1 ise. Yeni kişi tabanı
# (FNV-1a % 10) alır: taban kullanılmıyor ve kullanılan her renkten en az MIN_HUE_GAP derece uzaksa taban; değilse
# kullanılmayan renklerden, kullanılanlara en yakın tonu en uzak olan (eşitlikte tabandan palet sırasıyla ilki); hepsi
# kullanılıyorsa taban. Aynı kişi oturum boyunca aynı renkte kalır; oturumun ilk kişisi her zaman tabanını alır.
# Vektörü yeniden üretmek: python3 scripts/speaker_colors_ref.py > docs/speaker-colors-vectors.json
import json, sys
P = ['#FD736D', '#FEA757', '#FEDD3C', '#9BE759', '#1EE4B2', '#2AD5E5', '#49B5FA', '#8F9BFB', '#D482FF', '#F76AB7']
HUES = [25, 61, 97, 133, 169, 205, 241, 277, 313, 349]
MIN_HUE_GAP = 72


def key(name):
    s = name.strip()
    while s and s[-1] in '.,!?;:…':
        s = s[:-1]
    return s.strip().lower()


def fnv(s):
    h = 2166136261
    b = s.encode('utf-16-le')
    for i in range(0, len(b), 2):
        h ^= b[i] | (b[i + 1] << 8)
        h = (h * 16777619) & 0xffffffff
    return h


def confuse(s):
    s = s.replace('rn', 'm')
    return ''.join({'l': 'i', '1': 'i', '|': 'i', '0': 'o'}.get(c, c) for c in s)


def lev(a, b):
    d = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        p = d[:]
        d[0] = i
        for j, cb in enumerate(b, 1):
            d[j] = min(p[j] + 1, d[j - 1] + 1, p[j - 1] + (ca != cb))
    return d[-1]


def hue_gap(i, used):
    """`i` renginin tonunun kullanılan renklerin tonlarına en yakın uzaklığı (derece, çember üzerinde)."""
    return min(min(abs(HUES[i] - HUES[u]), 360 - abs(HUES[i] - HUES[u])) for u in used)


class Book:
    def __init__(self):
        self.people = []

    def color(self, name):
        k = key(name)
        if not k:
            return None
        for pk, c in self.people:
            if pk == k or confuse(pk) == confuse(k) or (min(len(pk), len(k)) >= 5 and lev(pk, k) <= 1):
                return c
        base = fnv(k) % len(P)
        used = [P.index(c) for _, c in self.people]
        if not used or (base not in used and hue_gap(base, used) >= MIN_HUE_GAP):
            pick = base
        else:
            pick = None
            for step in range(len(P)):
                c = (base + step) % len(P)
                if c in used:
                    continue
                if pick is None or hue_gap(c, used) > hue_gap(pick, used):
                    pick = c
            if pick is None:
                pick = base
        self.people.append((k, P[pick]))
        return P[pick]


def run(names):
    book = Book()
    return [{"name": n, "color": book.color(n)} for n in names]


seq = ["Mattia", "Lucia", "Mattla", "Mattia.", "MATTIA", "Boobie", "Jason", "Cal", "Raul", "Brian", "Mattia", "Lucia:",
       "Jasen", "Dre'Quan", "Bae-Luxe", "Lori", "Cal"]
gta6 = ["Lucia", "Jason", "Cal", "Yolanda", "CO Wilson", "Stefanie Gates", "Donnie", "Brian", "Officer Gutierrez",
        "Boobie", "Raul", "Lucia", "JASON"]
json.dump({"palette": P, "hues": HUES, "minHueGap": MIN_HUE_GAP, "sequence": run(seq), "gta6": run(gta6)},
          sys.stdout, ensure_ascii=False, indent=1)
print()
