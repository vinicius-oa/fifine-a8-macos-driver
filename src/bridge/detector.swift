import Foundation

// MARK: - Buzz guard: detects audio that repeats sample-for-sample (frozen fifine)
//
// A live microphone never produces the same 64 samples twice. When the fifine freezes,
// macOS keeps replaying a stale piece of audio in a loop (heard as a buzz). This detector
// keeps the last 4 s of audio and checks whether each new buffer's first 64 samples
// already occurred somewhere in that history.
//
// Real-time safe: no allocation, no locks. The history is stored twice in a row
// ("mirrored") so every window is contiguous, and the scan is anchored on the loudest
// probe sample, which rarely re-occurs by chance, so the inner loop is almost always
// a single comparison.
final class RepeatDetector {
    let histLen = 192000                      // 4 s at 48 kHz
    let probe = 64                            // samples that must match exactly
    let minLevel: Float = 1.2e-4              // ~ -78 dBFS; quieter probes are not judged
    private let hist: UnsafeMutablePointer<Float>
    private let probeBuf: UnsafeMutablePointer<Float>
    private var hpos = 0                      // next write position in [0, histLen)
    private var filled = 0

    init() {
        hist = .allocate(capacity: 2 * histLen); hist.initialize(repeating: 0, count: 2 * histLen)
        probeBuf = .allocate(capacity: probe); probeBuf.initialize(repeating: 0, count: probe)
    }
    deinit { hist.deallocate(); probeBuf.deallocate() }

    /// Returns 1 = repeats earlier audio, 0 = fresh audio, -1 = (near-)silence, not judged.
    func check(_ p: UnsafePointer<Float>, frames: Int, stride: Int) -> Int {
        var result = 0
        let n = min(probe, frames)
        var maxAbs: Float = 0, anchorIdx = 0
        for i in 0..<n {
            let v = p[i * stride]; probeBuf[i] = v
            if abs(v) > maxAbs { maxAbs = abs(v); anchorIdx = i }
        }
        if maxAbs < minLevel {
            result = -1
        } else if filled >= histLen / 4 {
            let start = (hpos - filled + histLen) % histLen
            let base = UnsafePointer(hist + start)    // contiguous thanks to mirroring
            let windows = filled - n + 1
            let anchor = probeBuf[anchorIdx]
            let a = base + anchorIdx
            var j = 0
            scan: while j < windows {
                if a[j] == anchor {
                    var k = 0
                    while k < n && base[j + k] == probeBuf[k] { k += 1 }
                    if k == n { result = 1; break scan }
                }
                j += 1
            }
        }
        for i in 0..<frames {
            let v = p[i * stride]
            hist[hpos] = v; hist[hpos + histLen] = v
            hpos += 1; if hpos == histLen { hpos = 0 }
        }
        filled = min(filled + frames, histLen)
        return result
    }

    func reset() { hpos = 0; filled = 0 }
}
