# Changelog

## v0.1.3

### Added

- **Opens at login into the menu bar.** Starting at login no longer puts a
  window in front of whatever you were doing. The app comes up with no window
  and no Dock icon, and everything still runs: the device listener, the
  DPI-stage and battery readings, and the wheel-direction fix. Open it from
  the menu bar when you want the window; closing that window returns it to the
  menu bar. Launching the app yourself behaves exactly as before, window and
  Dock icon included.

  An existing login item is updated automatically on first run, so there is
  nothing to switch off and on again. The same check repairs one left pointing
  at a copy of the app that has since moved.

### Fixed

- **The listener could settle on the wrong transport and stay there.** After a
  cold boot the menu bar would show the mouse connected over Bluetooth while
  the listener polled for a 2.4 GHz receiver that was never coming, so the DPI
  stage and battery never updated — for as long as the machine stayed up. It
  now checks which transport the listener is actually on, rather than assuming
  the one chosen at startup was right, and moves it within a couple of seconds
  of the mouse appearing.

### Changed

- **No longer warns that updating costs you your permissions.** It does not.
  Releases share a signing certificate, so the identity macOS records stays the
  same between versions and Input Monitoring, Bluetooth and Accessibility carry
  across — confirmed on an update between two released versions. A copy you
  build yourself is signed ad-hoc and identified by its contents, so moving
  between your own build and a release still asks once.

## v0.1.2

### Fixed

- **The Bluetooth listener pinned a CPU core.** Once the mouse was on
  Bluetooth, the listener thread sat at 97% indefinitely — 185 minutes of CPU
  in three hours — and the scroll wheel lagged, because wheel events pass
  through the same process. The wait loop pumped a run loop that had no
  sources on it, and `RunLoop.run(mode:before:)` returns immediately rather
  than sleeping in that case. Measured afterwards at 2–3%.

- **Button shortcuts sent Windows key combinations.** Copy sent Ctrl+C, which
  copies nothing on macOS and is SIGINT in a terminal; Undo sent Ctrl+Z, which
  suspends the foreground process; Select all sent Ctrl+A; Lock sent Win+L and
  Screen capture sent Shift+Win+S. These now use Command, with Shift+Cmd+4 for
  a screenshot and Ctrl+Cmd+Q to lock. `key:ctrl+c` still reaches the Windows
  form deliberately.

- **Switching Bluetooth identity stalled the listener.** The mouse carries two
  identities and the mode button cycles between them; macOS can keep both
  registered, and the app committed to whichever it found first. A stale one
  cost a full ten-second connect timeout reported as "could not reach the
  mouse". Each candidate is now tried in turn.

### Added

- **Record any key combination for a button.** The fixed list was only ever the
  subset the vendor's own software offered — the hardware accepts any HID
  modifier and usage. A capture button beside each mapping records whatever you
  press. Command combinations are recorded rather than triggering menu items,
  and Escape cancels.

## v0.1.1

### Fixed

- **"Reveal uninstaller" did nothing.** It pointed at a path that never
  existed: the uninstaller ships in the disk image, which is ejected once the
  app is dragged to Applications. A copy now lives inside the app bundle, and
  a second button runs it in Terminal so its questions can be answered.

### Changed

- **Settings reorganised** — controls, then status, then reference, then the
  one destructive action last. Uninstall previously sat in the middle of the
  panel. The version and update check moved into the settings header, having
  been reachable only from the menu bar.

## v0.1.0

First release. DPI stages with per-stage colour, polling rate, button mapping,
macros, sensor options, power timers and key debounce, over the 2.4 GHz
receiver, the USB cable or Bluetooth. Battery level over Bluetooth. Host-side
scroll-direction correction that leaves the trackpad alone. Graphical interface
and command-line tool over shared protocol code.
