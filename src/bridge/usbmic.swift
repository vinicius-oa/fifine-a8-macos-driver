import Foundation
import IOKit
import IOUSBHost
import os

// MARK: - Direct USB driver for the fifine A8 microphone (MV-SILICON 0x3142:0x0c08)
//
// Why: with macOS's own USB audio driver this mic stops sending audio every few minutes
// (it answers with empty packets until reset). Streaming it directly - sending only the
// requests strictly needed - ran 30 minutes with zero freezes (tested 2026-10-26).
//
// How it takes the mic: seize the device, unconfigure it (configuration 0 destroys the
// interfaces macOS's audio service holds), re-select configuration 1 WITHOUT driver
// matching, open interface 2 (mic stream), select alt 1 (48 kHz mono 16-bit), set the
// sample rate, then read isochronous IN packets from endpoint 0x82 continuously.
// stop(resetDevice: true) resets the device so macOS gets it back.
final class UsbMic {
    static let vendorID = 0x3142, productID = 0x0c08
    let ifaceNumber = 2, altSetting = 1
    let endpoint: UInt8 = 0x82
    let sampleRate = 48000
    let framesPerRequest = 8           // 8 ms of audio per request
    let requestsInFlight = 16          // 128 ms queued ahead
    let maxPacket = 96                 // 48 samples x 2 bytes (from the endpoint descriptor)

    /// Called on the USB queue with each request's samples (mono, Float -1...1).
    var onSamples: (UnsafePointer<Float>, Int) -> Void = { _, _ in }
    var log: (String) -> Void = { print($0) }

    let queue = DispatchQueue(label: "fifine.usbmic", qos: .userInteractive)

