# asctl — Attack Shark X3 for macOS

A native macOS configuration tool for the Attack Shark X3 mouse. Sets DPI stages,
polling rate, button mappings, macros, sensor options and power timers over the
2.4 GHz receiver, the USB cable, or Bluetooth.

The vendor supplies configuration software for Windows only. This project
reverse-engineers its HID protocol and reimplements it natively, with no kernel
extension, no daemon and no dependencies — a single Swift binary using IOKit and
CoreBluetooth, providing both a graphical interface and a command-line interface
over shared protocol code.

```bash
asctl gui
asctl dpi 800,1600,3200 --active 2
```

## Contents

- [Background](#background)
- [Requirements](#requirements)
- [Installation](#installation)
- [Permissions](#permissions)
- [Feature status](#feature-status)
- [Graphical interface](#graphical-interface)
- [Command-line interface](#command-line-interface)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Protocol notes](#protocol-notes)
- [Implementation notes](#implementation-notes)
- [Transports](#transports)
- [Known issues](#known-issues)
- [Contributing](#contributing)

## Background

The X3 ships with a Windows-only configuration utility. On macOS the mouse
functions as a generic pointing device, and every hardware capability that
utility exposes — DPI stages, polling rate, button remapping, macros, sensor
tuning — is unreachable.

A separate limitation is specific to macOS. The system provides a single
"Natural scrolling" preference that applies simultaneously to the trackpad and
to every connected mouse. There is no per-device setting, and the X3 provides no
on-device alternative because that control resides in the Windows utility.
Correcting wheel direction independently of the trackpad therefore requires
host-side interception.

The configuration protocol is write-only. The device accepts settings but
provides no means of reading them back: no state query, no readback, no factory
reset. This is confirmed by the vendor binary, which contains 29 calls to
`SetFeature` and none to `GetFeature`. The vendor application does not read from
the device either; it displays what it last transmitted.

Two consequences follow, and they govern how this project is built and tested.
A setting cannot be confirmed by reading it back, and the device acknowledges a
malformed report exactly as it acknowledges a correct one. Acceptance therefore
proves nothing. Every feature listed below was confirmed by operating the mouse
and measuring the result.

## Requirements

- macOS 12 or later
- Apple silicon or Intel
- For building: the Xcode command line tools

## Installation

Download the [latest release](https://github.com/yourchocomate/attacksharkx3/releases/latest),
open the disk image, and drag `asctl.app` to Applications. The release also
includes a command-line-only tarball. Both are universal binaries.

### First launch

Release builds are ad-hoc signed rather than notarised, as notarisation requires
a paid Apple Developer ID. Gatekeeper will refuse the first launch. Either remove
the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/asctl.app
```

Or attempt to open the app, then approve it under **System Settings ▸ Privacy &
Security ▸ Security ▸ Open Anyway**.

Note that the older method of right-clicking and selecting Open no longer
bypasses Gatekeeper on current macOS versions.

### Building from source

```bash
swift build -c release
.build/release/asctl selftest      # verifies generated payloads; no hardware required
INSTALL=1 Scripts/make-app.sh      # build the app bundle and install it
```

## Permissions

macOS attributes privacy permissions to the process that requests them. Grant
them to `asctl.app` when using the application, or to your terminal emulator when
using the CLI.

| Operation | Permission required |
|---|---|
| Configuration over the 2.4 GHz receiver or USB cable | Input Monitoring |
| Bluetooth configuration and battery level | Bluetooth |
| Scroll-direction correction | Accessibility |

Bluetooth access is enforced per process. A process without it is terminated with
`SIGABRT` and no diagnostic output, so Bluetooth commands should be run from a
terminal that has been granted access, or from the app bundle.

## Feature status

Every entry marked **verified** was tested on physical hardware and confirmed by
measurement — polling rate by timing the report stream, DPI by measuring pointer
travel, debounce by timing click intervals, and so on. Nothing is marked verified
on the strength of the device accepting a report, because the device accepts
incorrect reports just as readily.

| Feature | Status |
|---|---|
| DPI stages and per-stage colour | Verified — multi-stage ladders, high-range stages |
| Polling rate (125/250/500/1000 Hz) | Verified — measured report rate |
| Button mapping | Verified — full action table, button order confirmed, factory defaults recoverable |
| Macros | Verified — upload, fragmentation, execution, keyboard and mouse events, all loop modes |
| Lift-off distance (1 mm / 2 mm) | Verified |
| Ripple control | Verified at high DPI; three replications |
| Motion sync | Verified at high DPI and 1000 Hz; three replications |
| Angle snap | Verified, but n=2; treat as provisional |
| Key debounce | Verified — field counts 2 ms units (see Implementation notes) |
| Bluetooth configuration | Verified over GATT — identical reports and acknowledgements |
| Battery level | Verified over Bluetooth — one read per power cycle (see Implementation notes) |
| Status events (DPI stage, write acknowledgements) | Verified |
| Scroll direction independent of macOS | Working — host-side event tap, wheel only |
| Profiles | Host-side; the device's own profile slots are unused by this product |
| Sleep and deep sleep timers | Mapped; writes accepted, behaviour unmeasured |
| Battery event `0x4010` | Decoded from the vendor binary; not observed firing |
| Lighting | Not implemented on this model (see Implementation notes) |
| Reading current settings | Not possible — the protocol is write-only |

## Graphical interface

`asctl gui` opens a window arranged like the vendor application: button and
profile controls on the left, a mouse diagram in the centre, and a settings
accordion on the right. It runs in the menu bar and reports the active DPI stage
and battery level.

Differences from the vendor application:

| | Vendor | asctl |
|---|---|---|
| Transport | Auto-detected; reduced feature set on Bluetooth | Selectable; full feature set on both |
| Feedback | None; displays what it believes it sent | Every byte sent and every acknowledgement received |
| Dry run | Not available | Preview exact bytes without writing |
| DPI stage colour | 16 presets | Full RGB per stage |
| Sensor options | Hidden on Bluetooth | Always available |
| Bluetooth recovery | None | One-click controller cycle for the dead-cursor fault |

The interface rejects button maps containing no left click and warns on
mode-switch entries, both of which are unrecoverable without a known-good
mapping.

## Command-line interface

```bash
asctl list                                # connected interfaces and transport
asctl dpi 800,1600,3200,6400 --active 2
asctl pollrate 1000
asctl buttons left,right,middle,dpi_cycle,mode_switch,forward,backward
asctl power --sleep 10 --debounce 5
asctl scroll standard
asctl profile save daily
asctl --ble dpi 1600                      # any write command accepts --ble
asctl fix-bluetooth
```

`asctl help` documents the full surface. Any write can be previewed with
`--dry-run`.

`list`, `descriptor`, `probe`, `get`, `status` and `watch` are read-only.

`set` and `send` write arbitrary bytes to the device. Not every command is
mapped, so an unrecognised value could persist unexpected state to flash. No
damage to an X3 has been observed, and no write here has been proven safe.

## Updating

The menu bar item includes an update check. It compares the installed version
against the latest published release, verifies the download against the
`SHA256SUMS.txt` published alongside it, retains the existing installation until
the replacement is in place, and restarts into the new version.

Permissions survive an update provided the release was signed with a
certificate. macOS records a *designated requirement* when permissions are
granted, and what that requirement contains depends on how the build was signed:

| Signature | Designated requirement | Permissions after an update |
|---|---|---|
| Ad-hoc | `cdhash H"…"` — a hash of one specific build | Must be granted again |
| Certificate | `identifier "…" and certificate root = H"…"` | Preserved |

Release builds are signed with a self-signed certificate, which is enough to
make the requirement stable — it is identical for every build the certificate
signs, so TCC continues to recognise the application. A build produced without
the certificate falls back to ad-hoc signing and will re-prompt; the application
says so when it finishes updating, so the resulting loss of Bluetooth access is
not mistaken for a fault.

This does not affect Gatekeeper. A self-signed certificate is trusted by
nothing, so the first launch still requires the step described under
[First launch](#first-launch). Removing that step requires notarisation, which
requires a paid Apple Developer ID.

### Signing your own builds

`Scripts/make-signing-cert.sh` generates the certificate and prints instructions
for adding it to the repository as the secrets `MACOS_SIGNING_CERT` and
`MACOS_SIGNING_PASSWORD`. The release workflow uses them when present and falls
back to ad-hoc signing when absent, so forks and pull requests still build.

To sign locally, import the certificate and set `SIGN_IDENTITY`:

```bash
SIGN_IDENTITY="asctl self-signed" Scripts/make-app.sh
```

Keep a backup of the certificate. Replacing it changes the designated
requirement, which costs every existing installation its permissions once.

## Uninstalling

```bash
Scripts/uninstall.sh              # prompts before removing saved profiles
Scripts/uninstall.sh --keep-data  # remove the application, retain ~/.config/asctl
Scripts/uninstall.sh --all        # remove everything
```

The script is also included in the disk image. It quits the running application,
removes both launch agents, revokes the Privacy & Security entries, deletes the
application and window preferences, and reports what it found before making any
changes.

Settings already written to the device are not affected. The protocol provides no
readback and no factory reset, so the mouse retains its last configuration until
something overwrites it.

Profiles are stored in `~/.config/asctl`. As the device cannot be read back, that
directory is the only existing record of a configuration, which is why the
uninstaller prompts before removing it.

## Protocol notes

A configuration report sent in isolation is acknowledged and then ignored. It
takes effect only when preceded immediately by:

```
0C 0A 01 FE 01 FE 00 00 00 00
```

`asctl` always sends this preamble. Two consequences are worth noting for anyone
extending this work:

1. `IOHIDDeviceSetReport` returning success indicates that the transport accepted
   the bytes. It carries no information about whether the device applied the
   setting.
2. The device's acknowledgement (`0x5010` on the status channel) indicates that
   the report was well-formed and received. It does not indicate that the setting
   was applied; a report can be acknowledged and have no effect.

## Implementation notes

Three features behave differently from what the protocol or the vendor interface
suggests. Each is documented here because the difference is not discoverable from
the wire format alone.

### Lighting is not implemented on this model

The protocol defines a complete lighting report: twelve modes, RGB colour,
brightness and speed. On the X3 none of it has any effect. Reports are accepted
and acknowledged, and nothing changes.

The light beside the scroll wheel is a battery and charge indicator, not
addressable RGB — off on battery, magenta while charging, green at full. The
vendor application does not expose a lighting panel for this model either. The
protocol fields exist because one firmware serves a product range; on the X3
nothing consumes them.

`asctl light` is retained because the same report carries the sleep timers and
key debounce, which do work. It warns that the lighting fields are inert.

### Battery level: one read per power cycle

The level is read from GATT characteristic `2A19`, the standard Bluetooth Battery
Level, over the Bluetooth link.

**Reading the characteristic increments it.** Three reads within a tenth of a
second return values one apart; thirty seconds of idle time changes nothing. The
value therefore reflects how many times it has been read since the mouse last
powered on, not elapsed time, and it continues past 100 indefinitely. It resets
only when the device power-cycles.

Only the first read after power-up returns the true level. `asctl` performs
exactly one read when the Bluetooth link is established, caches the result, and
does not read again until the mouse has been switched off and on. This is the
same approach macOS takes: it reads once at connection and serves a cached value
thereafter, which is why the figure in System Settings stays correct.

Two consequences for users:

- The level does not track discharge during a session. It is a snapshot from when
  the link came up, and the interface shows when it was taken.
- If another tool has read the characteristic since the mouse powered on, the
  value will read high. Power-cycling the mouse restores it.

The 2.4 GHz receiver has no equivalent. The vendor obtains the level there from a
status event, `0x4010`, which carries a level of 1–10 in its high byte and is
pushed by the device on a six-second interval. That event is decoded here but has
not been observed firing.

### Key debounce is expressed in 2 ms units

The vendor interface presents key debounce as a slider labelled 2–25 ms, and the
wire field accepts 2 to 25. Measured against click intervals, the resulting
debounce floor is 2.00× the configured value.

The field counts 2 ms units, so the vendor's stated 2–25 ms range is actually
4–50 ms. `asctl` transmits the raw value so that settings match between the two
applications, and displays the effective figure alongside it.

## Transports

| Transport | Channel | Configuration |
|---|---|---|
| 2.4 GHz receiver | HID feature reports | Yes |
| USB cable | HID feature reports | Yes |
| Bluetooth | GATT — service `FEE0`, write `FEE3`, notify `FEE4` | Yes, with `--ble` |

Over Bluetooth the device exposes a one-byte maximum feature report, so HID
feature reports cannot carry configuration. The same commands are sent over GATT
instead, which is also what the vendor application does. Subscribing to `FEE4` is
mandatory; writes issued before subscription are discarded silently.

The device presents Microsoft's `045E:0040` identity over Bluetooth, so a genuine
Microsoft mouse will also match that identifier.

## Known issues

### Dead cursor after a Bluetooth reconnection

The mouse occasionally reconnects over Bluetooth with functioning buttons and no
pointer movement. This is a firmware fault. In that state every configuration
report, including the one that programs the sensor's registers, is delivered and
acknowledged, and none restores motion reporting. Only tearing down the Bluetooth
link clears it.

```bash
asctl fix-bluetooth
```

The fault does not occur over the 2.4 GHz receiver.

## Contributing

The most valuable contribution is ground truth from a USB capture: run the
Windows utility, change a single setting, and capture the resulting feature
report. This converts an inference into a fact without risk to hardware.

Also of interest:

- **Other Attack Shark models.** The report framing appears to be shared across
  the range. `asctl light-probe` is retained so that lighting can be re-tested on
  a model that implements it.
- **The battery event `0x4010`.** Decoded from the vendor binary but never
  observed firing on either transport. The vendor application arms a six-second
  watchdog for it and displays a sleep indicator when it lapses, which suggests
  the event is routine on a supported configuration. Untested: the mouse running
  on battery power with the receiver connected.
- **Measurement of the sleep timers**, currently accepted by the device but
  unverified.
- **A third replication of angle snap**, which currently rests on n=2.
- **Confirmation of the `1D57:FA60` identity.** Only `FA61` has been observed.

### Verification approach

Because the protocol is write-only and the device acknowledges malformed reports,
no feature here is accepted on the basis that a write succeeded. Each was
exercised on hardware and measured: polling rate by timing the input report
stream, DPI by pointer travel, debounce by click intervals, lift-off distance and
the sensor options by controlled movement at the operating points where they
apply.

Two failure modes recur often enough to be worth stating for anyone extending
this:

- **A null result at the wrong operating point.** Ripple control appears inert
  until tested at high DPI; motion sync until 1000 Hz is also set. Two
  replications proved insufficient — motion sync came close to a false positive
  at n=2, which is why angle snap is still marked provisional.
- **A sampling rate that makes two explanations indistinguishable.** Reading the
  battery characteristic once per second cannot separate "increments per read"
  from "increments per second". Varying the interval resolves it immediately.

Where a feature's existence is uncertain, establish that before designing
experiments to measure it. A null result cannot distinguish a feature that is
absent from one that is present and being driven incorrectly.

## Repository layout

```
Scripts/make-app.sh      Builds asctl.app (INSTALL=1 also installs it)
Scripts/make-dmg.sh      Builds a drag-to-install disk image
Scripts/make-icon.swift  Generates the application icon
Scripts/uninstall.sh     Removes the application, agents, permissions and data
Sources/asctl/
  GUI/                   SwiftUI interface (asctl gui)
    MainView.swift         Three-column window
    AppState.swift         Editable configuration and apply logic
    MouseDiagram.swift     Mouse diagram with per-button callouts
    Sections.swift         Accordion, sliders, DPI rows, log pane
    StatusMonitor.swift    Device event listener
    MenuBarView.swift      Menu bar popover and update control
    Transport.swift        HID and GATT transmission with logging
    GUIApp.swift           NSApplication bootstrap
  HID.swift              IOKit device discovery and feature-report I/O
  BLE.swift              CoreBluetooth GATT transport
  Protocol.swift         Report builders, checksum, action tables
  ReportDescriptor.swift HID report descriptor parser
  Watch.swift            Input-report capture and rate measurement
  Profile.swift          Host-side profiles
  Scroll.swift           Scroll-direction event tap and login agents
  Updater.swift          Release checking, verification and installation
  Version.swift          Version reporting and comparison
  BluetoothPower.swift   Bluetooth controller power cycling
  LightProbe.swift       Lighting sweep, retained for models with lighting
  PowerTest.swift        Debounce and sleep-timer measurement
  BatteryProbe.swift     Battery characteristic investigation
  AppPaths.swift         Configuration and profile locations
  SelfTest.swift         Payload verification without hardware
  main.swift             CLI surface
```

## Legal

This project constitutes reverse engineering for interoperability: producing
software that operates with hardware the user owns. No vendor code is copied,
redistributed or included in this repository, which contains only original code
and a description of an interface.

Not affiliated with or endorsed by Attack Shark.

## Author

Habibur Rahman — [@yourchocomate](https://github.com/yourchocomate)

## License

[MIT](LICENSE) © 2026 Habibur Rahman
