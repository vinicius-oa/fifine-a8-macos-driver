// fifine-bridge v4: reads the fifine A8 microphone with its own direct USB driver (usbmic.swift)
// and forwards the audio into the "BlackHole 2ch" virtual device, which apps (Zoom, Teams, Meet)
// use as their microphone.
//
// Why a direct driver: with macOS's USB audio driver the mic froze every ~2.5 minutes (empty
// packets until reset). Driven directly it ran 30 minutes with zero freezes (2026-10-26).
//
// Safety net (inside the driver):
// - Freeze: 20+ consecutive empty USB packets => reset the mic and take it back (~1 s).
// - Stall / unplug / USB error: no audio for 1 s => restart; if the mic is gone, wait for it.
//   Retries back off (1, 2, 4 ... 30 s) so a missing mic never causes a reset storm.
// - Buzz guard: audio repeating sample-for-sample => mute immediately and reset the mic.
// Also: keeps BlackHole at 100% volume, opts out of App Nap, hands the mic back to macOS on exit.
// Diagnostics: create "diagnostics-on" in this folder for a stats line every 10 s.
import CoreAudio
import Foundation
import os

setvbuf(stdout, nil, _IOLBF, 0)
let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
func log(_ s: String) { print("\(fmt.string(from: Date())) \(s)") }
let supportDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()   // Contents
    .deletingLastPathComponent().deletingLastPathComponent()   // install folder (contains bridge.log, diagnostics-on)
    .path
var diagnostics: Bool { FileManager.default.fileExists(atPath: supportDir + "/diagnostics-on") }

// Keep the log from growing without bound (rotate at start if > 5 MB).
let logPath = supportDir + "/bridge.log"
if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath), let size = attrs[.size] as? Int, size > 5_000_000 {
    try? FileManager.default.removeItem(atPath: logPath + ".old")
    try? FileManager.default.copyItem(atPath: logPath, toPath: logPath + ".old")
    if let h = FileHandle(forWritingAtPath: logPath) { h.truncateFile(atOffset: 0); h.closeFile() }
}

// MARK: - BlackHole (CoreAudio) helpers
func name(_ d: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &s, &cf) == noErr else { return "" }
    return (cf?.takeRetainedValue() as String?) ?? ""
}
func findBlackHole() -> AudioObjectID? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    return ids.first { name($0).lowercased().contains("blackhole") }
}
func setRate(_ d: AudioObjectID, _ r: Float64) {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = r
    AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(8), &v)
}
func nominalRate(_ d: AudioObjectID) -> Float64 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Float64 = 0; var s = UInt32(8)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &v); return v
}
/// Sets BlackHole's input and output volume to 100% if something lowered it.
func enforceFullVolume(_ d: AudioObjectID) -> String? {
    var fixed: [String] = []
    for (scope, label) in [(kAudioDevicePropertyScopeInput, "input"), (kAudioDevicePropertyScopeOutput, "output")] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(d, &a) else { continue }
        var v: Float32 = 1; var s = UInt32(4)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &s, &v) == noErr, v < 0.999 else { continue }
        var one: Float32 = 1
        if AudioObjectSetPropertyData(d, &a, 0, nil, 4, &one) == noErr { fixed.append("\(label) \(String(format: "%.2f", v))") }
    }
    return fixed.isEmpty ? nil : fixed.joined(separator: ", ")
}

// Latency-critical audio work: never let App Nap / background throttling slow this process.
let keepAwake = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "Real-time audio bridge: fifine microphone -> BlackHole")

