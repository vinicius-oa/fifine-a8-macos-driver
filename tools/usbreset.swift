// Software "replug": USB-reset the fifine (vendor 0x3142, product 0x0c08).
import Foundation
import IOKit
import IOUSBHost

let vid = 0x3142, pidv = 0x0c08
let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
match["idVendor"] = vid
match["idProduct"] = pidv
let service = IOServiceGetMatchingService(kIOMainPortDefault, match as CFDictionary)
guard service != 0 else { print("fifine not found"); exit(1) }
do {
    let dev = try IOUSBHostDevice(__ioService: service, options: [.deviceSeize], queue: nil, interestHandler: nil)
    print("opened fifine, resetting…")
    try dev.reset()
    print("reset OK")
    dev.destroy()
} catch {
    print("reset failed: \(error)")
    exit(2)
}