    private var device: IOUSBHostDevice?
    private var iface: IOUSBHostInterface?
    private var pipe: IOUSBHostPipe?
    private var slots: [Slot] = []
    private var nextFrame: UInt64 = 0
    private var generation = 0                       // queue-only: bumps on every stop/start
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8 * 48)

    // Health / statistics, shared with the supervisor (guarded by lock)
    private var lock = os_unfair_lock()
    private var _lastCompletion = Date.distantPast
    private var _consecutiveEmpty = 0
    private var _fatalEnqueueError: String?
    private var stats = Stats()
    struct Stats { var packets = 0, empty = 0, errors = 0, resyncs = 0, nonZeroSamples = 0, samples = 0; var peak: Float = 0 }

    private final class Slot {
        let data: NSMutableData
        let frames: UnsafeMutablePointer<IOUSBHostIsochronousFrame>
        init(_ d: NSMutableData, count: Int) {
            data = d
            frames = .allocate(capacity: count)
            frames.initialize(repeating: IOUSBHostIsochronousFrame(), count: count)
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case notFound, step(String, Error), message(String)
        var description: String {
            switch self {
            case .notFound: return "fifine not connected"
            case .step(let s, let e): return "\(s): \((e as NSError).localizedDescription) (\((e as NSError).code))"
            case .message(let m): return m
            }
        }
    }

    var isRunning: Bool { pipe != nil }

    // MARK: Health accessors
    var lastCompletion: Date { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _lastCompletion }
    var consecutiveEmpty: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _consecutiveEmpty }
    var fatalEnqueueError: String? { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _fatalEnqueueError }
    func takeStats() -> Stats {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let s = stats; stats = Stats(); return s
    }

    // MARK: Device lookup
    private static func deviceService() -> io_service_t {
        let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        m["idVendor"] = vendorID; m["idProduct"] = productID
        return IOServiceGetMatchingService(kIOMainPortDefault, m as CFDictionary)
    }
    static var isConnected: Bool {
        let s = deviceService(); if s != 0 { IOObjectRelease(s); return true }; return false
    }
    private func childInterface(of dev: io_service_t, number: Int) -> io_service_t {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(dev, kIOServicePlane, &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        var child = IOIteratorNext(it)
        while child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               let n = IORegistryEntryCreateCFProperty(child, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               n == number { return child }
            IOObjectRelease(child)
            child = IOIteratorNext(it)
        }
        return 0
    }

    // MARK: Start (take the mic from macOS and stream)
    func start() throws {
        stop(resetDevice: false)
        let svc = UsbMic.deviceService()
        guard svc != 0 else { throw Failure.notFound }
        defer { IOObjectRelease(svc) }

        let dev: IOUSBHostDevice
        do { dev = try IOUSBHostDevice(__ioService: svc, options: [.deviceSeize], queue: queue, interestHandler: nil) }
        catch { throw Failure.step("take device", error) }
        device = dev
        do {
            do { try dev.__configure(withValue: 0, matchInterfaces: false) } catch { throw Failure.step("unconfigure", error) }
            Thread.sleep(forTimeInterval: 0.2)
            do { try dev.__configure(withValue: 1, matchInterfaces: false) } catch { throw Failure.step("configure", error) }

            var opened: IOUSBHostInterface?
            var lastError: Error?
            for _ in 0..<30 {
                let ifs = childInterface(of: svc, number: ifaceNumber)
                if ifs != 0 {
                    defer { IOObjectRelease(ifs) }
                    do { opened = try IOUSBHostInterface(__ioService: ifs, options: [], queue: queue, interestHandler: nil); break }
                    catch { lastError = error }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let ifc = opened else { throw lastError.map { Failure.step("open mic interface", $0) } ?? Failure.message("mic interface did not appear") }
            iface = ifc

            do { try ifc.selectAlternateSetting(altSetting) } catch { throw Failure.step("select 48 kHz mode", error) }
            var req = IOUSBDeviceRequest()   // UAC1 SET_CUR SAMPLING_FREQ_CONTROL on the endpoint
            req.bmRequestType = 0x22; req.bRequest = 0x01; req.wValue = 0x0100; req.wIndex = UInt16(endpoint); req.wLength = 3
            let rateBytes = NSMutableData(bytes: [UInt8(sampleRate & 0xff), UInt8((sampleRate >> 8) & 0xff), UInt8((sampleRate >> 16) & 0xff)], length: 3)
            var n = 0
            do { try ifc.__send(req, data: rateBytes, bytesTransferred: &n, completionTimeout: 1.0) }
            catch { log("note: could not set the sample rate explicitly (\((error as NSError).code)); using the device default") }

            let p: IOUSBHostPipe
            do { p = try ifc.copyPipe(withAddress: Int(endpoint)) } catch { throw Failure.step("open audio pipe", error) }
            var newSlots: [Slot] = []
            for _ in 0..<requestsInFlight {
                let d: NSMutableData
                do { d = try ifc.ioData(withCapacity: framesPerRequest * maxPacket) } catch { throw Failure.step("allocate USB buffers", error) }
                guard d.length >= framesPerRequest * maxPacket else { throw Failure.message("USB buffer too small (\(d.length))") }
                newSlots.append(Slot(d, count: framesPerRequest))
            }
            pipe = p; slots = newSlots
            os_unfair_lock_lock(&lock)
            _lastCompletion = Date(); _consecutiveEmpty = 0; _fatalEnqueueError = nil
            os_unfair_lock_unlock(&lock)
            queue.sync {
                generation += 1
                let g = generation
                var t: UInt64 = 0
                nextFrame = ifc.__frameNumber(withTime: &t) + 10
                for s in slots { enqueue(s, g) }
            }
        } catch {
            stop(resetDevice: true)    // hand the mic back to macOS if setup failed half-way
            throw error
        }
    }

    // MARK: Stop
    /// resetDevice: true hands the mic back to macOS (its own drivers re-attach).
    func stop(resetDevice: Bool) {
        queue.sync { generation += 1 }        // completion handlers from the old run become no-ops
        if let p = pipe { try? p.__abort(with: .synchronous) }
        if let i = iface { try? i.selectAlternateSetting(0); i.destroy() }
        if let d = device {
            if resetDevice { try? d.reset() }
            d.destroy()
        }
        pipe = nil; iface = nil; device = nil; slots = []
    }

    // MARK: Streaming (runs on `queue`)
    private func enqueue(_ s: Slot, _ g: Int) {
        guard g == generation, let p = pipe else { return }
        for i in 0..<framesPerRequest {
            s.frames[i] = IOUSBHostIsochronousFrame()
            s.frames[i].requestCount = UInt32(maxPacket)
        }
        let first = nextFrame
        nextFrame += UInt64(framesPerRequest)
        do {
            try p.enqueueIORequest(with: s.data, frameList: s.frames, frameListCount: framesPerRequest, firstFrameNumber: first) { [weak self] status, _ in
                guard let self, g == self.generation else { return }
                self.process(s, status: status)
                self.enqueue(s, g)
            }
        } catch {
            let code = (error as NSError).code
            let isoTooOld = Int32(truncatingIfNeeded: code) == Int32(bitPattern: 0xE00002EE)
            let isoTooNew = Int32(truncatingIfNeeded: code) == Int32(bitPattern: 0xE00002EF)
            if (isoTooOld || isoTooNew), let ifc = iface {
                // We fell behind (or ran ahead of) the bus clock: resynchronise and carry on.
                var t: UInt64 = 0
                nextFrame = ifc.__frameNumber(withTime: &t) + 12
                os_unfair_lock_lock(&lock); stats.resyncs += 1; os_unfair_lock_unlock(&lock)
                queue.asyncAfter(deadline: .now() + 0.002) { [weak self] in self?.enqueue(s, g) }
            } else {
                os_unfair_lock_lock(&lock); _fatalEnqueueError = "enqueue failed: \((error as NSError).localizedDescription) (\(code))"; os_unfair_lock_unlock(&lock)
            }
        }
    }

    private func process(_ s: Slot, status: IOReturn) {
        let base = s.data.bytes.assumingMemoryBound(to: UInt8.self)
        var offset = 0, count = 0, empty = 0, errors = 0, nonZero = 0
        var peak: Float = 0
        var consecutive = 0
        os_unfair_lock_lock(&lock); consecutive = _consecutiveEmpty; os_unfair_lock_unlock(&lock)
        if status != kIOReturnSuccess && status != kIOReturnUnderrun { errors += 1 }
        for i in 0..<framesPerRequest {
            let f = s.frames[i]
            if f.status != kIOReturnSuccess && f.status != kIOReturnUnderrun { errors += 1 }
            let n = Int(f.completeCount) / 2
            if n == 0 { empty += 1; consecutive += 1 }
            else {
                consecutive = 0
                let p = UnsafeRawPointer(base + offset).assumingMemoryBound(to: Int16.self)
                for k in 0..<n where count < 8 * 48 {
                    let v = Float(p[k]) / 32768
                    scratch[count] = v; count += 1
                    if v != 0 { nonZero += 1 }
                    if abs(v) > peak { peak = abs(v) }
                }
            }
            offset += Int(f.requestCount)
        }
        os_unfair_lock_lock(&lock)
        _lastCompletion = Date(); _consecutiveEmpty = consecutive
        stats.packets += framesPerRequest; stats.empty += empty; stats.errors += errors
        stats.samples += count; stats.nonZeroSamples += nonZero; stats.peak = max(stats.peak, peak)
        os_unfair_lock_unlock(&lock)
        if count > 0 { onSamples(scratch, count) }
    }
}