// MARK: - Mono ring buffer: USB queue writes, BlackHole IOProc reads
final class Ring {
    var lock = os_unfair_lock()
    let cap = 48000
    var buf = [Float](repeating: 0, count: 48000)
    var r = 0, w = 0, fill = 0
    let target = 1536                 // 32 ms: USB delivers in 8 ms bursts, BlackHole reads ~10.7 ms
    let maxFill = 4800                // 100 ms: beyond this, drop old audio to keep latency low
    var primed = false
    var underruns = 0, overflowDrops = 0, goodReads = 0, driftDrops = 0, driftRepeats = 0
    private var driftCounter = 0
    private func put(_ v: Float) {
        buf[w] = v; w = (w + 1) % cap
        if fill < cap { fill += 1 } else { r = (r + 1) % cap }
    }
    // Drift correction: the mic's USB clock and BlackHole's clock differ slightly (~0.015%,
    // ~7 samples/s). Instead of letting the buffer slowly fill up and then skipping a big
    // chunk, drop (or repeat) one single sample at most every 400 samples while the buffer
    // is off target. Single-sample adjustments are inaudible.
    func write(_ p: UnsafePointer<Float>?, _ n: Int) {      // p == nil => silence
        os_unfair_lock_lock(&lock)
        for i in 0..<n {
            let v = p?[i] ?? 0
            driftCounter += 1
            if driftCounter >= 400 && fill > target + 768 { driftCounter = 0; driftDrops += 1; continue }
            put(v)
            if driftCounter >= 400 && primed && fill < target - 512 { driftCounter = 0; driftRepeats += 1; put(v) }
        }
        if fill > maxFill { let drop = fill - target; r = (r + drop) % cap; fill = target; overflowDrops += 1 }
        os_unfair_lock_unlock(&lock)
    }
    func read(into out: UnsafeMutablePointer<Float>, frames: Int, ch: Int) {
        os_unfair_lock_lock(&lock)
        if !primed && fill >= target { primed = true }
        if primed && fill >= frames {
            for i in 0..<frames {
                let v = buf[r]; r = (r + 1) % cap
                for c in 0..<ch { out[i * ch + c] = v }
            }
            fill -= frames; goodReads += 1
        } else {
            for i in 0..<(frames * ch) { out[i] = 0 }
            primed = false; underruns += 1
        }
        os_unfair_lock_unlock(&lock)
    }
    func reset() { os_unfair_lock_lock(&lock); r = 0; w = 0; fill = 0; primed = false; os_unfair_lock_unlock(&lock) }
    func takeStats() -> String {
        os_unfair_lock_lock(&lock)
        let s = "ring ok=\(goodReads) underruns=\(underruns) big-drops=\(overflowDrops) drift-drops=\(driftDrops) drift-repeats=\(driftRepeats) fill=\(fill)"
        underruns = 0; overflowDrops = 0; goodReads = 0; driftDrops = 0; driftRepeats = 0
        os_unfair_lock_unlock(&lock); return s
    }
}
let ring = Ring()

// MARK: - Buzz guard state (written on the USB queue, read by the supervisor)
let detector = RepeatDetector()
final class Guard { var lock = os_unfair_lock(); var repeatRun = 0; var frozenSince: Date?; var mutedChunks = 0 }
let buzz = Guard()

// MARK: - The microphone (direct USB driver)
let mic = UsbMic()
mic.log = { log($0) }
mic.onSamples = { p, n in
    let verdict = detector.check(p, frames: n, stride: 1)   // 1 = repeats earlier audio
    os_unfair_lock_lock(&buzz.lock)
    if verdict == 1 { buzz.repeatRun += 1 } else if verdict == 0 { buzz.repeatRun = 0; buzz.frozenSince = nil }
    if buzz.repeatRun >= 2 && buzz.frozenSince == nil { buzz.frozenSince = Date() }
    let mute = buzz.repeatRun >= 1
    if mute { buzz.mutedChunks += 1 }
    os_unfair_lock_unlock(&buzz.lock)
    ring.write(mute ? nil : p, n)
}

