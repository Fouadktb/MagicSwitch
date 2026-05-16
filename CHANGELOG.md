# Changelog

## 0.1.8 - 2026-05-16

- Added a `Repair Devices on This Mac` action for stale Bluetooth pairings after sleep.
- Prevented overlapping local switch operations from stacking delayed release/take commands.
- Increased peer command timeouts so slow Bluetooth recovery can finish instead of failing early.
- Added stronger reconnect recovery for devices that are paired but not usable.

## 0.1.7 - 2026-05-13

- Changed the DMG installer background to use a straight drag arrow.

## 0.1.6 - 2026-05-13

- Rebuilt the DMG installer background from SVG and fixed the install arrow.

## 0.1.5 - 2026-05-13

- Added a macOS disk image installer with a drag-to-Applications layout.

## 0.1.4 - 2026-05-13

- Added target Mac selection for setups with more than two Macs.
- Added peripheral import from the selected target Mac, so fresh installs can learn devices that are currently only configured on another Mac.
- Documented required macOS permissions and clarified that Remote Login is not required.

## 0.1.3 - 2026-05-13

- Replaced the `MS` menu bar text with a native image-only status bar symbol.

## 0.1.2 - 2026-05-13

- Fixed cropped smaller app icon representations in the release bundle.

## 0.1.1 - 2026-05-13

- Added a basic macOS app icon.

## 0.1.0 - 2026-05-13

- Initial public release.
- Menu bar app for switching paired Apple Magic Keyboard and Magic Trackpad devices between two Macs.
- Bonjour peer discovery over the local network.
- Local JSON config for device names and Bluetooth addresses.
- Native device manager for adding and removing paired, recent, or nearby Bluetooth peripherals.
- Ad-hoc signed app bundle and release zip packaging.
