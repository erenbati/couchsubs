// SPDX-License-Identifier: AGPL-3.0-only
// Bağımsız doğrulama (yalnız yerel; docs/ekran-capasi.md): izleyicinin öngördüğü yama ortası ile normalize çapraz ilintiyle
// (NCC, ±4 piksel tarama, parabolik alt piksel) asıl karede bulunan yer arasındaki uzaklık. Lucas-Kanade'den bağımsızdır.
// K: izleme karesinden ölçüm karesine büyütme (960 → 1920: 2). Yamalar ölçüm karesinin pikselinde, dörtgen izleme karesinde.
// Derleme: swiftc -O -o altin altin.swift
// Kullanım: [OUT=1] K=2 altin <gri dosya> <W> <H> <izle çıktısı> <başlangıç> rx ry rw rh x1 y1 x2 y2 ...
import Foundation

let a = CommandLine.arguments
let width = Int(a[2])!, height = Int(a[3])!
let data = try! Data(contentsOf: URL(fileURLWithPath: a[1]))
let lines = try! String(contentsOfFile: a[4], encoding: .utf8).split(separator: "\n")
let start = Int(a[5])!
let rx = Double(a[6])!, ry = Double(a[7])!, rw = Double(a[8])!, rh = Double(a[9])!
let cx = rx + rw / 2, cy = ry + rh / 2
let scale = Double(ProcessInfo.processInfo.environment["K"] ?? "1")!
let printsPoints = ProcessInfo.processInfo.environment["OUT"] != nil
var patches: [(Double, Double)] = []
var k = 10
while k + 1 < a.count { patches.append((Double(a[k])!, Double(a[k + 1])!)); k += 2 }
func pixel(_ f: Int, _ x: Int, _ y: Int) -> Double {
    Double(data[f * width * height + min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))])
}
func bilinear(_ f: Int, _ x: Double, _ y: Double) -> Double {
    let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - Double(x0), fy = y - Double(y0)
    return (pixel(f, x0, y0) * (1 - fx) + pixel(f, x0 + 1, y0) * fx) * (1 - fy)
        + (pixel(f, x0, y0 + 1) * (1 - fx) + pixel(f, x0 + 1, y0 + 1) * fx) * fy
}
let radius = 10, reach = 4
var errors: [Double] = []
for line in lines {
    let p = line.split(separator: " ")
    guard p.count >= 9, let i = Int(p[0]), (i + 1) * width * height <= data.count else { continue }
    let dx = Double(p[1])!, dy = Double(p[2])!, a11 = Double(p[3])!, a12 = Double(p[4])!, a21 = Double(p[5])!
    let a22 = Double(p[6])!, g = Double(p[7])!, h = Double(p[8])!
    let ma = (a11 + a22) / 2, mb = (a21 - a12) / 2
    for (index, (qx, qy)) in patches.enumerated() {
        let hx = (qx - (scale - 1) / 2) / scale - cx, hy = (qy - (scale - 1) / 2) / scale - cy
        let w = 1 + g * hx + h * hy
        let predX = scale * (cx + (dx + a11 * hx + a12 * hy) / w) + (scale - 1) / 2
        let predY = scale * (cy + (dy + a21 * hx + a22 * hy) / w) + (scale - 1) / 2
        // Başvuru yaması yalnız dönme/ölçekle çevrilir; yer taramayla bulunur.
        var template: [Double] = []
        let det = ma * ma + mb * mb
        for oy in -radius...radius {
            for ox in -radius...radius {
                let ru = (ma * Double(ox) + mb * Double(oy)) / det, rv = (-mb * Double(ox) + ma * Double(oy)) / det
                template.append(bilinear(start, qx + ru, qy + rv))
            }
        }
        let tm = template.reduce(0, +) / Double(template.count)
        let tv = template.map { ($0 - tm) * ($0 - tm) }.reduce(0, +)
        let bx = Int(predX.rounded()), by = Int(predY.rounded())
        var score = [[Double]](repeating: [Double](repeating: -2, count: 2 * reach + 1), count: 2 * reach + 1)
        var best = (-2.0, 0, 0)
        for sy in -reach...reach {
            for sx in -reach...reach {
                var values: [Double] = []
                for oy in -radius...radius { for ox in -radius...radius { values.append(pixel(i, bx + sx + ox, by + sy + oy)) } }
                let m = values.reduce(0, +) / Double(values.count)
                var cov = 0.0, vv = 0.0
                for j in 0..<values.count {
                    cov += (values[j] - m) * (template[j] - tm)
                    vv += (values[j] - m) * (values[j] - m)
                }
                let s = cov / max(1e-9, (vv * tv).squareRoot())
                score[sy + reach][sx + reach] = s
                if s > best.0 { best = (s, sx, sy) }
            }
        }
        let (_, sx, sy) = best
        var fx = Double(sx), fy = Double(sy)
        if abs(sx) < reach {
            let l = score[sy + reach][sx + reach - 1], c = score[sy + reach][sx + reach], r = score[sy + reach][sx + reach + 1]
            if l - 2 * c + r < 0 { fx += 0.5 * (l - r) / (l - 2 * c + r) }
        }
        if abs(sy) < reach {
            let u = score[sy + reach - 1][sx + reach], c = score[sy + reach][sx + reach], d = score[sy + reach + 1][sx + reach]
            if u - 2 * c + d < 0 { fy += 0.5 * (u - d) / (u - 2 * c + d) }
        }
        let foundX = Double(bx) + fx, foundY = Double(by) + fy
        errors.append(((foundX - predX) * (foundX - predX) + (foundY - predY) * (foundY - predY)).squareRoot())
        if printsPoints { print("P \(i) \(index) \(predX) \(predY) \(foundX) \(foundY)") }
    }
}
let sorted = errors.sorted()
func quantile(_ f: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * f))] }
print(String(format: "yama hatası (%d px genişlikte) n=%d ortanca=%.3f p95=%.3f en kötü=%.3f", width, sorted.count,
             quantile(0.5), quantile(0.95), sorted.last ?? 0))
