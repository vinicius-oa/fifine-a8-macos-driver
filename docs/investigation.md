# Investigation notes

How the cause was narrowed down, in order. Times are local (UTC−3), October 2026.

## 1. First symptom: the mic is connected but silent

- macOS listed the mic, it was the default input, permissions were fine, and its input volume was 100%.
- A test recorder received **exact digital zeros** from the fifine, while the Logitech Brio webcam mic worked normally.
- Unplugging and replugging was the only fix, and it only lasted a while.

## 2. The driver complains: "Input Fell Behind" (macOS 15.1.1)

- The kernel log showed `USB Sound assertion (Input Fell Behind)` from Apple's USB audio driver at a steady ~88 per minute (the log's rate limit), starting **1–16 minutes after each replug** and stopping only on unplug.
- 50,000+ of these assertions in about 10 hours.
- While it was happening, recorded audio was **frozen**: identical peak and RMS values every 5 seconds. The driver was replaying a stale buffer, heard by others as a buzz.
- Restarting the audio stream without a replug did **not** recover it, so the stuck state was in the device, not in the app.

## 3. Suspects eliminated

| Hypothesis | Experiment | Outcome |
|---|---|---|
| Third-party USB-A controller (ASMedia ASM3142) | Moved to a USB-C hub on Apple's own controller | Still froze |
| Cable | USB-A→C cable vs USB-C→C cable | Still froze |
| Bus power | Checked the power budget (mic needs 100 mA, port gives 500 mA) and searched for over-current or power-fault logs | Nothing found |
| Touch-mute button | Muted mid-stream; started streaming while muted | Behaved correctly: silence, then recovered on unmute |
| Chrome or a specific website | Froze with only a test recorder running; also froze 3.5 min after a site opened, with no event at that moment | Not the trigger |
| Clock drift | Measured the delivered sample rate against the Brio | Both −3 ppm, locked to the USB frame clock |
| No packet headroom at 48 kHz (`wMaxPacketSize` 96 = exactly 48 samples) | Switched the mic to 44.1 kHz, where 96 bytes leaves room | Froze twice in the first 3 minutes |
| Old macOS | Updated to macOS 27.0.1 | Still froze; only the log message changed |

## 4. Better evidence on macOS 27

macOS 27 replaced the kernel driver with a user-space one (`usbaudiod`), which logs in more detail:

```
AUAInputTransferManager completeBlock block starting at frame … recieved 8 zero length transfers … USB underflow -708
```

So the host keeps polling the isochronous IN endpoint every millisecond, and the device keeps answering with **zero-length packets**. None appear while the mic is healthy (checked over minutes of normal streaming), and about 200 per second appear once it is stuck.

## 5. The mic's own description (USB descriptors)

Dumped with `tools/descdump`:

- Vendor string `MV-SILICON`, product `fifine Microphone`, firmware `bcdDevice 1.00`. The "serial number" is `20190808`, almost certainly the date of the chip vendor's SDK.
- USB Audio Class 1.0. Interface 0 = audio control (feature units with mute and volume). Interface 1 = headphone output (48/44.1 kHz stereo). Interface 2 = microphone: alt 1 is 16-bit mono, alt 2 is 24-bit, endpoint `0x82` isochronous IN, sync type *adaptive*, `wMaxPacketSize` 96 (16-bit) or 144 (24-bit).
- Interface 3 is HID (media keys: volume, play/pause, mute). Interface 4 is a vendor HID channel (usage page `0xFF00`, usage `0x55AA`, 256-byte reports), probably the chip vendor's tuning or configuration tool. It is not touched.
- The firmware answers any unknown string index with the serial string, more evidence of a minimal firmware build.

## 6. The decisive test: drive the mic directly

The test program (`usbmic`, now `src/bridge/usbmic.swift`) took the mic from macOS like this:

1. Seize the USB device.
2. Set configuration 0. This destroys the interfaces that macOS's audio service holds; seizing an interface it holds is refused.
3. Set configuration 1 *without* driver matching, so macOS doesn't re-attach.
4. Open interface 2, select alt 1, send `SET_CUR SAMPLING_FREQ` (48000) to endpoint `0x82`.
5. Stream isochronous IN, logging every packet's size.

Results:

| Run | Duration | Packets | Empty packets | Freezes |
|---|---|---|---|---|
| Direct driver (test) | 30 min | 1,799,744 | 19 isolated, never more than 1 in a row | **0** |
| Bridge v4.2 as a background service | 30 min | ~1.8 M | 0 | **0** |
| macOS driver (baseline) | ~2.5 days | – | – | 646 (~17/h) |

Every packet was exactly 96 bytes: no 47- or 49-sample packets, which confirms the device clock is locked to the USB frame clock.

**Conclusion:** the freeze is triggered by how macOS's driver talks to this chip, not by the chip on its own. The exact trigger wasn't isolated. Candidates are the duplex headphone-output stream that macOS always runs, and its feature-unit or volume control traffic. A prepared variant that adds the output stream was never run, because it doesn't change the fix.

## 7. Side lessons

- **BlackHole is a two-way device.** On macOS 27, any process that attaches to it, even output-only, is checked against the *microphone* permission. Ad-hoc signed builds trigger a new prompt after every rebuild.
- When the bridge captured through Core Audio (the early versions), macOS applied **Voice Isolation** to it, which removed room noise and made BlackHole look like it had gaps. The direct driver bypasses Core Audio capture entirely.
- Zoom's "Automatically adjust microphone volume" lowered BlackHole's volume to 0.71 (about −19 dB). The bridge now resets it to 100%.
- Some vendor software (Logitech's RightSight, Chrome's device probes) tries to open every USB device it sees. It fails harmlessly.
