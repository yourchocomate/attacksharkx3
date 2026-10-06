# Changelog

## v0.1.3

### Added

- **Opens at login into the menu bar.** Starting at login no longer puts a
  window in front of whatever you were doing. The login item starts the app
  with no window and no Dock icon; the listener, the DPI-stage and battery
  readings and the wheel-direction fix all run as before. Opening it from the
  menu bar gives you the window and a Dock icon, and closing it returns to the
  menu bar. Launching the app yourself behaves exactly as it did.

  An existing login item is rewritten automatically on first run, so there is
  nothing to toggle. The check also repairs one left pointing at a bundle that
  has since moved.

### Fixed

- **The menu bar showed nothing after a background start.** Not connected, DPI
  unknown, no battery. Every startup action was tied to the main window
  appearing, so with no window none of it ran — including the wheel-direction
  fix, which is most of the reason to open at login. Startup now happens
  independently of whether a window exists.

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
