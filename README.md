# WabaUI

Recolors and darkens standard World of Warcraft UI panels — the minimap
border, action bars, unit frames, chat windows, and every standard window
(bags, character, merchant, spellbook, quest log, and more) — without
shipping any custom art. Every panel is just Blizzard's own texture,
recolored.

Targets **WoW Forever** (beta, official release 2026-11-04).

## Features

- **Per-panel darkness sliders** — every panel category (minimap, chat,
  objective tracker, action bars, each unit frame, every standard window)
  has its own 0–100% darkness slider, plus a master "Overall darkness"
  multiplier layered on top of all of them.
- **Per-panel tint colors** — every one of those same panels also gets its
  own color swatch, independent of its darkness slider: darkness controls
  how far a panel shades toward its color, the swatch controls what that
  color is. A master "Tint color (all panels)" swatch bulk-sets every
  panel to one color in a single click; pick any panel's own swatch
  afterward to give it something different.
- **Per-action-bar control** — the Main Action Bar and each extra bar
  (MultiBarLeft/Right, the bottom-left/right bars, and the extra bars) can
  either ride the master action-bar slider or use its own, via a checkbox
  next to each one. The bag bar and the gryphon-head end caps on the Main
  Action Bar are each independently adjustable the same way.
- **Extra action bar art matching** — optionally forces the extra action
  bars' button borders to match the Main Action Bar's ornate style, for
  bars whose own "Hide Bar Art" toggle isn't reachable in this client.
- **Minimap button** — left-click to toggle dark mode, right-click for
  options, drag to reposition.
- Every change is fully reversible: turning WabaUI off restores every
  touched panel to its original, unmodified appearance.

## Installation

1. Download the latest release.
2. Extract it so the addon's files sit directly under
   `Interface/AddOns/WabaUI/` (the folder name must be exactly `WabaUI` —
   it must match the `.toc` file inside it).
3. Restart the game or reload your UI (`/reload`).

## Usage

- `/wabaui` — show whether dark mode is on or off.
- `/wabaui on` / `/wabaui off` — toggle dark mode.
- `/wabaui options` — open the settings panel (also reachable via the
  minimap button's right-click, or the standard Options → AddOns menu).

The settings panel is organized into **Action Bars**, **Unit Frames**, and
**Windows** subsections, each holding that group's darkness sliders and
color swatches.

## License

All rights reserved. See [LICENSE](LICENSE).
