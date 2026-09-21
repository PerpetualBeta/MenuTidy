# MenuTidy

> ## macOS 27 works differently
>
> **It works again, but by a different route.** macOS 27 draws the whole menu bar
> as a single window. MenuTidy used to hide icons with an invisible spacer that
> pushed its neighbours off the edge, and there are no longer any neighbouring
> windows to push, so that technique cannot work on 27 and never will again.
>
> Instead, MenuTidy now asks macOS to do the hiding. It tells the system which
> icons should stay and the system hides the rest and reflows the bar itself.
> Collapsing is instant, no app is restarted, and there is no spacer.
>
> Two things follow from that, both only on macOS 27:
>
> - **Accessibility is required, not optional.** MenuTidy has to work out which
>   icons sit to the left of the chevron, and that is the only way to ask. On
>   macOS 14 to 26 the permission was needed only for Reveal Hidden Icons.
> - **Reveal Hidden Icons is gone, because macOS 27 does it.** The system grew
>   its own control for reaching icons tucked behind the notch, which is what
>   that feature existed for.
> - **Notification Centre works from the clock again**, collapsed or expanded,
>   as of 2.3.0. macOS will not open it while the bar is restricted, so MenuTidy
>   lifts the restriction for a moment, opens it for you, and puts the
>   restriction back. See below.
>
> **On macOS 14 through 26 nothing has changed at all** — same spacer, same
> behaviour, same Reveal Hidden Icons.
>
> Raised as [issue #4](https://github.com/PerpetualBeta/MenuTidy/issues/4) by a
> user on the day macOS 27 shipped, and fixed the same day.

A lightweight macOS menu bar manager that keeps your menu bar clean by collapsing third-party icons out of sight. Click to expand and reveal them when needed.

## Requirements

- macOS 14 (Sonoma) or later
- On macOS 27, Accessibility permission is required — see the notice above

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/MenuTidy/releases/latest/download/MenuTidy.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/MenuTidy/releases/latest)** — unzip and drag `MenuTidy.app` to your Applications folder.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/menutidy
```

After installation, launch MenuTidy — a chevron icon (`»`) appears in your menu bar.

## How It Works

There are two mechanisms, because macOS 27 changed the menu bar.

**On macOS 14 to 26**, MenuTidy adds two elements: a **chevron** (the visible icon you click) and a **spacer** (an invisible divider). When collapsed, the spacer expands to push icons to its left out of view.

```
Expanded:   [hidden icons] | [visible icons] [chevron] [system icons]
Collapsed:                   [visible icons] [chevron] [system icons]
```

**On macOS 27**, the whole menu bar is a single window, so there is nothing for a spacer to push. There is no spacer at all. MenuTidy instead tells macOS which icons should stay and the system hides the rest and reflows the bar itself. The **chevron is the boundary**: everything to its left is hidden, everything to its right stays.

An icon wide enough to straddle the chevron is kept. Hiding it would leave its rectangle sitting on top of the chevron, and macOS does not reclaim the space an icon occupied when it stops drawing it, so the chevron would become unclickable. Icons that show text, such as a music player showing the track title, are the ones wide enough for this to matter.

```
Expanded:   [hidden icons] [chevron] [visible icons] [system icons]
Collapsed:                 [chevron] [visible icons] [system icons]
```

- **Left-click** the chevron to toggle between collapsed and expanded
- **Right-click** the chevron to access the settings menu

## Setting Up

On first launch, MenuTidy starts in the **expanded** state so you can arrange your icons.

> On **macOS 27** there is no spacer, so ignore the `command`-drag instructions below. Drag icons in the menu bar the ordinary way (`command`-drag, as macOS itself allows) and put the ones you want kept to the **right of the chevron**.

### Choosing which icons to hide

All icons to the **left** of the spacer will be hidden when collapsed. All icons to the **right** of the spacer will remain visible at all times.

To move an icon between the hidden and visible zones:

1. Hold `command` (Command) — a glowing blue bar will appear in your menu bar showing where the spacer is
2. While holding `command`, drag any menu bar icon to the **right** of the blue bar to keep it always visible
3. Drag icons to the **left** of the blue bar to include them in the collapsible group
4. Release `command` — the blue bar disappears

### Repositioning the spacer

You can also move the spacer itself. Hold `command` and drag the glowing blue bar left or right to change where the hidden/visible boundary sits.

## Day-to-Day Use

| Action | Result |
|---|---|
| Left-click chevron | Toggle collapse/expand |
| Right-click chevron | Open settings menu |
| Hold `command` | Reveal the spacer position (blue bar) — macOS 14 to 26 only |
| `command`+drag an icon | Move it between hidden/visible zones (on macOS 27, either side of the chevron) |

## Right-click Menu

Right-click the chevron for the standard Jorvik menu:

- **About MenuTidy**
- **Reveal Hidden Icons…** — only on Macs with a notch, and only on macOS 14 to 26 (see below)
- **Check for Updates…** — runs a Sparkle-powered update check
- **Settings…**
- **Quit MenuTidy** — exit the app (all hidden icons reappear)

## Notification Centre (macOS 27)

**It works.** Click the clock, collapsed or expanded, and Notification Centre opens as usual. Before 2.3.0 the click did nothing while collapsed.

It is worth knowing what happens, because you will see it. While the bar is collapsed macOS is holding it under a restriction, and it refuses to open Notification Centre while one is active. There is no setting for that: the facility macOS 27 uses to hide menu bar items was built for exam lockdown, and withholding notifications is one of the things it is *for*. Asking the clock to press itself is refused in exactly the same silent way as a mouse click.

So MenuTidy does the one thing that does work. It drops the restriction, opens Notification Centre for you, and puts the restriction straight back. The bar is unrestricted for roughly two to four tenths of a second, and **your hidden icons are genuinely drawn again for that moment**, because for that moment the bar genuinely is not restricted. You will see a brief flicker. That is the whole cost.

If you would rather have the old behaviour, where the click simply does nothing:

```
defaults write cc.jorviksoftware.MenuTidy relayClockClick -bool NO
```

A two-finger swipe in from the right edge of the trackpad opens Notification Centre too, restriction or no restriction, and always did.

Other menu bar managers on macOS 27 meet the same wall, for the same reason.

## When the menu bar is too full (macOS 27)

macOS 27 drops menu bar icons of its own accord once the bar runs out of room, and it will drop icons MenuTidy has asked it to keep. Telling macOS an icon *may* be shown does not reserve space for it.

A dropped icon also **keeps its rectangle**. It stops being drawn, but the space it occupied stays claimed, so part of the menu bar becomes a dead region where clicks reach nothing at all. If that region lands on MenuTidy's chevron, the chevron stops responding and looks broken. It is not broken; there is simply nothing there to click.

None of that is something MenuTidy can fix, and all of it looks exactly like MenuTidy misbehaving. So from 2.3.0 it tells you. A small panel drops from the notch, once per run, when either:

- macOS has added **its own** chevron to the menu bar, which it does only while it is actually hiding icons, or
- your status icons need 80% or more of the screen's width.

The first is the signal worth trusting, because it is a fact rather than a forecast. On the Mac this was developed on it fired at 67% full while macOS was already dropping icons — the percentage on its own would have said nothing.

The remedy is to put less in the menu bar: quit an app you are not using, or remove a system icon in Control Centre settings.

The width threshold is adjustable. The other trigger is not: if macOS is actively hiding your icons, that is worth knowing about.

```
defaults write cc.jorviksoftware.MenuTidy menuBarFullThreshold -float 0.9
```

The panel hangs from the notch and is sized to clear the physical cutout, which no API describes. If its edges look wrong on your Mac:

```
defaults write cc.jorviksoftware.MenuTidy notchClearance -float 8
```

Default is 6.

## Reveal Hidden Icons (notched Macs, macOS 14 to 26)

> **Not present on macOS 27.** The system grew its own control for reaching icons tucked behind the notch, so MenuTidy no longer offers a second answer to the same question. Everything in this section applies to macOS 14 through 26.

On 14"/16" MacBook Pros and notched MacBook Airs, the menu bar wraps around the notch — and when you have more status icons than fit in the right-hand segment, the leftmost ones get clipped behind the notch with no way to click them.

MenuTidy's **Reveal Hidden Icons…** menu item drops a panel listing every status icon currently hidden behind the notch. **Left-click** an entry to activate that icon's primary action (or open its menu, if it's a menu-style item); **right-click** to send a right-click instead, for icons that distinguish the two.

Each time you open the panel it scans the menu bar fresh — a brief spinner shows while it works, then the complete list appears, so you always know you're looking at the final result. Clicking **Reveal Hidden Icons** again closes the panel; it also closes if you collapse the menu bar.

The menu item only appears on notched displays. The first time you use it MenuTidy will ask for Accessibility permission so it can enumerate other apps' status items; you can also grant it ahead of time from **Settings → Permissions**.

#### Where the notch actually ends

macOS reports the notch's right edge through `auxiliaryTopRightArea`, but it does not start drawing status items there — there is a dead band of roughly 14 to 30 points beyond it where an item is laid out, reports a perfectly ordinary position, and is never rendered. Nothing in AppKit describes that band, and a probe status item doesn't find it either (it measures the leftmost *available slot* for the current arrangement, which is a different thing).

An icon parked in that band used to be reported as visible while being nowhere on screen, so it was left out of the very panel meant to reveal it. MenuTidy now allows for it. If your Mac's band differs, the clearance is a knob:

```
defaults write cc.jorviksoftware.MenuTidy notchDrawInset -float 24
```

Default is 22. **Err low if you change it** — too small only reverts to missing the odd icon from the list, while too large starts hiding icons that are plainly on screen.

### Settings…

- **Auto-collapse** — automatically collapse the bar a few seconds after the pointer leaves it (0–999 seconds; 0 = immediately). Off by default; see below
- **Permissions → Accessibility** — on macOS 14 to 26, required only for **Reveal Hidden Icons**. **On macOS 27 it is required for collapsing to work at all**, because MenuTidy has to work out which icons sit left of the chevron. The row says which applies, and shows live status with a Grant Access button
- **Menu bar icon pill** — optional grey background for stronger contrast on busy or wallpaper-tinted menu bars (off by default)
- **General → Launch at Login** — start MenuTidy automatically when you log in

Auto-updates are handled by Sparkle. Use the **Check for Updates…** menu item to check on demand; Sparkle's prompt offers an "Automatically download and install updates in the future" checkbox the first time an update is available.

## Behaviour on Restart

- MenuTidy remembers where you've placed the chevron, and the spacer on macOS 14 to 26, across restarts — your drag-arrangement persists
- Other apps' icon positions are preserved by macOS in their own preferences, so the layout you build once stays put
- On subsequent launches, MenuTidy automatically collapses after a short delay to let all icons load into their saved positions first

## Auto-collapse

By default the bar stays in whatever state you left it — expand to peek at your icons, and it waits for you to click again to tidy. If you'd rather it re-tidy itself, turn on **Auto-collapse** in Settings (right-click the chevron → **Settings…**):

- **Automatically collapse the menu bar** — the on/off switch (off by default).
- **Collapse after … seconds** — how long to wait after the pointer leaves the menu bar before tidying, from 0 to 999. Set it to **0** to collapse the moment you move away.

The countdown starts when the pointer leaves the menu bar and is cancelled if you move back up to it before it elapses — so the bar only tidies once you've genuinely moved away.

## Building from Source

MenuTidy is a single-file Swift app with no dependencies beyond macOS system frameworks. No Xcode project is required.

The build is driven by the shared [`release.mk`](https://github.com/PerpetualBeta/jorvik-release) Make include, so `jorvik-release` has to be checked out **beside this repo** — the Makefile looks for it at `../jorvik-release/`. macOS ships GNU Make 3.81 as `make`, which is too old, so `gmake` comes from [Homebrew](https://brew.sh).

```bash
brew install make   # GNU Make 4+, if you do not already have gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git
git clone https://github.com/PerpetualBeta/MenuTidy.git
cd MenuTidy
gmake build
open.build/MenuTidy.app
```

## Troubleshooting

### The chevron disappeared

If you accidentally move the chevron to the left of the spacer and collapse, MenuTidy will detect this and automatically expand to recover. If the chevron is still missing, quit MenuTidy from Activity Monitor and relaunch — it will start expanded.

To fully reset MenuTidy's saved positions:

```bash
defaults delete cc.jorviksoftware.MenuTidy
```

Then relaunch the app.

### Icons aren't hiding

On **macOS 14 to 26**, make sure the icons you want hidden are to the **left** of the spacer (the glowing blue bar that appears when you hold `command`). Icons to the right of the spacer are excluded from hiding.

On **macOS 27**, check two things. Icons you want hidden must be to the **left of the chevron**. And Accessibility must be granted — without it MenuTidy cannot tell which icons to keep, so it refuses to collapse rather than risk hiding everything. Clicking the chevron will say so and offer to open the right settings pane.

### An icon disappeared that should have stayed (macOS 27)

Icons to the **right** of the chevron are meant to stay visible when the bar
collapses. If one of them vanishes instead, there are two known causes and the
log will tell you which.

Turn the log on, collapse the bar once, then read
`~/Library/Logs/MenuTidy/menutidy.log`:

```bash
defaults write cc.jorviksoftware.MenuTidy debugLogging -bool YES
```

It takes effect immediately, with no relaunch.

Each collapse writes out the layout it decided from: every icon, where it starts
and ends, and whether it was kept or hidden. Two lines are worth looking for.

`allow-list: N app(s) are not installed directly in /Applications` names an app
macOS 27 cannot match. The system works out an icon's owner from where the app
lives, and for an app launched from anywhere other than `/Applications` it
reports no owner at all, so no allow-list can keep it and the icon is taken down
whichever side of the chevron it sits on. This is not something MenuTidy can fix.
The workaround is to install the app in `/Applications`, or to symlink its
location to a copy there.

`collapse check: N allow-listed app(s) left the bar anyway` names an app that was
asked for and went regardless. That usually means the bar is too full and macOS
is dropping icons of its own accord, which it does even to icons an app has
asked it to keep.

Turn the log off again with:

```bash
defaults write cc.jorviksoftware.MenuTidy debugLogging -bool NO
```

### The spacer isn't visible

The spacer is only visible when you hold the `command` key. In normal use it's completely invisible.

There is no spacer at all on **macOS 27** — the chevron is the boundary instead.

---

MenuTidy is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
