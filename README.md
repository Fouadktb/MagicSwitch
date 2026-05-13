<p align="center">
  <img src="docs/assets/magicswitch-icon.png" alt="MagicSwitch app icon" width="128" height="128">
</p>

# MagicSwitch

MagicSwitch is a tiny macOS menu bar app for switching an Apple Magic Keyboard, Magic Trackpad, or similar Bluetooth devices between two Macs.

It coordinates both Macs over the local network: one Mac releases the configured Bluetooth devices, then the other Mac pairs/connects to them. It is meant for people who keep two Macs on the same desk and want fewer USB cables, hubs, and manual Bluetooth forget/re-pair cycles.

This is an early release. It works well for the setup it was built against, but Apple Bluetooth behavior can vary across macOS versions and devices.

## Requirements

- Two Macs on the same local network.
- macOS 13 Ventura or newer.
- Bluetooth and Local Network permissions granted when macOS asks.
- Your Magic devices paired at least once.
- For building from source: Xcode Command Line Tools.

## Install

1. Download `MagicSwitch-v0.1.3.zip` from the release.
2. Unzip it and move `MagicSwitch.app` to `/Applications` on both Macs.
3. Launch `MagicSwitch.app` on both Macs.
4. Approve Bluetooth and Local Network permissions when prompted.
5. Open the MagicSwitch menu bar icon and choose `Manage Devices...` on each Mac.
6. Click `Scan`, then add the keyboard, trackpad, mouse, or other Bluetooth peripherals you want MagicSwitch to move.

MagicSwitch is ad-hoc signed in the public zip. On first launch, macOS may ask you to confirm that you want to open it.

## Configure Devices

Most users should configure devices from the menu bar icon under `Manage Devices...`. The manager lists registered peripherals and available paired, recent, or nearby Bluetooth devices. Use `Add` and `Remove` to choose what MagicSwitch switches.

MagicSwitch reads:

```text
~/Library/Application Support/MagicSwitch/config.json
```

On first launch, MagicSwitch creates a placeholder config at that path. Replace the placeholder addresses with your devices:

```json
{
  "devices": [
    {
      "name": "Magic Keyboard",
      "address": "AA:BB:CC:DD:EE:FF"
    },
    {
      "name": "Magic Trackpad",
      "address": "11:22:33:44:55:66"
    }
  ]
}
```

You can also point to another config file:

```zsh
MAGICSWITCH_CONFIG=/path/to/config.json open /Applications/MagicSwitch.app
```

### Find Bluetooth Addresses

If you have `blueutil`:

```zsh
blueutil --paired
```

Or use macOS built-ins:

```zsh
system_profiler SPBluetoothDataType
```

Look for the device address for your keyboard, trackpad, or mouse and paste it into `config.json`.

## Use

Run MagicSwitch on both Macs. In the menu bar, click the MagicSwitch icon:

- `Switch Devices`: moves the configured devices to the other Mac when they are currently connected locally, or takes them to this Mac otherwise.
- `Take Devices to This Mac`: asks the peer Mac to release the devices, then connects them here.
- `Release Devices from This Mac`: disconnects and removes the local pairings.
- `Manage Devices...`: add or remove Bluetooth peripherals from the switch list.
- `Open Config`: opens the active config file.
- `Open Log`: opens the app log.

Logs are written to:

```text
~/Library/Logs/MagicSwitch/MagicSwitch.log
```

## Build

```zsh
scripts/build-app.sh
```

The app bundle is written to:

```text
build/MagicSwitch.app
```

To create a release zip:

```zsh
scripts/package-release.sh 0.1.3
```

The zip is written to:

```text
dist/MagicSwitch-v0.1.3.zip
```

## How It Works

MagicSwitch runs a small TCP listener on each Mac and advertises it with Bonjour as `_magicswitch._tcp`. When switching, the active Mac tells the peer to release or take the configured Bluetooth devices.

For each configured Bluetooth device, MagicSwitch uses macOS `IOBluetooth` APIs to:

- close the active connection,
- remove local pairing when releasing,
- start pairing,
- open a Bluetooth connection on the target Mac.

## Limitations

- MagicSwitch is designed for a two-Mac desk setup.
- Both Macs need to be awake and reachable on the same local network.
- If a device is not discoverable, you may need to power-cycle it or pair it once manually.
- The public build is not notarized yet.
- This project is not affiliated with Apple.