// MARK: - BlackHole output (output-only "player", so no microphone permission is needed)
// Attaching an IOProc to BlackHole (a two-way device) makes macOS treat the process as a possible
// recorder and ask for microphone permission. An output-only AUHAL unit plays into BlackHole like any
// music app does, without that permission.
import AudioToolbox
let renderProc: AURenderCallback = { _, _, _, _, frames, ioData in
    guard let abl = UnsafeMutableAudioBufferListPointer(ioData) else { return noErr }
    let n = Int(frames)
    if let first = abl.first, let d0 = first.mData {
        let out0 = d0.assumingMemoryBound(to: Float.self)
        ring.read(into: out0, frames: n, ch: 1)                       // channel 1
        for i in 1..<abl.count { if let di = abl[i].mData { memcpy(di, d0, n * 4) } }   // same audio on channel 2
    }
    return noErr
}
final class Output {
    var lock = os_unfair_lock()
    var unit: AudioUnit?
    var device: AudioObjectID = 0
    var running: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return unit != nil }
    func stop() {
        os_unfair_lock_lock(&lock); let u = unit; unit = nil; device = 0; os_unfair_lock_unlock(&lock)
        if let u { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
    }
    func start(_ dev: AudioObjectID) -> String? {
        stop()
        setRate(dev, 48000)
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return "no HAL output component" }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let u = au else { return "could not create output unit" }
        var off: UInt32 = 0, on: UInt32 = 1
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, 4)   // never record
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, 4)
        var d = dev
        var st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioObjectID>.size))
        if st != noErr { AudioComponentInstanceDispose(u); return "could not select BlackHole (\(st))" }
        var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        st = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if st != noErr { AudioComponentInstanceDispose(u); return "could not set format (\(st))" }
        var cb = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: nil)
        st = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if st != noErr { AudioComponentInstanceDispose(u); return "could not set callback (\(st))" }
        st = AudioUnitInitialize(u)
        if st != noErr { AudioComponentInstanceDispose(u); return "could not initialize (\(st))" }
        st = AudioOutputUnitStart(u)
        if st != noErr { AudioUnitUninitialize(u); AudioComponentInstanceDispose(u); return "could not start (\(st))" }
        os_unfair_lock_lock(&lock); unit = u; device = dev; os_unfair_lock_unlock(&lock)
        return nil
    }
}
let output = Output()

// Output manager thread: keeps the BlackHole player running and BlackHole at 48 kHz / 100% volume.
// Runs separately so a slow macOS audio service can never delay taking over the microphone.
let outputThread = Thread {
    var lastVolumeLog = Date.distantPast
    while true {
        let bh = findBlackHole()
        if bh == nil {
            if output.running { log("BlackHole device missing"); output.stop() }
        } else if !output.running || bh != output.device {
            if let err = output.start(bh!) { log("could not start BlackHole output: \(err)") } else { log("BlackHole output running") }
        } else {
            if nominalRate(output.device) != 48000 { setRate(output.device, 48000); log("BlackHole sample rate was changed - set back to 48 kHz") }
            if let fixed = enforceFullVolume(output.device), Date().timeIntervalSince(lastVolumeLog) > 30 {
                log("BlackHole volume was lowered (\(fixed)) - set back to 100%. If this repeats, turn off \"Automatically adjust microphone volume\" in Zoom/Teams")
                lastVolumeLog = Date()
            }
        }
        Thread.sleep(forTimeInterval: 2)
    }
}
outputThread.qualityOfService = .userInitiated

// MARK: - Clean exit: give the mic back to macOS
func shutdown(_ why: String) {
    log("stopping (\(why)) - handing the mic back to macOS")
    mic.stop(resetDevice: true)
    output.stop()
    exit(0)
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); signal(SIGUSR1, SIG_IGN)
// Test hook: `kill -USR1 <pid>` makes the bridge behave exactly as if the mic had frozen.
final class TestFlag { var lock = os_unfair_lock(); var simulateFreeze = false }
let testFlag = TestFlag()
let signalSources = [SIGINT, SIGTERM, SIGUSR1].map { s -> DispatchSourceSignal in
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler {
        if s == SIGUSR1 { os_unfair_lock_lock(&testFlag.lock); testFlag.simulateFreeze = true; os_unfair_lock_unlock(&testFlag.lock) }
        else { shutdown(s == SIGTERM ? "service stopped" : "interrupted") }
    }
    src.resume(); return src
}

