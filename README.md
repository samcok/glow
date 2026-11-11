# Glow

A Mac menu bar app for Philips Hue lights.

<p>
  <img src="docs/screenshot-dark.png" alt="Glow main window" width="68%">
  <img src="docs/screenshot-menubar.png" alt="Glow menu bar popover" width="28%">
</p>

## Features

- Rooms, with brightness per light and per room
- A color wheel for color bulbs and a temperature bar for white bulbs
- Group or sync lights by selecting several, or by dropping one on another
- Recall, create, update, rename and delete scenes
- Live sync with the Hue app
- Menu bar popover and a full window; Glow leaves the Dock when the window is closed
- English and French

## Requirements

- A Mac with macOS 26 or later
- A Philips Hue Bridge on the same network

## Install

1. Download `Glow.zip` from the Releases page and move Glow to your Applications folder.
2. Glow is not notarized. On first launch, right-click it and choose Open, or go to System Settings > Privacy & Security and click Open Anyway.

## First launch

Glow looks for your bridge on the local network as soon as it opens (allow local network access if macOS asks). Pick your bridge, or type its address, then press the round link button on top of it. Glow pairs within a few seconds and saves the key in your Keychain. Use "Forget bridge" from the menu bar icon or the window to start over.

## Build from source

You need the Xcode Command Line Tools.

```
./build.sh --install
```

This builds, signs and zips `build/Glow.app`, and copies it to `~/Applications`.

## Privacy and security

- Glow only talks to your bridge on the local network. It finds it with Bonjour, and asks discovery.meethue.com only if that fails.
- No analytics, no tracking.
- The app key is stored in the macOS Keychain.
- The bridge certificate is pinned on first pairing. If it changes, Glow stops and asks you to pair again.
- The app is sandboxed. To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Limitations

- No entertainment or screen sync
- No remote access, only your local network
- Dynamic scenes are not supported

## License

MIT, see [LICENSE](LICENSE).

## Disclaimer

Glow is not affiliated with or endorsed by Signify. Philips Hue is a trademark of Signify Holding.
