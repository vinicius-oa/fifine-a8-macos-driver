import Foundation
// Deterministic RNG
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
func gauss() -> Double { let u = max(rnd(), 1e-12), v = rnd(); return sqrt(-2 * log(u)) * cos(2 * .pi * v) }
func q16(_ x: Double) -> Float { Float((x * 32768).rounded() / 32768) }   // 16-bit quantization like the mic
func noise(_ n: Int, dB: Double) -> [Float] { let a = pow(10, dB / 20) / 3; return (0..<n).map { _ in q16(gauss() * a) } }

func run(_ name: String, _ signal: [Float], expectFrozen: Bool, frozenStartsAt: Int? = nil) {
    let d = RepeatDetector()
    var repeats = 0, run = 0, firstFrozen: Int? = nil
    var t = 0.0
    var i = 0
    while i + 512 <= signal.count {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let v = signal.withUnsafeBufferPointer { d.check($0.baseAddress! + i, frames: 512, stride: 1) }
        t = max(t, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        if v == 1 { repeats += 1; run += 1 } else if v == 0 { run = 0 }
        if run >= 2 && firstFrozen == nil { firstFrozen = i }
        i += 512
    }
    var verdict = "frozen detected: " + (firstFrozen.map { String(format: "yes, at %.3f s", Double($0) / 48000) } ?? "no")
    if let s = frozenStartsAt, let f = firstFrozen { verdict += String(format: " (%.0f ms after the loop started)", Double(f - s) / 48) }
    let pass = (firstFrozen != nil) == expectFrozen
    print("\(pass ? "PASS" : "FAIL") \(name): repeats=\(repeats), \(verdict), worst call \(String(format: "%.2f", t)) ms")
}

let sec = 48000
run("normal room noise -55 dB, 30 s", noise(30 * sec, dB: -55), expectFrozen: false)
run("very quiet room -75 dB, 30 s", noise(30 * sec, dB: -75), expectFrozen: false)
run("near-silence -90 dB (mostly zeros), 30 s", noise(30 * sec, dB: -90), expectFrozen: false)
var speech = noise(30 * sec, dB: -40)
for k in speech.indices { speech[k] *= Float(0.2 + 0.8 * abs(sin(Double(k) / 4000))) }
run("speech-like modulated audio, 30 s", speech, expectFrozen: false)
// Frozen: 3 s live, then the last 32768 samples loop (aligned to 512)
var live = noise(3 * sec, dB: -50)
let loopA = Array(live.suffix(32768))
var frozenA = live; while frozenA.count < 6 * sec { frozenA += loopA }
run("freeze, 0.68 s loop (aligned)", frozenA, expectFrozen: true, frozenStartsAt: 3 * sec)
// Frozen with a loop length that is NOT a multiple of 512
live = noise(3 * sec, dB: -50)
let loopB = Array(live.suffix(30001))
var frozenB = live; while frozenB.count < 6 * sec { frozenB += loopB }
run("freeze, 0.625 s loop (unaligned)", frozenB, expectFrozen: true, frozenStartsAt: 3 * sec)
// Frozen with a long 3 s loop
live = noise(4 * sec, dB: -50)
let loopC = Array(live.suffix(3 * sec))
var frozenC = live; while frozenC.count < 12 * sec { frozenC += loopC }
run("freeze, 3 s loop", frozenC, expectFrozen: true, frozenStartsAt: 4 * sec)
