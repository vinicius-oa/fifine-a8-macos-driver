# fifine A8 macOS driver

A user-space USB driver that stops the **FIFINE AmpliGame A8** USB microphone from freezing on macOS.

With macOS's built-in USB audio driver, this mic goes silent (or plays a looping "buzz") every few minutes. Only unplugging it brings it back. This project reads the mic directly over USB instead, which it has handled with **zero freezes** in testing, and feeds the audio into the free [BlackHole](https://existential.audio/blackhole/) virtual device. Zoom, Teams, Meet and other apps then use BlackHole as the microphone.

> Not affiliated with FIFINE or Apple. Use at your own risk. It talks to the mic with standard USB audio requests only and never writes to the mic's firmware.

---

## The problem

- After **1–20 minutes** of use, the mic stops delivering sound. Apps receive either digital silence or the same tiny piece of audio repeated in a loop, which call participants hear as a "bee" buzz.
- It never recovers on its own. Unplugging and replugging fixes it until the next time.
- It happened on both USB-A and USB-C ports, with two different cables, through a hub and without one, on macOS 15 and macOS 27.

**How often:** a log-watching script reset the mic **646 times in about 2.5 days**, a typical gap of **2.4–3.4 minutes** between freezes (longest 22 minutes).

**What macOS logs when it happens:**

| macOS | Log message |
|---|---|
| 15.1 | kernel: `USB Sound assertion (Input Fell Behind)`, repeated about 1.5 times per second |
| 27.0 | `usbaudiod`: `AUAInputTransferManager … received N zero length transfers … USB underflow`, about 200 per second |

In plain terms: the Mac keeps asking the mic for audio every millisecond, and the mic answers with **empty packets**.

## What was ruled out

| Suspect | Test | Result |
|---|---|---|
| USB port or controller | USB-A (ASMedia) port vs USB-C hub on Apple's controller | Froze on both |
| Cable | USB-A→C cable vs USB-C→C cable | Froze with both |
| Power | Power budget and kernel power-fault logs | 100 mA needed, 500 mA available, no faults |
| Touch-mute button | Muting mid-stream, and starting a stream while muted | Mute works correctly (silence, then recovers) |
| A specific app (Chrome, Zoom) | Freezes with only a test program recording | Froze anyway |
| Clock drift | Measured sample rate vs another USB mic (Logitech Brio) | Both −3 ppm, locked to the USB clock |
| Packet sizing (48 kHz has no headroom: 96-byte packets = exactly 48 samples) | Ran at 44.1 kHz, which has headroom | Froze anyway |
| macOS version | macOS 15.1.1 and 27.0.1 | Froze on both |

## The finding

The decisive experiment was a minimal **direct USB driver**. It takes the mic away from macOS's audio driver and sends it only what's needed to stream: select the configuration, select interface 2 alternate setting 1 (48 kHz mono 16-bit), set the sample rate, then read the isochronous endpoint.

| Who drives the mic | Duration | Freezes |
|---|---|---|
| macOS's USB audio driver | 2.5 days | 646 (about 17 per hour) |
| This driver, test program | 30 min (1,799,744 packets) | **0** |
| This driver, installed as a background service | 30 min | **0**, with no USB errors and no audio dropouts |

Getting zero freezes in 30 minutes by chance, at 17 per hour, is about a 1-in-5,000 event. So **the mic itself is fine**: something in the way macOS's driver talks to this particular chip (MV-SILICON, firmware 1.00) triggers the lock-up. Which exact request is responsible wasn't isolated (see [docs/investigation.md](docs/investigation.md)). It doesn't matter for the fix, because this driver never sends it.

## How the fix works

```
 fifine A8 ──USB──► fifine-bridge (this project)                    ┌──► Zoom / Teams / Meet …
                    ├─ direct USB driver  (usbmic.swift)            │    (microphone = "BlackHole 2ch")
                    │    takes the mic from macOS, streams 48 kHz   │
                    ├─ safety net + buzz guard                      │
                    └─ output ──► BlackHole 2ch (virtual device) ───┘
```

- **Direct USB driver** (`src/bridge/usbmic.swift`) uses Apple's `IOUSBHost` framework, so it needs no kernel extension, no admin rights and no Apple-issued entitlement. It reads isochronous packets from endpoint `0x82`, 16 requests of 8 ms queued ahead.
- **Safety net:**
  - **Freeze** (20+ consecutive empty packets): reset the mic and take it back, in about 1 second.
  - **Stall, USB error or unplug:** restart. If the mic is gone, wait for it, retrying with back-off up to 30 s, so a missing mic never causes reset storms.
  - **Buzz guard** (`src/bridge/detector.swift`): live audio never repeats sample for sample, so any exact repeat of earlier audio is muted within about 20 ms and the mic is reset.
- **Output** goes to BlackHole through a standard output unit, with a ~32 ms buffer and inaudible single-sample drift correction between the USB clock and BlackHole's clock. It keeps BlackHole at 48 kHz and 100% volume, because some apps' "auto-adjust mic volume" turns it down.
- Runs as a per-user background service (LaunchAgent), opts out of App Nap, and **hands the mic back to macOS** when stopped.

