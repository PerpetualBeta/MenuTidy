import Cocoa
import Combine
import ServiceManagement
import SwiftUI
import ApplicationServices
import Sparkle

// MARK: - Debug logging
//
// Off by default. Enable per-machine with:
//   defaults write cc.jorviksoftware.MenuTidy debugLogging -bool YES
// Lines append to ~/Library/Logs/MenuTidy/menutidy.log. Never to stderr/Console,
// never to /tmp. Used to dump hidden-icon AX geometry when diagnosing reveal
// counts; the flag-read is cached once so the hot detection loop stays cheap.
enum MTDebug {
    /// Read on every call, not cached at launch, so `defaults write ...
    /// debugLogging -bool YES` takes effect without a relaunch. That is what
    /// every other logging app in the estate does (see `Ballast/Sources/Log.swift`),
    /// and there is no hot path here to protect: the busiest log site sits
    /// inside `evaluateAutoCollapse`, behind branches that only fire on a state
    /// change, which a full day of use showed firing 165 times rather than once
    /// per pointer move. `log()` takes its message as an `@autoclosure`, so a
    /// disabled call still builds no string.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugLogging") }

    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MenuTidy", isDirectory: true)
    private static let url = directory.appendingPathComponent("menutidy.log")
    /// The one generation kept behind the live log.
    private static let previousURL = directory.appendingPathComponent("menutidy.log.1")

    /// Rotate once the live log passes this many bytes, keeping one previous
    /// generation, so the most this can ever occupy is twice this figure.
    ///
    /// 4 MB by default. A night of the heaviest instrumenting this app has ever
    /// had, on 2026-09-19, produced 10 MB in about seven hours, so 4 MB holds a
    /// few hours of the noisiest possible use and the previous generation keeps
    /// the run before it. Ordinary use with logging on is a small fraction of
    /// that. It is a knob because a long debugging session may want more:
    ///
    ///     defaults write cc.jorviksoftware.MenuTidy debugLogMaxBytes -int 20971520
    private static var maximumBytes: Int {
        let stored = UserDefaults.standard.integer(forKey: "debugLogMaxBytes")
        return stored > 0 ? stored : 4 * 1024 * 1024
    }

    private static let lock = NSLock()
    private static var handle: FileHandle?
    /// Which file on disk the handle is actually attached to.
    ///
    /// A file handle follows the **inode**, not the path. When one process
    /// rotates the log, every other process carries on writing into the file
    /// that was just renamed out of the way, silently, for the rest of its
    /// life. Two processes write to this log: the app and the holder it spawns.
    /// So before every write the path is checked against what the handle holds,
    /// and a mismatch means somebody rotated underneath us and it is time to
    /// reopen.
    private static var inode: ino_t = 0

