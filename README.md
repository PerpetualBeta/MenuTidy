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

## Right-click Menu

Right-click the chevron for the standard Jorvik menu:

- **About MenuTidy**
- **Reveal Hidden Icons…** — only shown on Macs with a notch (see below)
- **Check for Updates…** — runs a Sparkle-powered update check
- **Settings…**
- **Quit MenuTidy** — exit the app (all hidden icons reappear)

## Reveal Hidden Icons (notched Macs)

On 14"/16" MacBook Pros and notched MacBook Airs, the menu bar wraps around the notch — and when you have more status icons than fit in the right-hand segment, the leftmost ones get clipped behind the notch with no way to click them.

MenuTidy's **Reveal Hidden Icons…** menu item drops a panel listing every status icon currently hidden behind the notch. **Left-click** an entry to activate that icon's primary action (or open its menu, if it's a menu-style item); **right-click** to send a right-click instead, for icons that distinguish the two.

Each time you open the panel it scans the menu bar fresh — a brief spinner shows while it works, then the complete list appears, so you always know you're looking at the final result. Clicking **Reveal Hidden Icons** again closes the panel; it also closes if you collapse the menu bar.

The menu item only appears on notched displays. The first time you use it MenuTidy will ask for Accessibility permission so it can enumerate other apps' status items; you can also grant it ahead of time from **Settings → Permissions**.

### Settings…

- **Auto-collapse** — automatically collapse the bar a few seconds after the pointer leaves it (0–999 seconds; 0 = immediately). Off by default; see below
- **Permissions → Accessibility** — required for **Reveal Hidden Icons**; shows live status with a Grant Access button if not yet granted
- **Menu bar icon pill** — optional grey background for stronger contrast on busy or wallpaper-tinted menu bars (off by default)
- **General → Launch at Login** — start MenuTidy automatically when you log in

Auto-updates are handled by Sparkle. Use the **Check for Updates…** menu item to check on demand; Sparkle's prompt offers an "Automatically download and install updates in the future" checkbox the first time an update is available.

## Behaviour on Restart

- MenuTidy remembers where you've placed the chevron and the spacer across restarts — your drag-arrangement of either persists
- Other apps' icon positions are preserved by macOS in their own preferences, so the layout you build once stays put
- On subsequent launches, MenuTidy automatically collapses after a short delay to let all icons load into their saved positions first

## Auto-collapse

By default the bar stays in whatever state you left it — expand to peek at your icons, and it waits for you to click again to tidy. If you'd rather it re-tidy itself, turn on **Auto-collapse** in Settings (right-click the chevron → **Settings…**):

- **Automatically collapse the menu bar** — the on/off switch (off by default).
- **Collapse after … seconds** — how long to wait after the pointer leaves the menu bar before tidying, from 0 to 999. Set it to **0** to collapse the moment you move away.

The countdown starts when the pointer leaves the menu bar and is cancelled if you move back up to it before it elapses — so the bar only tidies once you've genuinely moved away.

## Building from Source

MenuTidy is a single-file Swift app with no dependencies beyond macOS system frameworks. No Xcode project is required.

```bash
cd ~/Desktop/Jorvik\ Software/MenuTidy
gmake build
open .build/MenuTidy.app
```

Requires GNU Make 4.x — `brew install make` installs it as `gmake`. The target is defined in the shared `release.mk` from `jorvik-release/`.

## Troubleshooting

### The chevron disappeared

If you accidentally move the chevron to the left of the spacer and collapse, MenuTidy will detect this and automatically expand to recover. If the chevron is still missing, quit MenuTidy from Activity Monitor and relaunch — it will start expanded.

To fully reset MenuTidy's saved positions:

```bash
defaults delete cc.jorviksoftware.MenuTidy
```

Then relaunch the app.

### Icons aren't hiding

Make sure the icons you want hidden are to the **left** of the spacer (the glowing blue bar that appears when you hold ⌘). Icons to the right of the spacer are excluded from hiding.

### The spacer isn't visible

The spacer is only visible when you hold the **⌘** key. In normal use it's completely invisible.

---

MenuTidy is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