## Tested on

| | |
|---|---|
| Computer | Mac mini (2023), Apple M2, 16 GB RAM (`Mac14,3`) |
| macOS | **27.0.1** (build 26A434). The problem was first diagnosed on macOS 15.1.1 (24B91). |
| Microphone | FIFINE AmpliGame A8 USB. USB ID `3142:0c08`, manufacturer string `MV-SILICON`, firmware `bcdDevice 1.00`, USB full speed (12 Mbps), USB Audio Class 1.0 |
| Connection | USB-C → USB-C cable into a Genesys Logic USB 3.2 hub on a rear Thunderbolt/USB-C port, shared with a Logitech Brio 500 webcam. The problem also reproduced on the Mac's USB-A port. |
| Virtual audio device | BlackHole 2ch 0.7.1 (Existential Audio, notarized installer) |
| Toolchain | Swift 6.0.2 (Xcode command-line tools) |
| Apps used with it | Zoom (microphone set to "BlackHole 2ch", "Automatically adjust microphone volume" off), Google Chrome |

Other A8 units, or other FIFINE models with the same chip, may behave the same way, but **only this exact setup was tested**. A different model probably has a different USB ID and interface layout. Use `tools/descdump` to check yours.

## Prerequisites

- A Mac running **macOS 15 or later**. Developed on Apple Silicon (M2); Intel Macs are untested.
- **Xcode command-line tools**, for the Swift compiler: `xcode-select --install`
- **BlackHole 2ch**:
  ```sh
  brew install --cask blackhole-2ch
  ```
  or download it from <https://existential.audio/blackhole/>. The installer asks for your admin password.
- A FIFINE AmpliGame A8 connected over USB.

## Install

```sh
git clone https://github.com/vinicius-oa/fifine-a8-macos-driver.git && cd fifine-a8-macos-driver
scripts/install.sh
```

The script:
1. checks that BlackHole is installed;
2. builds the bridge;
3. stops any older version;
4. installs it to `~/Library/Application Support/fifine-a8-bridge`;
5. starts it as the LaunchAgent `local.fifine-a8.bridge`.

Then:
1. **Click Allow** when macOS asks whether "fifine bridge" may use the microphone. macOS asks because BlackHole can also record; the bridge only plays into it. If no pop-up appears, enable it under System Settings > Privacy & Security > Microphone.
2. In your call apps, choose **"BlackHole 2ch"** as the microphone.
3. Recommended: in Zoom, turn off **Settings > Audio > "Automatically adjust microphone volume"**.

**Never** select BlackHole as a *speaker* or output device. Anything played into it would be sent to the call as if it were your voice.

## Uninstall

```sh
scripts/uninstall.sh            # stops the service; the mic is handed back to macOS
scripts/uninstall.sh --purge    # also deletes the install folder and log
```

## Day-to-day

| Task | How |
|---|---|
| See what it's doing | `~/Library/Application Support/fifine-a8-bridge/bridge.log` |
| Detailed stats every 10 s | `touch ~/Library/Application\ Support/fifine-a8-bridge/diagnostics-on` (delete the file to stop) |
| Test the safety net | `kill -USR1 $(pgrep -f fifine-bridge.app)`: behaves exactly like a real freeze |
| Restart | `launchctl kickstart -k gui/$(id -u)/local.fifine-a8.bridge` |
| "The mic is sending pure silence" in the log | The touch-mute on top of the mic is on. Tap it. |

## Limitations

- **While the bridge runs, the fifine is hidden from macOS's sound device list.** The driver owns it, and apps use "BlackHole 2ch" instead.
- **The headphone jack and the mic's media buttons don't work** while the bridge runs. The driver only streams the microphone. The touch-mute still works, because it's handled inside the mic.
- **Every rebuild needs one Allow click.** The bridge is ad-hoc signed, so each build looks like a new app to macOS's privacy system.
- The audio path adds about 32 ms of latency, which isn't noticeable in calls.
- macOS's driver is still the root trigger, and it's closed source. A future macOS update might fix it, making this project unnecessary.

## Repository layout

```
src/bridge/main.swift       bridge: supervisor, safety net, BlackHole output, buffer, logging
src/bridge/usbmic.swift     direct USB driver for the A8 (IOUSBHost, isochronous IN)
src/bridge/detector.swift   buzz guard: detects audio that repeats sample-for-sample
src/bridge/Info.plist       app bundle metadata
scripts/                    build.sh, install.sh, uninstall.sh, run-tests.sh
launchd/                    LaunchAgent template
tools/descdump.swift        read-only dump of the mic's USB descriptors (briefly takes the mic)
tools/usbreset.swift        software "replug" of the mic (only works while the bridge is NOT running)
tests/detector_test/        buzz-guard tests on synthetic audio (scripts/run-tests.sh)
docs/investigation.md       the full diagnosis, step by step, with evidence
```

## License

MIT, see [LICENSE](LICENSE).
