// SPDX-License-Identifier: AGPL-3.0-only
// Çapa izleme ölçüm aracı (yalnız yerel; docs/ekran-capasi.md). Ham gri kareler (ffmpeg -f rawvideo -pix_fmt gray) üzerinde
// ScreenAnchor.Tracker ve Smoother çalıştırır; her kare için gösterilecek dönüşümü yazar: kare dx dy a b c d g h uyum [J].
// Derleme: swiftc -O -o izle main.swift ../../core/Sources/CouchSubsCore/ScreenAnchor.swift
// Kullanım: W=960 H=536 [HAM=1] izle <gri dosya> <başlangıç karesi> x y en boy
import Foundation

let args = CommandLine.arguments
let path = args[1], start = Int(args[2])!
let rect = ScreenAnchor.Rect(x: Double(args[3])!, y: Double(args[4])!, width: Double(args[5])!, height: Double(args[6])!)
let env = ProcessInfo.processInfo.environment
let width = Int(env["W"] ?? "960")!, height = Int(env["H"] ?? "536")!
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let count = data.count / (width * height)
func frame(_ i: Int) -> ScreenAnchor.Gray {
    ScreenAnchor.Gray(width: width, height: height, pixels: [UInt8](data[(i * width * height)..<((i + 1) * width * height)]))
}
let tracker = ScreenAnchor.Tracker()
tracker.begin(frame(start), rect: rect)
var smoother = ScreenAnchor.Smoother()
let began = Date()
var tracked = 0
for i in (start + 1)..<count {
    guard let fix = tracker.track(frame(i)) else {
        print("KAYIP \(i)")
        break
    }
    tracked += 1
    let shown = smoother.push(fix.motion, rect: rect)
    let m = env["HAM"] != nil ? fix.motion : shown.motion
    print(String(format: "%d %.4f %.4f %.6f %.6f %.6f %.6f %.9f %.9f %.3f %@", i, m.dx, m.dy, m.a, m.b, m.c, m.d, m.g, m.h,
                 fix.inliers, shown.jumped ? "J" : ""))
}
FileHandle.standardError.write(String(format: "kare başına %.2f ms\n",
                                      Date().timeIntervalSince(began) * 1000 / Double(max(1, tracked))).data(using: .utf8)!)
