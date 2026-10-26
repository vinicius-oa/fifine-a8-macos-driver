// Read-only descriptor dump for the fifine (0x3142:0x0c08).
// Takes the device from Apple's driver, issues only standard GET_DESCRIPTOR / GET_STATUS
// requests, prints hex, then resets the device so macOS re-attaches its driver.
import Foundation
import IOKit
import IOUSBHost

setvbuf(stdout, nil, _IOLBF, 0)
let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
match["idVendor"] = 0x3142
match["idProduct"] = 0x0c08
let service = IOServiceGetMatchingService(kIOMainPortDefault, match as CFDictionary)
guard service != 0 else { print("fifine not found"); exit(1) }

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

let dev: IOUSBHostDevice
do { dev = try IOUSBHostDevice(__ioService: service, options: [.deviceSeize], queue: nil, interestHandler: nil) }
catch { print("open failed: \(error)"); exit(2) }

// GET_DESCRIPTOR via control transfer. recipient: 0 = device, 1 = interface
func getDescriptor(type: UInt8, index: UInt8, lang: UInt16 = 0, recipient: UInt8 = 0, iface: UInt16 = 0, length: Int = 1024) -> Data? {
    var req = IOUSBDeviceRequest()
    req.bmRequestType = 0x80 | recipient
    req.bRequest = 6
    req.wValue = UInt16(type) << 8 | UInt16(index)
    req.wIndex = recipient == 1 ? iface : lang
    req.wLength = UInt16(length)
    let buf = NSMutableData(length: length)!
    var n = 0
    do {
        try dev.__send(req, data: buf, bytesTransferred: &n, completionTimeout: 2.0)
        return buf.subdata(with: NSRange(location: 0, length: n))
    } catch { print("  request type=0x\(String(type, radix: 16)) index=\(index) failed: \(error.localizedDescription)"); return nil }
}

if let d = getDescriptor(type: 1, index: 0, length: 18) { print("DEVICE \(hex(d))") }
if let c = getDescriptor(type: 2, index: 0, length: 9), c.count >= 4 {
    let total = Int(c[2]) | Int(c[3]) << 8
    if let full = getDescriptor(type: 2, index: 0, length: total) { print("CONFIG \(hex(full))") }
}
if let langs = getDescriptor(type: 3, index: 0, length: 255), langs.count >= 4 {
    print("LANGS \(hex(langs))")
    let lang = UInt16(langs[2]) | UInt16(langs[3]) << 8
    for i in 1...8 {
        if let s = getDescriptor(type: 3, index: UInt8(i), lang: lang, length: 255), s.count > 2 {
            let str = String(data: s.subdata(in: 2..<s.count), encoding: .utf16LittleEndian) ?? "?"
            print("STRING \(i) \"\(str)\"")
        }
    }
}
// HID report descriptors for the two HID interfaces (3 and 4)
for iface: UInt16 in [3, 4] {
    if let r = getDescriptor(type: 0x22, index: 0, recipient: 1, iface: iface, length: 512) { print("HIDREPORT if\(iface) \(hex(r))") }
}
// Microsoft OS descriptor string (index 0xEE) - many vendor tools use it
if let ms = getDescriptor(type: 3, index: 0xEE, length: 255), ms.count > 2 { print("MSOS \(hex(ms))") }
// BOS (USB 2.1+ capability descriptors)
if let b = getDescriptor(type: 0x0F, index: 0, length: 5), b.count >= 4 {
    let total = Int(b[2]) | Int(b[3]) << 8
    if let full = getDescriptor(type: 0x0F, index: 0, length: total) { print("BOS \(hex(full))") }
}

// Hand the device back to macOS.
do { try dev.reset(); print("RESET OK") } catch { print("reset failed: \(error)") }
dev.destroy()
