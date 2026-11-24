# SPDX-License-Identifier: AGPL-3.0-only
"""Önce/sonra ölçüsü (docs/ekran-capasi.md): `altin` OUT=1 çıktısından izleme hatası ve kareler arası kayma (piksel).

SONRA: çeviri katmanı izleyicinin dönüşümüyle taşınır (öngörülen yer). ÖNCE: çeviri 330 ms'lik OCR turunda, telefon eşikten
(satır yüksekliğinin %25'i) fazla kaymışsa yeni yerine sıçrar, arada yerinde durur (PhoneSteady.positionShare; OCR'ın kendi
kutu oynaması hiç sayılmaz, yani önceki yöntem için iyimser).

Kullanım: python3 olc.py <altin çıktısı> <eşik pikseli> [kare/tur, 60 fps'de 20]
"""
import math
import sys

rows = [line.split() for line in open(sys.argv[1]) if line.startswith("P ")]
threshold = float(sys.argv[2])
tick = int(sys.argv[3]) if len(sys.argv) > 3 else 20
points = {}
for _, frame, patch, px, py, fx, fy in rows:
    points.setdefault(int(patch), []).append((int(frame), float(px), float(py), float(fx), float(fy)))


def quantile(values, f):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * f))]


after_error, after_slip, before_error, before_slip = [], [], [], []
for sequence in points.values():
    sequence.sort()
    last_after = last_before = shown = None
    for k, (_, px, py, fx, fy) in enumerate(sequence):
        error = (px - fx, py - fy)
        after_error.append(math.hypot(*error))
        if last_after:
            after_slip.append(math.hypot(error[0] - last_after[0], error[1] - last_after[1]))
        last_after = error
        if shown is None:
            shown = (fx, fy)
        if k % tick == 0 and math.hypot(fx - shown[0], fy - shown[1]) > threshold:
            shown = (fx, fy)
        error = (shown[0] - fx, shown[1] - fy)
        before_error.append(math.hypot(*error))
        if last_before:
            before_slip.append(math.hypot(error[0] - last_before[0], error[1] - last_before[1]))
        last_before = error


def show(name, values):
    print(f"{name}: ortanca {quantile(values, 0.5):.2f}  p95 {quantile(values, 0.95):.2f}  en kötü {max(values):.2f}")


show("ÖNCE izleme hatası", before_error)
show("ÖNCE kareler arası kayma", before_slip)
show("SONRA izleme hatası", after_error)
show("SONRA kareler arası kayma", after_slip)
