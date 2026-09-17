# code-rain-mac

Matrix-style code rain screensaver for macOS, written as a single-file Swift
menu-bar app. No `.saver` bundle, no System Settings dance: it runs in the
background, covers every screen after an idle timeout, and gets out of the way
on the first key press or mouse move.

Windows 10 / 11 port (native `.scr`): [code-rain-win](https://github.com/MakiDevelop/code-rain-win)

## Features

- Green katakana + digits with a white head glyph, horizontally mirrored like the film
- Bitmap persistence trail (fade-to-black back buffer) for the canonical look
- Antialiasing off on purpose: crisp 8-bit pixel edges, no gray residue
- **CPU-reactive glitch engine**: the rain samples *external* CPU load
  (total minus the app itself) and turns it into frozen columns and bit-rot
  glyphs (`█▓▒░■◈�`). A busy machine literally corrupts the rain.
- One full-screen window per display, all `NSScreen.screens`
- Menu-bar icon `⣿` with Test Now / Dismiss / Quit
- Global hotkey **⌃⌥⌘M** to trigger instantly, registered through Carbon
  `RegisterEventHotKey`, so no Accessibility permission prompt
- Idle trigger after 180 s of no input, auto-dismiss on any input
- Small HUD in the corner showing EXT / TOTAL / SELF CPU load

## Requirements

- macOS 13 or later
- Xcode command line tools (Swift 5.9+)

## Install

```bash
git clone https://github.com/MakiDevelop/code-rain-mac.git
cd code-rain-mac
./install.sh
```

`install.sh` does five things: `swift build -c release`, assembles
`CodeRain.app`, copies it to `~/Applications`, registers it as a hidden Login
Item, and launches it. Look for `⣿` in the menu bar.

## Uninstall

```bash
./uninstall.sh
```

Kills the app, removes the Login Item, deletes `~/Applications/CodeRain.app`.

## Usage

| Action | How |
|---|---|
| Trigger now | ⌃⌥⌘M, or menu bar `⣿` → Test Now |
| Dismiss | Any key, mouse move, or click (after a short grace period) |
| Change idle timeout | Edit `idleThresholdSeconds` in `Sources/CodeRain/main.swift`, re-run `./install.sh` |
| Quit | Menu bar `⣿` → Quit |

## Project layout

```
Package.swift                 SwiftPM manifest (single executable target)
Sources/CodeRain/main.swift   Everything: CPU sampler, glitch engine, rain view, idle monitor, hotkey, app delegate
install.sh / uninstall.sh     Build, bundle, Login Item registration
```

## License

MIT