// MARK: - Supervisor (every 0.2 s on a background thread; signals are handled on main)
log("fifine-bridge v4 starting (direct USB driver)")
let supervisor = Thread {
    var nextAttempt = Date.distantPast, backoff = 1.0
    var lastFailureLog = "", recoveries: [Date] = []
    var lastStats = Date(), silenceWarned = false

    func recover(_ reason: String, resetMic: Bool) {
        log("\(reason) - \(resetMic ? "resetting the mic and taking it back" : "restarting")")
        mic.stop(resetDevice: resetMic)
        ring.reset(); detector.reset()
        os_unfair_lock_lock(&buzz.lock); buzz.repeatRun = 0; buzz.frozenSince = nil; os_unfair_lock_unlock(&buzz.lock)
        recoveries = recoveries.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        // After a reset macOS needs ~1 s to re-enumerate the mic. Back off harder if recoveries pile up.
        nextAttempt = Date().addingTimeInterval(recoveries.count > 5 ? 10 : 1.0)
    }

    while true {

        // Microphone
        if !mic.isRunning {
            if Date() >= nextAttempt {
                do {
                    try mic.start()
                    log("fifine connected (direct USB driver, 48 kHz)")
                    backoff = 1; lastFailureLog = ""
                } catch {
                    let msg = "\(error)"
                    if msg != lastFailureLog { log("cannot start the mic yet: \(msg) - will keep retrying"); lastFailureLog = msg }
                    nextAttempt = Date().addingTimeInterval(backoff)
                    backoff = min(backoff * 2, 30)
                }
            }
        } else {
            let sinceAudio = Date().timeIntervalSince(mic.lastCompletion)
            os_unfair_lock_lock(&buzz.lock); let frozenFor = buzz.frozenSince.map { Date().timeIntervalSince($0) } ?? 0; os_unfair_lock_unlock(&buzz.lock)
            os_unfair_lock_lock(&testFlag.lock); let simulated = testFlag.simulateFreeze; testFlag.simulateFreeze = false; os_unfair_lock_unlock(&testFlag.lock)
            if simulated {
                recover("TEST: simulated freeze (SIGUSR1)", resetMic: true)
            } else if mic.consecutiveEmpty >= 20 {
                recover("freeze detected (mic sending empty packets)", resetMic: true)
            } else if let e = mic.fatalEnqueueError {
                recover("USB error (\(e))", resetMic: UsbMic.isConnected)
            } else if sinceAudio > 1.0 {
                recover(UsbMic.isConnected ? "USB stream stalled" : "fifine disconnected", resetMic: UsbMic.isConnected)
            } else if frozenFor > 0.2 {
                recover("buzz guard: audio repeating (frozen loop), muted", resetMic: true)
            }
        }

        // Every 10 s: silence alarm + optional diagnostics
        if Date().timeIntervalSince(lastStats) >= 10 {
            let s = mic.takeStats()
            os_unfair_lock_lock(&buzz.lock); let muted = buzz.mutedChunks; buzz.mutedChunks = 0; os_unfair_lock_unlock(&buzz.lock)
            if mic.isRunning && s.samples > 0 && s.nonZeroSamples == 0 {
                if !silenceWarned { log("note: the mic is sending pure silence - its touch-mute is probably on"); silenceWarned = true }
            } else if silenceWarned && s.nonZeroSamples > 0 { log("audio from the mic is flowing again"); silenceWarned = false }
            if diagnostics {
                let db = s.peak > 0 ? String(format: "%.1f", 20 * log10(Double(s.peak))) : "-inf"
                log("stats usb packets=\(s.packets) empty=\(s.empty) errors=\(s.errors) resyncs=\(s.resyncs) peak=\(db) dB muted-chunks=\(muted) | \(ring.takeStats())")
            } else { _ = ring.takeStats() }
            lastStats = Date()
        }

        Thread.sleep(forTimeInterval: 0.2)
    }
}
supervisor.qualityOfService = .userInteractive
supervisor.start()
outputThread.start()
_ = signalSources
dispatchMain()