    /// Every line is stamped with the time.
    ///
    /// Added 2026-09-20 after a night spent unable to tell an app that had
    /// stopped reacting from a user who had stopped clicking: the log showed no
    /// new lines in both cases, and without a clock there was no way to know
    /// which. A wrong conclusion was drawn from exactly that ambiguity.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = stamp.string(from: Date()) + "  " + message() + "\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        attachToTheLiveLog()
        guard let handle else { return }
        handle.write(data)
        rotateIfTooBig()
    }

    // MARK: - Private

    /// Make `handle` refer to the file currently at `url`, opening or reopening
    /// as required. Cheap: one `stat` when nothing has changed, which is the
    /// usual case.
    ///
    /// Opened `O_APPEND` rather than with `FileHandle(forWritingTo:)` + seek.
    /// Each handle carries its OWN offset, so with a plain seek-to-end two
    /// processes both write at the position the file had when they started and
    /// clobber each other. Measured 2026-09-20: of four holder start-ups only
    /// one left a line, and truncating the file while the app held it open
    /// padded the gap with NUL bytes. `O_APPEND` makes the kernel place every
    /// write at the true end at the moment of the write, whoever makes it.
    private static func attachToTheLiveLog() {
        var onDisk = stat()
        let exists = stat(url.path, &onDisk) == 0
        if handle != nil, exists, onDisk.st_ino == inode { return }

        handle = nil        // closeOnDealloc closes the old descriptor
        inode = 0
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        var opened = stat()
        inode = fstat(descriptor, &opened) == 0 ? opened.st_ino : 0
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Move the live log aside once it is too big and start a fresh one.
    ///
    /// The size is read from the descriptor rather than the path, so it is the
    /// file being written to that is measured even if the path has since been
    /// replaced.
    ///
    /// If both processes decide to rotate at the same instant, one rename wins
    /// and the other finds nothing to move; the cost is a single lost
    /// generation of a log that is off by default. A lock file to close that
    /// window would be more machinery than the problem deserves, and the holder
    /// writes about three lines in its whole life.
    private static func rotateIfTooBig() {
        guard let handle else { return }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              info.st_size >= maximumBytes else { return }

        self.handle = nil
        inode = 0
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: url, to: previousURL)
        attachToTheLiveLog()

        // Written straight to the handle: going through log() would take the
        // lock this method is already holding.
        let note = stamp.string(from: Date())
            + "  log rotated at \(info.st_size) bytes — the run before this is in menutidy.log.1\n"
        if let data = note.data(using: .utf8) { self.handle?.write(data) }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var chevronItem: NSStatusItem!
    /// The invisible spacer that does the hiding on macOS 14-26. Not created
    /// at all on macOS 27, where the bar is one window and an over-wide item
    /// pushes nothing — it would just be a second, useless MenuTidy entry in
    /// the user's menu bar. Optional rather than implicitly unwrapped so its
    /// absence is a fact the code has to handle, not a crash.
    var spacerItem: NSStatusItem?
    var cmdMonitor: Any?
    var mouseMonitor: Any?
    /// Watches for clicks aimed at the chevron that this app never receives.
    var buriedChevronMonitor: Any?
    /// Instrument state for `watchTheChevronPosition`. Main thread only.
    var chevronWatchTimer: Timer?
    var lastWatchedChevronX: CGFloat?
    /// When `statusItemClicked` last ran. The recovery compares against this to
    /// tell a click that genuinely went missing from one it simply also saw.
    private var lastHandledClick = Date.distantPast
    /// True while this app's own menu is on screen.
    ///
    /// The click that dismisses a menu is swallowed by the menu, so the status
    /// item's action never runs for it. If that click happens to land on the
    /// chevron — and it usually does, because that is what the user just
    /// right-clicked — the recovery below would see an unhandled click on the
    /// chevron and wrongly conclude it was buried. Measured 2026-09-20: every
    /// menu dismissal expanded the bar, and since a recovery deliberately does
    /// not re-arm auto-collapse, it switched auto-collapse off as well.
    private var menuIsOpen = false
    /// Said once per run. See `warnIfTheBarIsTooFull()`.
    private var hasSaidTheBarIsFull = false
    var spacerVisible = false
    var revealPanel: HiddenIconsPanel?
    /// Accessibility state, kept current by JorvikKit.
    ///
    /// NOT a raw `AXIsProcessTrusted()` poll. That call is cached in-process and
    /// the system announcement invalidates the cache, so **the first read after
    /// an announcement is the one that refetches — and a read taken too soon
    /// refetches the OLD answer and pins it there.** Reading more often makes it
    /// strictly worse. `JorvikPermissionWatcher` exists precisely because of
    /// that; read its notes before changing this.
    private let accessibility = JorvikPermissionWatcher.accessibility()
    private var accessibilityCancellable: AnyCancellable?
    // Captured when the right-click menu is built: opening that menu dismisses
    // the panel (resignKey) before the menu item fires, so we can't ask the live
    // panel whether it was open — we decide the toggle from this snapshot.
    var revealPanelWasOpenAtMenuInvoke = false

    // Auto-collapse. When on, the bar tidies itself a short delay after the
    // pointer leaves the menu-bar vicinity. A first-class setting (Settings →
    // Auto-Collapse) backed by the `autoCollapse` / `autoCollapseDelay`
    // UserDefaults keys, cached into these ivars so the pointer-tracking hot
    // path stays lookup-free; re-read live via autoCollapseSettingsChanged().
    var autoCollapseMouseMonitor: Any?
    var autoCollapsePending: DispatchWorkItem?
    private var autoCollapseEnabled = false
    private var autoCollapseDelay: TimeInterval = 2   // seconds; 0 = collapse immediately
    private static let maxAutoCollapseDelay: TimeInterval = 999

    var isCollapsed = false
    private let hasLaunchedBeforeKey = "MenuTidy_HasLaunchedBefore"
    private let didSeedDefaultPositionsKey = "MenuTidy_DidSeedDefaultPositions"

    let userDriverDelegate = MenuTidyUserDriverDelegate()
    lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: userDriverDelegate
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyPillColorKey()

        // Auto-collapse config — a first-class setting (Settings → Auto-Collapse),
        // off by default. Cached here; re-read live when the user changes it.
        reloadAutoCollapseConfig()

        setupStatusItems()
        setupCmdKeyMonitor()
        watchForBuriedChevron()
        watchTheChevronPosition()

        // Pre-warm the hidden-icons cache so opening the reveal panel is
        // instant. Only meaningful on notched displays — gated to avoid
        // pointless AX work elsewhere.
        // Pointless on macOS 27, where the reveal panel is never offered: this
        // cache exists only to make that panel open instantly, and filling it
        // means background Accessibility work for a feature that cannot run.
        if HiddenIcons.notchHorizontalRange() != nil && !MenuBarRestriction.isAvailable {
            HiddenIcons.startCaching()
        }

        // First inventory for the macOS 27 collapse path, in the background.
        // Deliberately outside the notch gate above: the hidden-icons cache is
        // only useful on a notched display, but collapsing is not.
        MenuBarInventory.refresh { [weak self] in self?.warnIfTheBarIsTooFull() }
        // Take an inventory whenever the permission arrives, so granting it never
        // requires a restart. The watcher handles the announcement and the stale
        // read that follows it; this only reacts to the settled answer.
        if MenuBarRestriction.isAvailable {
            accessibilityCancellable = accessibility.$isGranted
                .removeDuplicates()
                .sink { granted in
                    MTDebug.log("accessibility now \(granted ? "granted" : "not granted")")
                    if granted { MenuBarInventory.refresh() }
                }
        }

        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: hasLaunchedBeforeKey)
        if hasLaunchedBefore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.collapse()
            }
        } else {
            UserDefaults.standard.set(true, forKey: hasLaunchedBeforeKey)
        }

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink (e.g. moving from a notched
        // display to an external one) and leave the pre-rendered pill cropped.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }
    }

    // One-shot removal of the user-chosen pill colour key from the old design.
    // The new pill uses fixed grey/light colours; the key is dead weight.
    private func migrateLegacyPillColorKey() {
        let migrated = "didMigratePillColorV2"
        if UserDefaults.standard.bool(forKey: migrated) { return }
        UserDefaults.standard.removeObject(forKey: "menuBarPillColor")
        UserDefaults.standard.set(true, forKey: migrated)
    }

    func applicationWillTerminate(_ notification: Notification) {
        expand(startTracking: false)
    }

    // MARK: Status Items

    func setupStatusItems() {
        // Seed initial positions only on the very first launch — after that, defer
        // entirely to macOS's autosave so the user's drag-arrangement persists.
        // Older builds set these unconditionally on every launch, which silently
        // wiped any spacer/chevron repositioning across restarts.
        if !UserDefaults.standard.bool(forKey: didSeedDefaultPositionsKey) {
            // Preferred positions: lower number = further right.
            // Chevron at 150 = near system items (rightmost of our items)
            // Spacer at 300 = among third-party items (further left)
            UserDefaults.standard.set(150, forKey: "NSStatusItem Preferred Position MenuTidyChevron")
            UserDefaults.standard.set(300, forKey: "NSStatusItem Preferred Position MenuTidySpacer")
            UserDefaults.standard.set(true, forKey: didSeedDefaultPositionsKey)
        }

        // Create chevron first (rightmost)
        chevronItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevronItem.autosaveName = "MenuTidyChevron"
        if let button = chevronItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateIcon()
        }

        // Create spacer second (to the left, among third-party items). Skipped
        // entirely on macOS 27: there the restriction does the hiding, and a
        // spacer would only clutter the bar with a second MenuTidy item.
        if !MenuBarRestriction.isAvailable {
            let spacer = NSStatusBar.system.statusItem(withLength: 0)
            spacer.autosaveName = "MenuTidySpacer"
            spacerItem = spacer
        }
    }

    // MARK: ⌘ Key Monitor

    func setupCmdKeyMonitor() {
        // No spacer on macOS 27 means nothing to reveal, so no global monitor.
        guard !MenuBarRestriction.isAvailable else { return }
        cmdMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            if event.modifierFlags.contains(.command) {
                self.beginPointerTracking()
            } else {
                self.endPointerTracking()
            }
        }
    }

    // The highlight is a wayfinding aid for someone arranging their menu bar,
    // so it should only appear when the pointer is actually up there. ⌘ alone
    // isn't enough — it's pressed constantly for ordinary shortcuts. While the
    // key is held we follow the cursor and reveal the spacer only when it
    // enters the menu-bar band; releasing ⌘ tears the tracking back down.
    func beginPointerTracking() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.updateSpacerForPointer()
            }
        }
        updateSpacerForPointer()
    }

    func endPointerTracking() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        hideSpacer()
    }

    func updateSpacerForPointer() {
        if pointerInMenuBar() {
            showSpacer()
        } else {
            hideSpacer()
        }
    }

    /// True when the cursor sits within the menu-bar band at the top of
    /// whichever screen it's currently on. Thickness is queried live so a
    /// notched built-in display and a shorter external bar both read correctly.
    private func pointerInMenuBar() -> Bool {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) else {
            return false
        }
        return loc.y >= screen.frame.maxY - NSStatusBar.system.thickness
    }

    func showSpacer() {
        guard !isCollapsed, !spacerVisible, let spacerItem else { return }
        spacerVisible = true
        spacerItem.length = 10
        if let button = spacerItem.button {
            button.title = ""
            button.image = nil
            // Draw a glowing vertical bar
            let w: CGFloat = 14
            let h: CGFloat = 22
            let img = NSImage(size: NSSize(width: w, height: h))
            img.lockFocus()
            let barW: CGFloat = 3
            let barH: CGFloat = 16
            let barX = (w - barW) / 2
            let barY = (h - barH) / 2
            let barRect = NSRect(x: barX, y: barY, width: barW, height: barH)
            // Outer glow
            let glowColor = NSColor.systemBlue.withAlphaComponent(0.4)
            let glowRect = barRect.insetBy(dx: -3, dy: -2)
            glowColor.setFill()
            NSBezierPath(roundedRect: glowRect, xRadius: 3, yRadius: 3).fill()
            // Inner glow
            NSColor.systemBlue.withAlphaComponent(0.7).setFill()
            let innerGlow = barRect.insetBy(dx: -1.5, dy: -1)
            NSBezierPath(roundedRect: innerGlow, xRadius: 2, yRadius: 2).fill()
            // Bright core
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
            // White hot centre
            let centreRect = barRect.insetBy(dx: 0.5, dy: 1)
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: centreRect, xRadius: 1, yRadius: 1).fill()
            img.unlockFocus()
            button.image = img
        }
    }

    func hideSpacer() {
        spacerVisible = false
        guard !isCollapsed, let spacerItem else { return }
        spacerItem.length = 0
        spacerItem.button?.image = nil
    }

    func updateIcon() {
        guard let button = chevronItem.button else { return }
        let symbolName = isCollapsed ? "chevron.left.2" : "chevron.right.2"
        button.image = JorvikMenuBarPill.icon(
            symbolName: symbolName,
            accessibilityDescription: "MenuTidy"
        )
    }

    // MARK: Click Handling

    @objc func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            MTDebug.log("click: handler fired but NSApp.currentEvent was nil — ignoring")
            return
        }
        lastHandledClick = Date()
        MTDebug.log("click: type=\(event.type.rawValue) collapsed=\(isCollapsed)")
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        MTDebug.log("toggle: collapsed=\(isCollapsed) -> \(isCollapsed ? "expand" : "collapse")")
        if isCollapsed { expand() } else { collapse() }
    }

    // MARK: Auto-collapse (opt-in)
    //
    // Only active when `autoCollapse` is set. Tracking is installed while the
    // bar is expanded and torn down when it collapses, so there's zero hot-path
    // cost when the bar is already tidy or the feature is off. "Vicinity" is the
    // menu-bar band itself (the same predicate the ⌘ spacer-reveal uses); the
    // couple-second delay is the grace window, so a brief dip below the bar
    // doesn't tidy prematurely.
    //
    // Known limitation: navigating a tall drop-down opened from a hidden-group
    // icon for longer than the delay can trigger a collapse mid-menu, since the
    // pointer is below the band the whole time. Rare in practice, and the
    // affected item reappears on the next expand.

    /// Read the auto-collapse setting into the cached ivars. `autoCollapse`
    /// absent → off; `autoCollapseDelay` absent → 2 s, otherwise clamped to
    /// 0…999 (0 = collapse the moment the pointer leaves). Read-only — safe to
    /// call before the status items exist (e.g. at launch).
    func reloadAutoCollapseConfig() {
        let d = UserDefaults.standard
        autoCollapseEnabled = d.bool(forKey: "autoCollapse")
        let secs = d.object(forKey: "autoCollapseDelay") == nil ? 2.0 : d.double(forKey: "autoCollapseDelay")
        autoCollapseDelay = min(Self.maxAutoCollapseDelay, max(0, secs))
    }

    /// Called when the user changes the setting in Settings: re-read and apply
    /// immediately, no relaunch. Start tracking if it's now on and the bar is
    /// expanded; tear it down if it's now off.
    func autoCollapseSettingsChanged() {
        reloadAutoCollapseConfig()
        if autoCollapseEnabled {
            if !isCollapsed { startAutoCollapseTracking() }
        } else {
            stopAutoCollapseTracking()
        }
    }

    /// Begin watching the pointer so we can auto-collapse once it leaves the
    /// menu-bar vicinity. Called whenever the bar expands. Idempotent, and a
    /// no-op unless the feature is enabled.
    func startAutoCollapseTracking() {
        guard autoCollapseEnabled, autoCollapseMouseMonitor == nil else { return }
        MTDebug.log("auto-collapse: tracking started (delay=\(autoCollapseDelay)s)")
        autoCollapseMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.evaluateAutoCollapse()
        }
        // The pointer may already be away from the bar at expand time (the user
        // clicked the chevron and the cursor is drifting off), so evaluate once
        // now rather than waiting for the next move event.
        evaluateAutoCollapse()
    }

    func stopAutoCollapseTracking() {
        if let autoCollapseMouseMonitor {
            NSEvent.removeMonitor(autoCollapseMouseMonitor)
            self.autoCollapseMouseMonitor = nil
        }
        autoCollapsePending?.cancel()
        autoCollapsePending = nil
    }

    /// True while the Reveal Hidden Icons panel is on screen. Auto-collapse must
    /// stand down then: collapsing reflows the menu bar under the open panel and
    /// moves the very icon the user is reaching for out from under the cursor.
    private var revealPanelOpen: Bool { revealPanel?.isVisible == true }

    /// Arm the collapse countdown while the pointer is outside the vicinity;
    /// cancel it the moment it returns. Armed only once on leaving (guarded by
    /// `autoCollapsePending == nil`) so continued movement outside the band
    /// doesn't keep resetting it — the collapse fires a fixed delay after the
    /// pointer *first* left.
    private func evaluateAutoCollapse() {
        guard autoCollapseEnabled, !isCollapsed else { return }
        // Hold the countdown while the pointer is at the bar OR the Reveal panel
        // is open — either means "don't tidy yet".
        if pointerInMenuBar() || revealPanelOpen {
            if autoCollapsePending != nil {
                MTDebug.log("auto-collapse: countdown cancelled (pointer at bar or reveal open)")
            }
            autoCollapsePending?.cancel()
            autoCollapsePending = nil
        } else if autoCollapsePending == nil {
            MTDebug.log("auto-collapse: countdown armed")
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.autoCollapsePending = nil
                // Re-check at fire time: the pointer may have returned to the
                // bar (without a move event the monitor observed), or the Reveal
                // panel may have opened, since the countdown was armed.
                guard self.autoCollapseEnabled, !self.isCollapsed,
                      !self.pointerInMenuBar(), !self.revealPanelOpen else { return }
                MTDebug.log("auto-collapse: firing collapse")
                self.collapse(userInitiated: false)
            }
            autoCollapsePending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoCollapseDelay, execute: work)
        }
    }

    // MARK: Collapse / Expand

    /// Ask for Accessibility, which macOS 27 collapsing cannot work without.
    ///
    /// Two steps, because one is not enough. `promptForAccessibility` shows the
    /// system dialog, but macOS shows that only once per app — a user who
    /// dismissed it, or whose grant was reset, sees nothing at all. So if the
    /// permission still is not there, explain and offer to open the pane
    /// directly, which is the only route back.
    private func requestAccessibilityForCollapse() {
        // Deliberately does NOT also call promptForAccessibility(). That shows
        // the system dialog, which macOS displays only once per app — so on a
        // first run the user got two dialogs stacked on each other, and on every
        // run after that the system one silently did nothing. One dialog that
        // always appears and always offers a route is better than two that
        // sometimes do.
        let alert = NSAlert()
        alert.messageText = "MenuTidy needs Accessibility to collapse the menu bar"
        alert.informativeText = """
            On macOS 27 the system hides the icons for MenuTidy, and MenuTidy has \
            to tell it which ones to keep. Working that out needs Accessibility.

            Without it, clicking the chevron cannot do anything.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            JorvikPermissionWatcher.openSettings(pane: .accessibility)
        }
    }

    /// Collapse by restricting the menu bar (macOS 27 and later).
    ///
    /// Everything from the chevron rightwards stays; everything left of it is
    /// hidden. MenuTidy always keeps itself, because the chevron is the only way
    /// back — hiding it would leave the user with no way to expand.
    private func applyMenuBarRestriction(userInitiated: Bool) {
        // Without Accessibility the inventory is empty, which is indistinguishable
        // from "no other apps have items". Acting on that would hide every icon
        // on the Mac and leave only the chevron. Refuse instead.
        //
        // Refusing quietly is not enough. On macOS 27 this permission is the
        // difference between the app working and the chevron appearing dead, and
        // a silent refusal leaves the user with nothing to act on — no error, no
        // hint, and the only route to Settings is the very menu they are trying
        // to use. So say so, but only when they actually clicked: auto-collapse
        // firing in the background must never throw an alert at anyone.
        guard accessibility.isGranted else {
            MTDebug.log("collapse skipped: Accessibility not granted, cannot tell which icons to keep")
            isCollapsed = false
            if userInitiated { requestAccessibilityForCollapse() }
            return
        }

        guard let chevron = chevronRect() else {
            MTDebug.log("collapse skipped: cannot locate the chevron yet")
            isCollapsed = false
            return
        }

        // Read the cached snapshot. Walking here would freeze the app: one full
        // Accessibility sweep was measured at 29.3 seconds across 192 running
        // apps, which swallowed the next click and opened menus half a minute
        // late. The snapshot is taken in the background while expanded.
        guard MenuBarInventory.hasSnapshot else {
            MTDebug.log("collapse skipped: no inventory yet — refreshing, try again in a moment")
            MenuBarInventory.refresh()
            isCollapsed = false
            return
        }
        let inventory = MenuBarInventory.snapshot
        MTDebug.log("collapse: chevron=\(Int(chevron.x))-\(Int(chevron.x + chevron.width)) from \(inventory.count) cached item(s)")
        var keep = MenuBarInventory.bundleIdentifiers(leftOf: chevron)
        if let ownIdentifier = Bundle.main.bundleIdentifier, !keep.contains(ownIdentifier) {
            keep.append(ownIdentifier)
        }

        if !MenuBarRestriction.restrict(toVisible: keep) {
            MTDebug.log("collapse failed: the menu bar restriction could not be applied")
            isCollapsed = false
            return
        }

        logTheBarAsItWasRead(inventory, chevron: chevron, keep: keep)
        logAllowListedAppsInUnusualLocations(keep)
        verifyTheCollapseKeptWhatItPromised(keep, before: inventory)
    }

    /// How often the chevron watcher reads this app's own icon position.
    private static let chevronWatchInterval: TimeInterval = 1.0

    /// Watch where this app's own icon is actually drawn, and log every move.
    ///
    /// Behind its own knob, because it is an instrument and not a feature:
    ///
    ///     defaults write cc.jorviksoftware.MenuTidy logChevronMoves -bool YES
    ///
    /// **What this replaced, and why.** The first version measured how long
    /// macOS takes to put the bar back after the restriction is released, on
    /// the theory that `expand()` re-walks about 20 ms later and might be
    /// photographing a bar still in its collapsed layout. **That theory is
    /// dead.** Nine expand cycles on 2026-09-21, sixty readings each at 50 ms
    /// intervals: the first reading landed 1 to 4 ms after the release and the
    /// position never changed once, in any cycle. The snapshot agreed with the
    /// live reading and with AppKit's window frame every time. There is no
    /// settling to wait for, so do not add a delay.
    ///
    /// What the numbers pointed at instead: at 16:17:54 the chevron read 1714
    /// having read 2012 three minutes earlier, inside one app session, with
    /// AppKit agreeing at both readings. So this app read the bar correctly and
    /// **the bar had genuinely moved this app's icon 298 points**, about eight
    /// slots, while the user was editing the macOS menu bar visibility list.
    /// That changes which icons fall on which side of the chevron without the
    /// user touching the chevron.
    ///
    /// So the question is no longer "why was the photograph wrong". It is "what
    /// moves this icon". A one-second poll catches that with a timestamp, and
    /// logs only changes, so a quiet day costs one line.
    ///
    /// The read is dispatched off the main thread: asking Accessibility about
    /// our own process needs our own main thread free to answer it.
    private func watchTheChevronPosition() {
        guard MTDebug.enabled,
              UserDefaults.standard.bool(forKey: "logChevronMoves") else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        chevronWatchTimer = Timer.scheduledTimer(withTimeInterval: AppDelegate.chevronWatchInterval,
                                                 repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                guard let x = MenuBarInventory.liveLeftmostItemX(ofProcessIdentifier: pid) else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    defer { self.lastWatchedChevronX = x }
                    guard let previous = self.lastWatchedChevronX else {
                        MTDebug.log(String(format: "chevron watch: starting at x=%.0f", x))
                        return
                    }
                    guard x != previous else { return }
                    MTDebug.log(String(format: "chevron watch: moved %.0f -> %.0f (%+.0f), collapsed=%@",
                                       previous, x, x - previous,
                                       self.isCollapsed ? "true" : "false"))
                }
            }
        }
    }

    /// Dump the layout the collapse decision was actually made from.
    ///
    /// Every wrong collapse so far has been a wrong **input**, not a wrong
    /// rule. The rule is one comparison: keep anything whose right edge is past
    /// the middle of the chevron. What has gone wrong is the chevron position,
    /// or a snapshot missing an app, or a snapshot describing a layout the bar
    /// has already moved on from.
    ///
    /// Until this existed the log recorded the answer and never the question,
    /// so "that icon should have been hidden" could only be argued about. Now
    /// it can be read off: the divider, how old the reading is, and every item
    /// with its edges and the side it fell on.
    ///
    /// Behind the debug flag. It is a dozen or so lines per collapse.
    private func logTheBarAsItWasRead(_ inventory: [MenuBarInventory.Item],
                                      chevron: (x: CGFloat, width: CGFloat),
                                      keep: [String]) {
        guard MTDebug.enabled else { return }
        let divider = chevron.x + chevron.width / 2
        let age = MenuBarInventory.snapshotAge.map { String(format: "%.1fs old", $0) } ?? "age unknown"
        MTDebug.log("bar as read: chevron=\(Int(chevron.x))-\(Int(chevron.x + chevron.width)) "
                    + "divider=\(Int(divider)), \(inventory.count) item(s), snapshot \(age)")
        let keeping = Set(keep)
        for item in inventory.sorted(by: { $0.x < $1.x }) {
            let side = item.maxX > divider ? "keep" : "HIDE"
            let asked = keeping.contains(item.bundleIdentifier) ? "" : "  (not in allow-list)"
            MTDebug.log("  \(side)  \(Int(item.x))-\(Int(item.maxX))  \(item.bundleIdentifier)\(asked)")
        }
    }

    /// Record any allow-listed app that is not installed straight into
    /// `/Applications`.
    ///
    /// Assessment mode matches on bundle identifier, and on macOS 27
    /// `MenuBarAgent` resolves that identifier from **where the app lives**.
    /// For an app launched from outside `/Applications` it hands assessment
    /// mode a **nil** identifier, and nil matches nothing in any allow-list, so
    /// the system takes that icon down along with the ones that were genuinely
    /// asked for. Whichever side of the chevron it was on.
    ///
    /// Settled in Pelmet [issue #30](https://github.com/fif7y/pelmet/issues/30)
    /// by a reporter's symlink test: iStat Menus 7 runs its menu bar helper
    /// from `~/Library/Application Support/iStat Menus 7/`, the agent read nil,
    /// and symlinking that path to a copy in `/Applications` made the agent
    /// resolve the real path and read `com.bjango.istatmenus.status` correctly.
    /// The icon came back. This app builds its allow-list from bundle
    /// identifiers too, so it behaves identically and cannot fix it either.
    ///
    /// **Not reproducible on this machine**: every menu bar app here runs from
    /// `/Applications` or `/System`. So this does not fix anything and does not
    /// claim the case is happening. It puts the one fact that separates it from
    /// every other cause into the log, so the next "my icons vanished" can be
    /// answered from evidence rather than a guess, and pointed at the symlink.
    ///
    /// The test is the **parent directory**, not a prefix. `/Applications/Foo.app`
    /// is the resolving case; a nested install such as `/Applications/Setapp/Foo.app`
    /// is not known to resolve and a prefix test would wave it through.
    ///
    /// Only the unusual case is logged. An ordinary bar says nothing here.
    private func logAllowListedAppsInUnusualLocations(_ keep: [String]) {
        guard MTDebug.enabled else { return }
        let running = NSWorkspace.shared.runningApplications
        let unusual = keep.sorted().compactMap { identifier -> String? in
            guard let url = running.first(where: { $0.bundleIdentifier == identifier })?.bundleURL
            else { return nil }
            let parent = url.deletingLastPathComponent().path
            guard parent != "/Applications", parent != "/System", !parent.hasPrefix("/System/")
            else { return nil }
            return "\(identifier) at \(url.path)"
        }
        guard !unusual.isEmpty else { return }
        MTDebug.log("allow-list: \(unusual.count) app(s) are not installed directly in /Applications, "
                    + "which macOS 27 may drop whichever side of the chevron they are on: "
                    + unusual.joined(separator: "; "))
    }

    /// Check that the collapse kept what it said it would keep.
    ///
    /// Being in the allow-list is permission to be visible. **It does not
    /// reserve space.** macOS drops items of its own accord when the bar is
    /// overfull, allow-listed ones included, and an app whose bundle
    /// identifier the system reads as nil can never be matched at all. Both
    /// look identical to the user: an icon that was to the right of the chevron
    /// and is now gone. Neither left any trace in this log.
    ///
    /// So: which apps owned an item before the collapse, were asked to keep it,
    /// and own none afterwards. Named, so the next report starts with an answer.
    ///
    /// **Read the silence correctly.** An item macOS merely stops drawing stays
    /// in the Accessibility tree at the position it would have had, so this
    /// cannot see it. What it catches is an item that was **destroyed**, which
    /// is the failure worth a name. A quiet log here does not prove every icon
    /// is on screen.
    ///
    /// Behind the debug flag, because it costs one extra Accessibility sweep
    /// per collapse. `probe` reads without writing, so it cannot poison the
    /// cached snapshot the way a `refresh` during a collapse would.
    ///
    /// One interaction to know about while debugging: `probe` and `refresh`
    /// share a one-at-a-time token, so an expand landing inside this probe's
    /// half-second window has its own refresh dropped. Only reachable with
    /// debug logging on, and only for a double click on the chevron, but it
    /// would look like a snapshot that failed to update for no reason.
    private func verifyTheCollapseKeptWhatItPromised(_ keep: [String], before: [MenuBarInventory.Item]) {
        guard MTDebug.enabled else { return }
        // Long enough for macOS to finish reflowing the bar. The restriction
        // itself reports ACTIVE within about 10 ms; the reflow after it has
        // never been measured, so this is a generous round number chosen for an
        // instrument rather than a tuned figure for behaviour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isCollapsed else { return }
            MenuBarInventory.probe { after in
                let owned = Set(before.map { $0.bundleIdentifier })
                let survived = Set(after.map { $0.bundleIdentifier })
                let lost = Set(keep).intersection(owned).subtracting(survived).sorted()
                guard !lost.isEmpty else { return }
                MTDebug.log("collapse check: \(lost.count) allow-listed app(s) left the bar anyway: "
                            + lost.joined(separator: ", "))
            }
        }
    }


    func collapse(userInitiated: Bool = true) {
        isCollapsed = true
        stopAutoCollapseTracking()
        // Collapsing hides the very icons a Reveal panel is listing, so dismiss
        // it. Auto-collapse never fires while the panel is open (see
        // evaluateAutoCollapse), so in practice this only runs on a manual
        // collapse — clicking the chevron while Reveal is up.
        revealPanel?.close()
        revealPanel = nil

        // macOS 27 draws the whole bar as one window, so the spacer has nothing
        // to push and hides nothing. There, ask macOS to restrict the bar
        // instead. Everything earlier keeps the spacer, unchanged.
        if MenuBarRestriction.isAvailable {
            applyMenuBarRestriction(userInitiated: userInitiated)
            updateIcon()
            return      // the off-screen safety check below is a spacer concern only
        }

        spacerItem?.length = 10_000
        updateIcon()

        // Safety: if the chevron got pushed off-screen, undo immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard let window = self.chevronItem.button?.window else {
                self.expand(startTracking: false)
                return
            }
            let frame = window.frame
            // Test against the chevron's OWN display, not global (0,0). With
            // "Displays have separate Spaces", the chevron's window moves to
            // whichever display is active; a display arranged left of the main
            // one lives in negative-x global space, so absolute checks
            // (maxX < 50, minX < 0) fire spuriously there and we'd "collapse
            // then immediately reopen". (GitHub issue #1.)
            let screenFrame = (window.screen
                ?? NSScreen.screens.first { $0.frame.intersects(frame) }
                ?? NSScreen.main)?.frame
            guard let screenFrame else {
                self.expand(startTracking: false)   // not on any screen → genuinely off-screen
                return
            }
            // Chevron is off-screen if squeezed to nothing, or pushed past the
            // left edge of its own display.
            if frame.width < 5
                || frame.maxX < screenFrame.minX + 50
                || frame.minX < screenFrame.minX {
                self.expand(startTracking: false)
            }
        }
    }

    // `startTracking` lets the safety-revert path below re-expand without
    // re-arming auto-collapse — otherwise a chevron pushed off-screen (a broken
    // arrangement) would collapse, revert, and collapse again on a loop.
    func expand(startTracking: Bool = true) {
        isCollapsed = false
        if MenuBarRestriction.isAvailable {
            MenuBarRestriction.release()
            // Re-inventory now the bar is whole again. A restricted bar
            // under-reports, so a snapshot taken during a collapse would shrink
            // the allow-list a little more each cycle.
            MenuBarInventory.refresh { [weak self] in self?.warnIfTheBarIsTooFull() }
        } else {
            spacerItem?.length = 0
        }
        updateIcon()
        if startTracking {
            startAutoCollapseTracking()
        }
    }

    /// The chevron's rectangle in screen coordinates.
    ///
    /// Everything to the right of this survives a collapse, so a wrong answer
    /// here does not fail loudly — it quietly keeps the wrong set of icons. A
    /// reading of 361 instead of 896 kept 23 apps out of 24, which is a collapse
    /// that hides almost nothing.
    ///
    /// **macOS 14 to 26:** the status item owns a real window and its frame is
    /// the truth. Unchanged.
    ///
    /// **macOS 27:** it does not. The whole bar is one Window Server window and
    /// this app owns nothing at the menu bar layer, confirmed with
    /// `CGWindowList`. AppKit still returns an `NSWindow`, but its frame is
    /// stale whenever macOS reflows the bar — which happens every time any app
    /// with a variable-width item changes width. So ask Accessibility, which
    /// reports where the item was actually drawn.
    ///
    /// Falls back to the window frame when the snapshot has no entry for us yet,
    /// which is better than refusing to collapse at all.
    private func chevronRect() -> (x: CGFloat, width: CGFloat)? {
        if MenuBarRestriction.isAvailable,
           let ownIdentifier = Bundle.main.bundleIdentifier,
           let item = MenuBarInventory.item(ofBundleIdentifier: ownIdentifier) {
            let x = item.x
            // Log the disagreement, not just the answer. How far the window
            // frame drifts from where the item was drawn is the only field
            // evidence we have for how badly macOS 27 reflows behind AppKit's
            // back, and it costs nothing to record.
            if let stale = chevronItem.button?.window?.frame.minX, abs(stale - x) >= 1 {
                MTDebug.log(String(format: "chevron: drawn at %.0f, AppKit window says %.0f (drift %.0f)",
                                   x, stale, x - stale))
            }
            return (x, item.width)
        }
        guard let frame = chevronItem.button?.window?.frame else { return nil }
        return (frame.minX, frame.width)
    }

    /// Notice when a click on the chevron reaches nothing, and get the user out.
    ///
    /// ## The fault this recovers from
    ///
    /// macOS 27 hides a menu bar item **without reclaiming its space**: it stops
    /// being drawn but keeps its rectangle. That is normally invisible. It stops
    /// being invisible when the bar runs out of room, because macOS then drops
    /// items of its own accord — including ones this app has explicitly
    /// allow-listed, since the allow-list grants permission to be visible and
    /// does not reserve space.
    ///
    /// Measured on 2026-09-20. Ballast puts the song title in the bar, so its
    /// item grows with the track name; it was measured between 36 and 378 points
    /// wide on the same machine within ten minutes. On a long title the bar
    /// overflowed, macOS dropped Ballast despite it being allow-listed, and the
    /// 310-point rectangle it left behind lay across this app's chevron. Clicks
    /// posted at thirteen positions from x=800 to x=1090 reached **nothing**.
    /// The same sweep with a short title hit at exactly 1010, 1030 and 1045, the
    /// chevron's real rectangle.
    ///
    /// The chevron is the only way to expand, so this strands the user with a
    /// collapsed bar and no way back.
    ///
    /// ## Why this is detected by click rather than by geometry
    ///
    /// The obvious check is "does another item's rectangle cover mine". It does
    /// not work. Hidden items park in a stack immediately right of the notch,
    /// and when the chevron is the leftmost visible item it sits in that same
    /// place — measured at 854-890 with seven parked ghosts at 852-890. A
    /// geometric test cannot tell that harmless stack from Ballast's dead
    /// rectangle, and undoes every collapse.
    ///
    /// So this asks the question that actually matters: did a click land on the
    /// chevron and do nothing. A global monitor **never sees events delivered to
    /// this app**, so a menu bar click that reaches this monitor is by
    /// definition one this app did not get. If it landed inside the chevron, the
    /// chevron is buried, and releasing the restriction gives the user their bar
    /// back.
    private func watchForBuriedChevron() {
        guard MenuBarRestriction.isAvailable, buriedChevronMonitor == nil else { return }
        MTDebug.log("watching for clicks that miss the chevron")
        buriedChevronMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp]
        ) { [weak self] event in
            guard let self, self.pointerInMenuBar() else { return }
            // Read the menu state HERE, not in the completion below: the probe
            // takes a few hundred milliseconds and the menu will have closed by
            // then, so asking later always answers "no menu".
            guard !self.menuIsOpen else { return }
            // Independent of the chevron check below, and deliberately not
            // exclusive with it: the clock is the rightmost item in the bar and
            // is always allow-listed, so a click can never be inside both it
            // and this app's chevron.
            if event.type == .leftMouseUp {
                self.relayClockClickIfItWentNowhere(at: NSEvent.mouseLocation.x)
            }
            self.checkWhetherClickMissedTheChevron(at: NSEvent.mouseLocation.x,
                                                   wasRightButton: event.type == .rightMouseUp,
                                                   clickedAt: Date())
        }
    }

    /// Was `x` inside the chevron. If so the click was aimed at us and went
    /// somewhere else, which only happens when the chevron is buried.
    ///
    /// Read live rather than from the cache: the whole point is that the bar has
    /// reflowed since the collapse. The walk is off the main thread and only
    /// runs on a menu bar click that this app did not receive, so it is rare.
    private func checkWhetherClickMissedTheChevron(at x: CGFloat,
                                                   wasRightButton: Bool,
                                                   clickedAt: Date) {
        guard let ownIdentifier = Bundle.main.bundleIdentifier else { return }

        // Wait for the normal path before doing ANY work. A global monitor DOES
        // see clicks on a status item even when this app receives them too — the
        // system draws the bar, so the event reaches the global stream either
        // way. So most of what arrives here was handled perfectly well a
        // moment ago and needs nothing.
        //
        // Deciding that cheaply matters. An earlier cut walked Accessibility
        // first and checked afterwards, which put a walk on the path of every
        // single menu bar click, including the click that starts a collapse.
        // That walk queries this app's own process too, and an Accessibility
        // query against ourselves has to be served by our main thread — the same
        // thread trying to perform the collapse. The collapse visibly lagged.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clickHandOverWindow) {
            // Re-check the menu here, not only at the monitor, and throw away a
            // click that has gone stale.
            //
            // An open NSMenu stops this app's main run loop dead for as long as
            // it is on screen — not slows, stops. Measured 2026-09-20 with a
            // replica of showMenu(): a block scheduled 0.03s before a menu
            // opened ran 2.7s late in one run and **28.1 seconds** late in
            // another, in both cases the instant the menu closed. Heartbeat
            // timers froze for the same interval.
            //
            // So without this, a click can be judged here long after the user
            // made it, and several queued clicks fire in one burst when the menu
            // closes — collapsing or expanding the bar for no reason the user
            // can see.
            guard !self.menuIsOpen,
                  Date().timeIntervalSince(clickedAt) < Self.staleClickCutoff else { return }

            // Near in time, in EITHER direction. The monitor and the status
            // item's own action both fire on mouse-up and their order is not
            // guaranteed. An earlier cut tested `lastHandledClick < clickedAt`,
            // so whenever the monitor happened to be timestamped later the
            // guard passed and the recovery collapsed a bar the user had just
            // expanded — appearing as auto-collapse firing instantly.
            guard abs(clickedAt.timeIntervalSince(self.lastHandledClick))
                    >= Self.clickHandOverWindow else { return }
            self.walkToConfirmTheClickMissed(at: x, wasRightButton: wasRightButton,
                                             ownIdentifier: ownIdentifier)
        }
    }

    /// How long to give the ordinary click path before treating a click as lost.
    ///
    /// This is the gap between the button going up and `statusItemClicked`
    /// running, which is a few milliseconds when it happens at all. A quarter of
    /// a second is far longer than that and still far shorter than a person can
    /// notice, and nothing happens during the wait.
    private static let clickHandOverWindow: TimeInterval = 0.25

    /// Past this age a click is not worth acting on.
    ///
    /// Only reachable when the main run loop has been stalled, which an open
    /// menu does for its whole lifetime. Acting on a click this old means acting
    /// on an intention the user abandoned long ago.
    private static let staleClickCutoff: TimeInterval = 1.0

    private func walkToConfirmTheClickMissed(at x: CGFloat, wasRightButton: Bool,
                                             ownIdentifier: String) {
        MenuBarInventory.probe { live in
            guard let mine = live.first(where: { $0.bundleIdentifier == ownIdentifier }),
                  x >= mine.x, x <= mine.maxX else { return }
            MTDebug.log(String(format:
                "chevron is buried: a %@-click at %.0f fell inside it (%.0f-%.0f) and never arrived. Acting on it here.",
                wasRightButton ? "right" : "left", x, mine.x, mine.maxX))
            if wasRightButton {
                // The menu is what the click asked for, so give them the menu,
                // at the pointer rather than via the button. Expanding instead
                // would be a surprise, and would hide the very thing they were
                // reaching for.
                self.showMenu(at: NSEvent.mouseLocation)
            } else if !self.isCollapsed {
                // A missed LEFT click while EXPANDED is deliberately ignored.
                //
                // Recovering it would mean collapsing, and a wrong collapse is
                // destructive: it hides the user's icons and they may not even
                // realise the state changed. A wrong menu is merely a menu.
                //
                // It has to be ignored because our own position cannot be
                // trusted in this state. Measured 2026-09-20: within two log
                // lines, a live probe put this app's item at 856-892 while the
                // collapse that followed put it at 1008-1044. On an overfull
                // expanded bar our own item can be sitting on a ghost rectangle
                // like any other. A click at 884 was matched to the chevron,
                // was not aimed at it, and collapsed the bar under the user.
                //
                // Collapsed is different: the bar is not overfull, positions
                // agree, and the recovery's action is to EXPAND, which shows
                // more rather than less and is instantly obvious if wrong.
                MTDebug.log(String(format:
                    "missed left-click at %.0f ignored: expanded, so our own position is not trustworthy", x))
            } else {
                // Auto-collapse is left ARMED here, deliberately.
                //
                // An earlier cut suppressed it, reasoning that re-collapsing
                // would just bury the chevron again. That was the wrong trade:
                // burials are frequent when a long title is playing, so every
                // one of them silently switched off a feature the user had
                // turned on, and it looked like auto-collapse was broken.
                //
                // It is also no longer necessary. Burial used to be a trap
                // because the chevron was the only way back and it had stopped
                // answering. It is survivable now — that is what this whole
                // recovery is — so honour the setting and let the user turn it
                // off themselves if they would rather.
                self.expand()
            }
        }
    }

    // MARK: Menu

    /// The share of the screen's width at which the menu bar counts as too
    /// full, as a fraction. `defaults write cc.jorviksoftware.MenuTidy
    /// menuBarFullThreshold -float 0.7` moves it.
    ///
    /// 0.8 is Jonathan's figure and it came from measurement rather than taste.
    /// His bar sat at 59% with 23 items and behaved. It reached roughly 82%
    /// when Ballast put a long track title in it, and that is when macOS began
    /// dropping items of its own accord.
    private var menuBarFullThreshold: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "menuBarFullThreshold")
        return stored > 0 ? CGFloat(stored) : 0.8
    }

    /// Tell the user their menu bar is too full for macOS to lay out.
    ///
    /// ## What goes wrong when it is
    ///
    /// macOS 27 drops items when the bar runs out of room, and it drops
    /// allow-listed ones too: the allow-list grants permission to be visible,
    /// it does not reserve space. Worse, a dropped item **keeps its
    /// rectangle**, so the bar is left with dead regions where a click reaches
    /// nothing at all. Measured 2026-09-20: clicks posted at thirteen positions
    /// from x=800 to x=1090 reached nothing, while the same sweep with a
    /// shorter item present hit normally.
    ///
    /// None of that is something this app can fix, and it looks exactly like
    /// this app misbehaving, so it is worth naming.
    ///
    /// ## Said once per run
    ///
    /// This is something to learn, not something to be nagged about. Once the
    /// user knows, repeating it every time they expand the bar adds nothing.
    private func warnIfTheBarIsTooFull() {
        guard !hasSaidTheBarIsFull,
              let width = NSScreen.main?.frame.width,
              let share = MenuBarInventory.occupancy(ofScreenWidth: width) else { return }
        let threshold = menuBarFullThreshold

        // Off the main thread: asking whether macOS has added its own chevron
        // means a round trip to another process, and this runs after every
        // expand.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let alreadyHiding = MenuBarInventory.macOSIsHidingItems
            guard alreadyHiding || share >= threshold else { return }
            DispatchQueue.main.async {
                guard let self, !self.hasSaidTheBarIsFull else { return }
                self.hasSaidTheBarIsFull = true
                MTDebug.log(String(format:
                    "menu bar is %.0f%% full (%.0f pt of %.0f pt), threshold %.0f%%; macOS %@ hiding items of its own accord",
                    share * 100, share * width, width, threshold * 100,
                    alreadyHiding ? "IS" : "is not"))
                if alreadyHiding {
                    // Present tense on purpose. This is not a forecast: icons
                    // are being dropped right now.
                    NotchWarning.show(title: "Menu bar is full",
                                      detail: "macOS is hiding icons itself")
                } else {
                    NotchWarning.show(title: "Menu bar is nearly full",
                                      detail: "macOS may start hiding icons")
                }
            }
        }
    }

    /// Whether a click on the clock should be relayed while the bar is
    /// collapsed. On by default; `defaults write cc.jorviksoftware.MenuTidy
    /// relayClockClick -bool NO` restores the behaviour 2.2.1 shipped, where
    /// the click simply does nothing.
    ///
    /// A knob rather than a fixed choice because the cost of the fix is
    /// visible: every hidden icon flashes back for the length of the swap. How
    /// acceptable that is can only be judged by looking at it.
    private var relayClockClick: Bool {
        UserDefaults.standard.object(forKey: "relayClockClick") as? Bool ?? true
    }

    /// Finish a click on the clock that macOS refused to act on.
    ///
    /// While the bar is collapsed a restriction is active, and macOS will not
    /// open Notification Centre while one is — see
    /// `MenuBarRestriction.withRestrictionLifted(do:)` for the measurements.
    /// The clock still draws the right time; only the click is dead. Users
    /// reported this against Hidden Bar as issue #421 as well, so it is not
    /// something this app does wrong.
    ///
    /// This spots the dead click and completes it: drop the restriction, press
    /// the clock, put the restriction back.
    ///
    /// ## Why the work is off the main thread
    ///
    /// Finding the clock is one Accessibility query against one system daemon,
    /// not the full sweep, but it still crosses a process boundary and it runs
    /// on every menu bar click made while collapsed. An earlier version of the
    /// buried-chevron recovery put an Accessibility walk on the click path and
    /// the collapse visibly lagged. Nothing here needs the main thread until
    /// there is something to do.
    private func relayClockClickIfItWentNowhere(at x: CGFloat) {
        guard relayClockClick, MenuBarRestriction.isRestricting else { return }

        // A click made while the panel is open is the user closing it, and the
        // raw click already does that on its own — the panel dismisses on any
        // click outside itself, restriction or no restriction. Pressing the
        // clock as well would open it straight back, so the panel could never
        // be closed this way. Measured 2026-09-20: four clicks in a row all
        // left it open.
        //
        // Read here, on mouse-up, and that is early enough: measured in the
        // same session, the panel is still listed at mouse-up and only goes
        // afterwards.
        guard !MenuBarInventory.isNotificationCentreShowing else {
            MTDebug.log("clock: the panel is already open, so the click closes it by itself")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let clock = MenuBarInventory.systemClock(),
                  x >= clock.x, x <= clock.x + clock.width else { return }
            DispatchQueue.main.async {
                // Re-checked: the bar may have expanded during the lookup, and
                // if it has then the click the user made worked by itself.
                guard MenuBarRestriction.isRestricting else { return }
                // Mark the click as dealt with. Without this the buried-chevron
                // recovery treats it as a click nobody handled and runs a full
                // Accessibility walk 0.25s later to find out why — measured at
                // 0.3s across 27 apps, after EVERY click on the clock, for an
                // answer that was never in doubt.
                self.lastHandledClick = Date()
                MTDebug.log(String(format:
                    "clock: a left-click at %.0f landed in the clock (%.0f-%.0f), which macOS ignores while restricted. Lifting the restriction to open Notification Centre.",
                    x, clock.x, clock.x + clock.width))
                MenuBarRestriction.withRestrictionLifted {
                    if !MenuBarInventory.pressSystemClock() {
                        MTDebug.log("clock: the press failed")
                    }
                }
            }
        }
    }

    func showMenu() {
        MTDebug.log("showMenu: opening the right-click menu")
        // Snapshot the panel's open state *before* performClick opens the menu
        // (which dismisses the panel), so revealHiddenIcons() can toggle it off.
        revealPanelWasOpenAtMenuInvoke = (revealPanel?.isVisible == true)
        let menu = buildMenu()
        menu.delegate = self
        chevronItem.menu = menu
        chevronItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.chevronItem.menu = nil
        }
    }

    /// Open the menu at a point on screen, without going through the status
    /// item's button.
    ///
    /// `showMenu()` asks the button to click itself, which is the right thing to
    /// do when the bar is behaving. It is the wrong thing when the click had to
    /// be recovered, because the reason it needed recovering is that the button
    /// is not where macOS is drawing the item. Measured on 2026-09-20: with the
    /// bar expanded and overfull, the chevron was reported at x=250 — spilled to
    /// the **left** of the notch — seconds after a click at x=1065 was matched
    /// to it. `performClick` on that button logged success and showed nothing.
    ///
    /// Popping the menu at the pointer needs no button and no correct item
    /// position, so it works in exactly the case that defeats the normal path.
    func showMenu(at point: NSPoint) {
        MTDebug.log(String(format: "showMenu: popping the menu at %.0f,%.0f", point.x, point.y))
        revealPanelWasOpenAtMenuInvoke = (revealPanel?.isVisible == true)
        let menu = buildMenu()
        menu.delegate = self
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    /// Cleared a beat late on purpose. The click that dismisses a menu arrives
    /// while the menu is still closing, so clearing this synchronously would
    /// reopen the very window the flag exists to close.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.menuIsOpen = false
        }
    }

    @objc func openAbout() {
        JorvikAboutView.showWindow(
            appName: "MenuTidy",
            repoName: "MenuTidy",
            productPage: "utilities/menutidy"
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        sparkleUpdater.checkForUpdates(sender)
    }

    @objc func openSettings() {
        JorvikSettingsView.showWindow(appName: "MenuTidy") { [weak self] in
            MenuTidySettingsContent(
                onPillChanged: { self?.updateIcon() },
                onAutoCollapseChanged: { self?.autoCollapseSettingsChanged() }
            )
        }
    }

    @objc func revealHiddenIcons() {
        // Toggle: if the panel was open when this menu was invoked, close it and
        // stop. Decided from the pre-menu snapshot, not the live panel, because
        // opening the menu already dismissed it.
        let wasOpen = revealPanelWasOpenAtMenuInvoke
        revealPanelWasOpenAtMenuInvoke = false
        if wasOpen {
            revealPanel?.close()
            revealPanel = nil
            return
        }

        let axGranted = AXIsProcessTrusted()
        if !axGranted {
            // Trigger the system prompt the first time. The panel will show
            // its own "permission required" message in the meantime.
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        // Open in a loading state and scan fresh — never show the cached
        // snapshot, which the user can't distinguish from the final list. The
        // spinner is replaced by the real list once the background walk
        // completes. Always a *full* walk: an app that launched after the last
        // enumeration wouldn't be in the fast-path host-PID cache.
        let panel = HiddenIconsPanel(axGranted: axGranted)
        panel.anchor(to: chevronItem)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        revealPanel = panel
        // Dismissing the panel (esp. click-away) must re-arm auto-collapse: closing it
        // isn't a mouse-move, so the tracking monitor never re-evaluates on its own and
        // the bar would stay expanded forever. Re-evaluate on close (a no-op during a
        // controller-driven collapse, which has already set isCollapsed + stopped tracking).
        panel.onDismiss = { [weak self] in self?.evaluateAutoCollapse() }

        MTDebug.log("reveal open: axGranted=\(axGranted) (scanning)")
        guard axGranted else { return }   // no scan without AX; panel shows the permission message
        HiddenIcons.refreshAsyncFull { [weak panel] fresh in
            MTDebug.log("reveal refresh done: fresh=\(fresh.count) panelVisible=\(panel?.isVisible == true)")
            guard let panel, panel.isVisible else { return }
            panel.updateItems(fresh)
        }
    }

    func buildMenu() -> NSMenu {
        let tipText = NSAttributedString(
            string: "\u{2318}+drag icons to the right of the\nspacer to keep them always visible",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let tip = JorvikMenuBuilder.ActionItem(
            title: "",
            action: #selector(NSObject.description),
            target: self,
            isEnabled: false,
            attributedTitle: tipText
        )

        var actions: [JorvikMenuBuilder.ActionItem] = []
        let separator = JorvikMenuBuilder.ActionItem(
            title: "-", action: #selector(NSObject.description), target: self
        )

        // The tip explains how to drag icons past the spacer. There is no spacer
        // on macOS 27, so the advice would be nonsense there.
        if !MenuBarRestriction.isAvailable {
            actions.append(tip)
        }

        // Only offer the reveal action on notched displays, and only while the
        // bar is expanded — when collapsed, every third-party icon is shoved
        // off-screen to the spacer sentinel (~-4400), so there's nothing
        // meaningful to reveal or activate.
        //
        // Not offered on macOS 27 at all: the system grew its own overflow
        // chevron for exactly this, and doing it ourselves as well would be two
        // competing answers to one question. Jonathan's call, and it makes the
        // app smaller on the newer OS rather than larger.
        if HiddenIcons.notchHorizontalRange() != nil && !isCollapsed && !MenuBarRestriction.isAvailable {
            if !actions.isEmpty { actions.append(separator) }
            actions.append(.init(
                title: "Reveal Hidden Icons\u{2026}",
                action: #selector(revealHiddenIcons),
                target: self
            ))
        }

        // Only separate from what came before if there IS anything before, or
        // the menu opens with a stray divider under About.
        if !actions.isEmpty { actions.append(separator) }
        actions.append(.init(
            title: "Check for Updates\u{2026}",
            action: #selector(checkForUpdates(_:)),
            target: self
        ))

        return JorvikMenuBuilder.buildMenu(
            appName: "MenuTidy",
            aboutAction: #selector(openAbout),
            settingsAction: #selector(openSettings),
            target: self,
            actions: actions
        )
    }
}

// MARK: - Sparkle User Driver Delegate

/// Keeps Sparkle's update UI visible across the whole session, including
/// when the user switches to another app mid-download. See KB:
/// `conventions/sparkle-integration.md` §6 for the rationale.
final class MenuTidyUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}

// MARK: - Hidden-Icons Detection

struct HiddenIcon {
    let appName: String
    let appIcon: NSImage?
    let title: String?
    let frame: CGRect
    let axElement: AXUIElement
}

enum HiddenIcons {

    // MARK: Live cache
    //
    // Enumerating every app's AXExtrasMenuBar takes ~hundreds of ms because
    // each AX call crosses a process boundary. Doing it lazily on every
    // panel open felt sluggish; instead we keep a cache that's populated
    // event-driven (initial fetch + refresh on app launch/terminate) so the
    // panel reads it instantly.

    private static let cacheQueue = DispatchQueue(label: "cc.jorviksoftware.MenuTidy.hidden-icons.cache")
    private static var _cached: [HiddenIcon] = []
    private static var cachingStarted = false
    private static var lastAXTrusted = false
    private static var axPollTimer: Timer?

    // Cache of PIDs known to host status items (AXExtrasMenuBar non-nil).
    // Built by detectClippedFull(); read by detectClipped() to skip the
    // ~70% of running apps that have no menu bar items at all.
    private static let pidQueue = DispatchQueue(label: "cc.jorviksoftware.MenuTidy.hidden-icons.pids")
    private static var _hostPIDs: Set<pid_t> = []

    private static var hostPIDs: Set<pid_t> {
        pidQueue.sync { _hostPIDs }
    }
    private static func setHostPIDs(_ newValue: Set<pid_t>) {
        pidQueue.sync { _hostPIDs = newValue }
    }
    private static func removeHostPID(_ pid: pid_t) {
        pidQueue.sync { _ = _hostPIDs.remove(pid) }
    }

    static var cached: [HiddenIcon] {
        cacheQueue.sync { _cached }
    }

    /// Idempotent. Wires up event-driven refresh and triggers an initial fetch.
    static func startCaching() {
        guard !cachingStarted else { return }
        cachingStarted = true

        lastAXTrusted = AXIsProcessTrusted()
        refreshAsyncFull()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            // The new app might be a status-item host. Schedule several
            // refreshes at backoff intervals — quick-starting apps are
            // caught at 1.5 s, slow-starting apps (especially Electron
            // wrappers and apps that wait on network/login before
            // surfacing their NSStatusItem) at 5 s or 15 s. Each pass
            // is idempotent; the cost is three extra full walks per
            // launch event, which is fine.
            for delay in [1.5, 5.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { refreshAsyncFull() }
            }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            // Trim the terminated PID from the host cache immediately so
            // subsequent fast walks don't waste an AX query on a dead pid.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                removeHostPID(app.processIdentifier)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshAsync() }
        }

        // macOS doesn't fire a notification when AX permission changes, so
        // poll. Cheap (one syscall every few seconds), and only matters until
        // the user grants AX once — after that the polled value never flips
        // back unless they revoke. On any flip false→true we kick a full
        // refresh because the previous "empty cache" came from no AX access.
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let now = AXIsProcessTrusted()
            if now != lastAXTrusted {
                lastAXTrusted = now
                if now { refreshAsyncFull() }
            }
        }
    }

    /// Background fast refresh — walks the cached PID set only. Falls back
    /// to a full walk if the cache is empty (first launch, post-AX-grant).
    static func refreshAsync(completion: (([HiddenIcon]) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let items = detectClipped()
            cacheQueue.sync { _cached = items }
            if let completion {
                DispatchQueue.main.async { completion(items) }
            }
        }
    }

    /// Background full refresh — walks every running app and rebuilds the
    /// host-PID cache. Used on launch, on AX permission flips, and on app
    /// launch / terminate notifications so any newly-introduced hoster
    /// (or removed one) is reflected in subsequent fast refreshes.
    static func refreshAsyncFull(completion: (([HiddenIcon]) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let items = detectClippedFull()
            cacheQueue.sync { _cached = items }
            if let completion {
                DispatchQueue.main.async { completion(items) }
            }
        }
    }

    /// Returns the X range occupied by the notch on the main screen, or nil if
    /// the screen has no notch. Used both to gate the reveal feature and to
    /// classify which status items are clipped.
    /// Extra clearance beyond the *reported* notch edge before macOS will actually draw a status item.
    ///
    /// `auxiliaryTopRightArea.minX` is not the draw boundary. Established from two observations, each
    /// pairing a logged layout with what was genuinely on screen at that moment:
    ///
    ///   a) Rainy Day at 862 invisible, HyperCaps at 895 the leftmost visible → boundary ∈ (862, 895]
    ///   b) Rainy Day at 845 invisible, HyperCaps at 878 the leftmost visible → boundary ∈ (845, 878]
    ///
    /// Intersecting those gives a boundary in **(862, 878]** on a display reporting its notch edge at
    /// 848 — an inset of 14 to 30 points. The reported edge, 848, satisfies neither observation, which
    /// is why an icon sitting in that band was reported visible while being nowhere on screen.
    ///
    /// This is a *measured* constant, not a derived one: nothing in AppKit reports it, and a probe
    /// status item measures the leftmost available slot given current packing, which is a different
    /// quantity (it read 896 — above the bracket — and would have hidden HyperCaps). So it is exposed
    /// rather than buried, defaulted to the middle of the bracket:
    ///
    ///     defaults write cc.jorviksoftware.MenuTidy notchDrawInset -float 22
    ///
    /// **Err low if it ever needs adjusting.** Too small merely restores the old under-detection, which
    /// omits an icon from the panel. Too large hides icons that are genuinely on screen — the worse
    /// failure, and one this code shipped briefly while I had it at 1014.
    static var notchDrawInset: CGFloat {
        guard let override = UserDefaults.standard.object(forKey: "notchDrawInset") as? Double else { return 22 }
        return CGFloat(override)
    }

    static func notchHorizontalRange() -> ClosedRange<CGFloat>? {
        guard let screen = NSScreen.main else { return nil }
        guard screen.safeAreaInsets.top > 0 else { return nil }
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return nil }
        let lo = leftArea.maxX
        let hi = rightArea.minX
        guard hi > lo else { return nil }
        return lo...hi
    }

    /// Fast detect — walks only the cached host-PID set. Drops detect time
    /// from ~1.6 s (full walk over ~80 apps) to ~400 ms (~25 apps with
    /// status items). Falls back to a full walk if the cache is empty,
    /// which happens on first run, after an AX permission grant, or if
    /// the user has somehow ended up with no cached hosters.
    static func detectClipped() -> [HiddenIcon] {
        let cached = hostPIDs
        if cached.isEmpty {
            return detectClippedFull()
        }
        let candidates = cached.compactMap { NSRunningApplication(processIdentifier: $0) }
        return walk(candidates: candidates, isFullWalk: false)
    }

    /// Full detect — walks every running app and rebuilds the host-PID
    /// cache. More expensive (~1.6 s); used at moments where new hosters
    /// might have appeared (launch, AX flip, app-launch notifications).
    static func detectClippedFull() -> [HiddenIcon] {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0.processIdentifier > 0
        }
        return walk(candidates: candidates, isFullWalk: true)
    }

    /// Shared walk — parallelises AX queries across cores and aggregates
    /// results under a single NSLock. On a full walk, also rebuilds the
    /// host-PID cache from the apps that returned a non-nil AXExtrasMenuBar.
    private static func walk(candidates: [NSRunningApplication], isFullWalk: Bool) -> [HiddenIcon] {
        guard let notchRange = notchHorizontalRange() else { return [] }
        // Right edge of the main screen in global coordinates — a visible item
        // must lie within it. `screenMaxX` guards the (rare) off-the-right case.
        let screenMaxX = NSScreen.main?.frame.maxX ?? .greatestFiniteMagnitude

        // The boundary macOS actually draws from — the reported notch edge plus the measured inset.
        let drawBoundary = notchRange.upperBound + notchDrawInset

        MTDebug.log("--- walk (\(isFullWalk ? "full" : "fast")) notch=\(notchRange.lowerBound)...\(notchRange.upperBound) inset=\(notchDrawInset) drawBoundary=\(drawBoundary) screenMaxX=\(screenMaxX) ---")

        let lock = NSLock()
        var result: [HiddenIcon] = []
        var hostsFound: Set<pid_t> = []

        DispatchQueue.concurrentPerform(iterations: candidates.count) { idx in
            let app = candidates[idx]
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)

            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
                  let extras = extrasRef else { return }
            let extrasEl = extras as! AXUIElement

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(extrasEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let items = childrenRef as? [AXUIElement] else {
                lock.lock(); hostsFound.insert(pid); lock.unlock()
                return
            }

            var localClipped: [HiddenIcon] = []
            for item in items {
                let frame = axFrame(of: item)
                // Require a real, rendered frame.
                guard frame.width > 0, frame.height > 0 else { continue }
                // Sanity check: real menu bar status items are 20–60pt wide.
                // AX occasionally returns bogus aggregate frames (Control Centre
                // reports a 5016pt-wide rect when MenuTidy's spacer expands to
                // 10000pt and the menu bar geometry is unusual). Anything
                // wider than the notch itself can't be a partially-clipped
                // status item — it's a misreported aggregate.
                guard frame.width <= 200 else { continue }
                // An item is hidden by the notch in two distinct ways:
                //
                //   1. *Partial* clip — the frame straddles the notch range
                //      (e.g. ScreenLock at x=794, ShortcutHUD at x=690 with
                //      a notch at 663–848). The visible portion peeks out
                //      one side of the notch.
                //
                //   2. *Full* clip — the menu bar didn't have enough room
                //      for this item once the notch consumed its space, so
                //      macOS pushed the entire item off-screen to the left.
                //      AX reports a far-negative x sentinel (typically
                //      around -4000pt). A purely-overlap predicate misses
                //      these because their frame isn't anywhere near the
                //      notch range geometrically.
                //
                // Catch both. `maxX <= 0` is a clean signal for case 2 —
                // legitimately-visible left-of-notch items report small
                // positive maxX (their visible portion sits at x ≥ 0).
                // On a notched display, status items are only ever *visible*
                // to the RIGHT of the notch (the strip left of the notch is
                // app-menu territory). So an item is visible iff it sits fully
                // right of the notch and on-screen. Everything else is hidden:
                //   - overlapping the notch (partial clip),
                //   - parked just LEFT of the notch (overflow that didn't fit
                //     right of it — these tile leftward from the notch; an
                //     earlier `overlapsNotch || maxX<=0` test wrongly counted
                //     them as visible, which is why exposing dropped icons like
                //     AdGuard Mini / RainbowApple / MirrorGuard from the panel),
                //   - flung off-screen-left to the spacer's ~-4000 sentinel.
                let visibleRightOfNotch = frame.minX >= drawBoundary && frame.minX < screenMaxX
                // Unplaced sentinel: some apps register a status item they
                // aren't actually showing; AX parks it at the screen's far-left
                // origin (x≈-1…7, so a tiny positive maxX). No real status
                // item — visible or overflow — lives in that Apple-menu strip,
                // so a frame whose right edge is within 50pt of the origin is
                // junk, not a hidden icon. (The off-screen-left sentinel has
                // maxX <= 0, so `maxX > 0` keeps it out of this exclusion and
                // it stays correctly counted as hidden.)
                let unplacedSentinel = frame.maxX > 0 && frame.maxX <= 50
                let isHidden = !visibleRightOfNotch && !unplacedSentinel

                let title = axString(of: item, attribute: kAXTitleAttribute as CFString)
                let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"

                MTDebug.log(String(format: "item %@ '%@' frame=[x=%.0f w=%.0f maxX=%.0f] visibleRight=%@ unplaced=%@ -> %@",
                                   appName, title ?? "",
                                   frame.minX, frame.width, frame.maxX,
                                   visibleRightOfNotch ? "Y" : "n",
                                   unplacedSentinel ? "Y" : "n",
                                   isHidden ? "HIDDEN" : "visible"))

                guard isHidden else { continue }
                localClipped.append(HiddenIcon(
                    appName: appName,
                    appIcon: app.icon,
                    title: title,
                    frame: frame,
                    axElement: item
                ))
            }

            lock.lock()
            hostsFound.insert(pid)
            result.append(contentsOf: localClipped)
            lock.unlock()
        }

        // After a full walk, hostsFound IS the new cache. After a fast walk
        // it's a subset (apps that still host extras); we don't update the
        // cache here — stale PIDs cost ~25 ms per fast refresh, trimmed on
        // app-terminate notifications.
        if isFullWalk {
            setHostPIDs(hostsFound)
        }

        return result.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private static func axFrame(of element: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        }
        if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    private static func axString(of element: AXUIElement, attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }
}

// MARK: - Hidden-Icons Panel

/// Floating panel listing every status item we found via AX. Each row supports
/// both left- and right-click; the click is forwarded to the underlying status
/// item so the user can use icons that are clipped behind the notch.
final class HiddenIconsPanel: NSPanel {

    private var items: [HiddenIcon] = []
    private let axGranted: Bool
    // While true the panel shows a spinner instead of a list. We never show the
    // cached snapshot — the user can't tell a provisional list from the final
    // one — so the panel opens "scanning" and swaps to the real list when the
    // background walk finishes (updateItems).
    private var isLoading: Bool

    /// Called after the panel dismisses (any path: click-away, Esc, activate, or a
    /// controller-driven close). Lets the controller re-evaluate auto-collapse — a
    /// click that closes the panel is not a mouse-move, so the controller's
    /// mouseMoved tracking would never otherwise re-fire to arm the countdown.
    var onDismiss: (() -> Void)?

    init(axGranted: Bool) {
        self.axGranted = axGranted
        // A spinner only makes sense when we're actually about to scan; without
        // Accessibility there's nothing to scan, so open straight to the
        // permission message instead.
        self.isLoading = axGranted
        let frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        rebuildContent()
    }

    /// Panel height for the current state: a fixed compact box while loading (or
    /// empty), otherwise sized to the row count.
    private func preferredHeight() -> CGFloat {
        if isLoading { return 80 }
        let pad: CGFloat = 8, rowH: CGFloat = 32, footerH: CGFloat = 22
        let headerH: CGFloat = items.isEmpty ? 0 : 22
        return max(pad * 2 + headerH + CGFloat(items.count) * rowH + footerH, 80)
    }

    func anchor(to statusItem: NSStatusItem) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame
        let originX = buttonFrame.midX - frame.width / 2
        let originY = buttonFrame.minY - frame.height - 4
        setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    /// Swap in the freshly-scanned list, replacing the spinner (or a previous
    /// list). The first call out of the loading state always rebuilds — even to
    /// an empty list — so the spinner is guaranteed to be replaced; later
    /// refreshes no-op when the list is unchanged, to avoid flicker.
    func updateItems(_ newItems: [HiddenIcon]) {
        if !isLoading {
            let oldKeys = items.map { "\($0.appName)|\(Int($0.frame.minX))" }
            let newKeys = newItems.map { "\($0.appName)|\(Int($0.frame.minX))" }
            guard oldKeys != newKeys else { return }
        }
        isLoading = false
        items = newItems

        // Resize to fit and rebuild. setFrame(display:true) resizes contentView
        // synchronously so rebuildContent's NSVisualEffectView gets right bounds.
        var f = frame
        let oldHeight = f.height
        f.size.height = preferredHeight()
        f.origin.y += oldHeight - f.size.height  // keep top edge anchored
        setFrame(f, display: true)
        rebuildContent()
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        // Dismiss when the user clicks anywhere else.
        DispatchQueue.main.async { [weak self] in
            self?.close()
        }
    }

    // Notify the controller on EVERY dismissal (click-away, Esc, activate, or a
    // controller-driven close) so it can re-arm auto-collapse without waiting for a
    // mouse-move that may never come. `super.close()` orders the window out first,
    // so `isVisible` is already false when the controller re-evaluates.
    override func close() {
        super.close()
        onDismiss?()
    }

    private func rebuildContent() {
        let pad: CGFloat = 8
        let rowH: CGFloat = 32
        let headerH: CGFloat = 22
        let footerH: CGFloat = 22

        let content = NSVisualEffectView(frame: contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        content.material = .menu
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        let cornerR: CGFloat = 10
        content.layer?.cornerRadius = cornerR
        content.layer?.masksToBounds = true
        // The layer cornerRadius rounds the view's PIXELS, but the window's drop-shadow
        // reads the rectangular backing — so it drew square corners behind the rounded
        // panel (invalidateShadow just recomputes the same square). A resizable rounded
        // maskImage is the one thing the window-shadow machinery honours, so the shadow
        // follows the rounding.
        content.maskImage = Self.roundedMask(radius: cornerR)
        contentView = content

        let bounds = content.bounds

        // Loading: a centred spinner over a single "scanning" line, nothing else.
        if isLoading {
            let spin: CGFloat = 18
            let spinner = NSProgressIndicator(frame: NSRect(
                x: (bounds.width - spin) / 2, y: bounds.midY + 2, width: spin, height: spin))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            content.addSubview(spinner)

            let label = makeLabel("Scanning the menu bar\u{2026}", size: 11, colour: .secondaryLabelColor)
            label.alignment = .center
            label.frame = NSRect(x: pad, y: bounds.midY - 22, width: bounds.width - pad * 2, height: 16)
            content.addSubview(label)
            return
        }

        var y = bounds.height - pad

        if !items.isEmpty {
            let headerLabel = makeLabel(
                "Left-click to activate · right-click for the icon's menu",
                size: 11,
                colour: .secondaryLabelColor
            )
            headerLabel.frame = NSRect(x: pad, y: y - headerH, width: bounds.width - pad * 2, height: headerH)
            content.addSubview(headerLabel)
            y -= headerH
        }

        for item in items {
            y -= rowH
            let row = HiddenIconRow(item: item, panel: self)
            row.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: rowH)
            content.addSubview(row)
        }

        let footerText: String
        if !items.isEmpty {
            footerText = "\(items.count) icon\(items.count == 1 ? "" : "s") behind notch · Esc to close"
        } else if !axGranted {
            footerText = "Accessibility permission required — grant in Settings."
        } else {
            footerText = "No icons are currently hidden behind the notch."
        }
        let footer = makeLabel(footerText, size: 11, colour: .secondaryLabelColor)
        footer.alignment = .center
        footer.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: footerH)
        content.addSubview(footer)

        // The window drop-shadow is cached from the rectangular backing and is NOT
        // recomputed when the rounded content or the panel size changes — so it drew
        // SQUARE corners behind the rounded panel. Invalidate it once this layout has
        // rendered (so the rounded, transparent-cornered content is on screen) and
        // AppKit re-derives the shadow to hug the rounded shape.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    private func makeLabel(_ text: String, size: CGFloat, colour: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: size)
        f.textColor = colour
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    /// A resizable rounded-rect mask for the panel's NSVisualEffectView. Using this as
    /// the view's `maskImage` (not just a layer cornerRadius) is what makes the WINDOW's
    /// drop-shadow hug the rounded corners: the shadow follows the vibrancy view's
    /// reported mask, whereas a layer cornerRadius leaves the window shadow square. The
    /// cap-insets keep the corners crisp while the straight edges stretch to any size.
    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            close()
            return
        }
        super.keyDown(with: event)
    }

    func dismissAndClick(_ item: HiddenIcon, button: CGMouseButton) {
        // Close the panel first so it doesn't interfere with event routing
        // (especially for items whose AX frame falls behind the notch — the
        // panel must be out of the way before we post events).
        close()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            HiddenIcons.send(button: button, to: item)
        }
    }
}

extension HiddenIcons {
    /// Activates a hidden status item.
    ///
    /// Why this is gnarly: the icon is geometrically positioned in the notch
    /// region of the menu bar, where macOS's hardware clip hides it. Synthetic
    /// CGEvent clicks posted at that coordinate go nowhere — the notch has no
    /// hit-test target, even though the status item logically lives there.
    /// AX bypasses hit-testing entirely, so `AXPress` is the only reliable way
    /// to make the click register on a behind-notch item.
    ///
    /// Cursor warp before AXPress: once the menu opens, NSStatusItem-managed
    /// menus track mouse position relative to the icon's button. If the cursor
    /// is far away (the user clicked our reveal panel mid-screen), the very
    /// first mouseMoved event reads as "moved off the icon" and the menu
    /// dismisses. Pre-warping the cursor onto the icon means the menu opens
    /// with the cursor already over its anchor — subsequent physical movement
    /// reads as natural drag-down navigation.
    static func send(button: CGMouseButton, to item: HiddenIcon) {
        let iconPoint = CGPoint(x: item.frame.midX, y: item.frame.midY)

        // Park cursor on the icon before any action so the menu opens with a
        // consistent tracking origin.
        CGWarpMouseCursorPosition(iconPoint)

        if button == .left {
            // AXPress bypasses hit-testing, so it's the reliable path for a
            // behind-notch item. But on macOS 26 (Tahoe) the *first* press to
            // another app's menu-bar extra often returns kAXErrorCannotComplete
            // — the AX messaging channel to that app is cold — and the click
            // silently does nothing (issue #3). Bound each attempt with a short
            // timeout and retry until the channel warms (usually the 2nd try).
            AXUIElementSetMessagingTimeout(item.axElement, 1.0)
            var errs: [Int32] = []
            var err = AXUIElementPerformAction(item.axElement, kAXPressAction as CFString)
            errs.append(err.rawValue)
            var tries = 1
            while err == .cannotComplete && tries < 4 {
                usleep(120_000)   // 120 ms breather between tries
                err = AXUIElementPerformAction(item.axElement, kAXPressAction as CFString)
                errs.append(err.rawValue)
                tries += 1
            }
            MTDebug.log("send left '\(item.appName)' AXPress=\(errs)")
            return
        }

        MTDebug.log("send right '\(item.appName)'")

        // Right-click — apps that distinguish use a separate right-click handler.
        // AX has no standard "right-press" action, so synthesise it via CGEvent.
        // For items behind the notch this may not register on apps that rely on
        // hit-testing; for visible items it works as expected.
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: iconPoint, mouseButton: .right)
        let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: iconPoint, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Hidden-Icons Row View

final class HiddenIconRow: NSView {

    private let item: HiddenIcon
    private weak var panel: HiddenIconsPanel?
    private var isHovered = false

    init(item: HiddenIcon, panel: HiddenIconsPanel) {
        self.item = item
        self.panel = panel
        super.init(frame: .zero)

        let icon = NSImageView(frame: NSRect(x: 6, y: 4, width: 24, height: 24))
        icon.image = item.appIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let label = NSTextField(labelWithString: item.appName)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 38, y: (item.title?.isEmpty == false ? 14 : 8), width: 220, height: 16)
        addSubview(label)

        if let subtitle = item.title, !subtitle.isEmpty {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 10)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.frame = NSRect(x: 38, y: 0, width: 220, height: 12)
            addSubview(sub)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        panel?.dismissAndClick(item, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        panel?.dismissAndClick(item, button: .right)
    }
}

// MARK: - Main

// Holder mode. Started by our own `collapse()` as a separate process, never by
// the user. It applies the restriction, then does nothing but stay alive.
//
// Why a second process rather than just calling invalidate(): **invalidate()
// does not undo assessment mode.** Proven 2026-09-20 on 27.0 (26A428) by
// controlled experiment — a process that has never restricted leaves
// Notification Centre working; one collapse and expand kills it and it stays
// dead while expanded, unrestricted, for the life of the process. Only the
// process exiting restores it. Wi-Fi and Control Centre are unaffected
// throughout, which is what identifies the residue as assessment mode's own
// notification suppression rather than anything geometric.
//
// The framework offers no other inverse: `dyld_info -exports` shows
// MBAssessmentModeAssertion has exactly activate(completionHandler:),
// activate(with:completionHandler:) and invalidate(). So the only complete
// release available is process death, and this makes that a thing MenuTidy can
// do on demand instead of something that needs the user to quit the app.
//
// Verified end to end with a standalone build of exactly this code path: no
// restriction, clock works; assertion held in a separate process, clock dead;
// that process killed, clock works again.
if let holderIndex = CommandLine.arguments.firstIndex(of: MenuBarRestriction.holderFlag) {
    let keep = Array(CommandLine.arguments.dropFirst(holderIndex + 1))
    MenuBarRestriction.runAsHolder(keeping: keep)
    // runAsHolder never returns.
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
