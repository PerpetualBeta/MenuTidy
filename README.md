# MenuTidy

A lightweight macOS menu bar manager that keeps your menu bar clean by collapsing third-party icons out of sight. Click to expand and reveal them when needed.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/MenuTidy/releases/latest/download/MenuTidy.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/MenuTidy/releases/latest)** — unzip and drag `MenuTidy.app` to your Applications folder.

After installation, launch MenuTidy — a chevron icon (`»`) appears in your menu bar.

## How It Works

MenuTidy adds two elements to your menu bar: a **chevron** (the visible icon you click) and a **spacer** (an invisible divider). When collapsed, the spacer expands to push icons to its left out of view.

```
Expanded:   [hidden icons] | [visible icons] [chevron] [system icons]
Collapsed:                   [visible icons] [chevron] [system icons]
```

- **Left-click** the chevron to toggle between collapsed and expanded
- **Right-click** the chevron to access the settings menu

## Setting Up

On first launch, MenuTidy starts in the **expanded** state so you can arrange your icons.

### Choosing which icons to hide

All icons to the **left** of the spacer will be hidden when collapsed. All icons to the **right** of the spacer will remain visible at all times.

To move an icon between the hidden and visible zones:

1. Hold **⌘** (Command) — a glowing blue bar will appear in your menu bar showing where the spacer is
2. While holding **⌘**, drag any menu bar icon to the **right** of the blue bar to keep it always visible
3. Drag icons to the **left** of the blue bar to include them in the collapsible group
4. Release **⌘** — the blue bar disappears

### Repositioning the spacer

You can also move the spacer itself. Hold **⌘** and drag the glowing blue bar left or right to change where the hidden/visible boundary sits.

## Day-to-Day Use

| Action | Result |
|---|---|
| Left-click chevron | Toggle collapse/expand |
| Right-click chevron | Open settings menu |
| Hold ⌘ | Reveal the spacer position (blue bar) |
| ⌘+drag an icon | Move it between hidden/visible zones |

## Settings Menu

Right-click the chevron to access:

- **Start at Login** — launch MenuTidy automatically when you log in
- **Quit MenuTidy** — exit the app (all hidden icons will reappear)

## Behaviour on Restart

- MenuTidy remembers its position and the spacer position across restarts
- Other apps' icon positions are also preserved by macOS
- On subsequent launches, MenuTidy automatically collapses after a short delay to let all icons load into their saved positions first

## Building from Source

MenuTidy is a single-file Swift app with no dependencies beyond macOS system frameworks. No Xcode project is required.

```bash
cd ~/Desktop/MenuTidy
./build.sh
open MenuTidy.app
```

The build script compiles `main.swift` with `swiftc`, links against Cocoa and ServiceManagement, and assembles the `.app` bundle.

## Troubleshooting

### The chevron disappeared

If you accidentally move the chevron to the left of the spacer and collapse, MenuTidy will detect this and automatically expand to recover. If the chevron is still missing, quit MenuTidy from Activity Monitor and relaunch — it will start expanded.

To fully reset MenuTidy's saved positions:

```bash
defaults delete com.local.MenuTidy
```

Then relaunch the app.

### Icons aren't hiding

Make sure the icons you want hidden are to the **left** of the spacer (the glowing blue bar that appears when you hold ⌘). Icons to the right of the spacer are excluded from hiding.

### The spacer isn't visible

The spacer is only visible when you hold the **⌘** key. In normal use it's completely invisible.

---

MenuTidy is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
