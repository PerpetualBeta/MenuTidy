import Cocoa
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
    static let enabled = UserDefaults.standard.bool(forKey: "debugLogging")

    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MenuTidy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("menutidy.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    private static let lock = NSLock()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled, let handle else { return }
        let line = message() + "\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        handle.write(data)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var chevronItem: NSStatusItem!
    var spacerItem: NSStatusItem!
    var cmdMonitor: Any?
    var mouseMonitor: Any?
    var spacerVisible = false
    var revealPanel: HiddenIconsPanel?
    // Captured when the right-click menu is built: opening that menu dismisses
    // the panel (resignKey) before the menu item fires, so we can't ask the live
    // panel whether it was open — we decide the toggle from this snapshot.
    var revealPanelWasOpenAtMenuInvoke = false

    // Auto-collapse (opt-in). When enabled, the bar tidies itself a short delay
    // after the pointer leaves the menu-bar vicinity, so an expand-to-peek
    // doesn't leave the bar open indefinitely. Config is read once at launch
    // (see applicationDidFinishLaunching), matching the debugLogging flag.
    var autoCollapseMouseMonitor: Any?
    var autoCollapsePending: DispatchWorkItem?
    private var autoCollapseEnabled = false
    private var autoCollapseDelay: TimeInterval = 2   // "a couple of seconds"

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

        // Auto-collapse config (opt-in, off by default). Enable per-machine:
        //   defaults write cc.jorviksoftware.MenuTidy autoCollapse -bool YES
        // Optionally tune the delay in seconds (default 2):
        //   defaults write cc.jorviksoftware.MenuTidy autoCollapseDelay -int 3
        // Read once here so the pointer-tracking hot path stays free of
        // UserDefaults lookups; a change takes effect on the next launch.
        autoCollapseEnabled = UserDefaults.standard.bool(forKey: "autoCollapse")
        let configuredDelay = UserDefaults.standard.double(forKey: "autoCollapseDelay")
        if configuredDelay > 0 { autoCollapseDelay = configuredDelay }

        setupStatusItems()
        setupCmdKeyMonitor()

        // Pre-warm the hidden-icons cache so opening the reveal panel is
        // instant. Only meaningful on notched displays — gated to avoid
        // pointless AX work elsewhere.
        if HiddenIcons.notchHorizontalRange() != nil {
            HiddenIcons.startCaching()
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

        // Create spacer second (to the left, among third-party items)
        spacerItem = NSStatusBar.system.statusItem(withLength: 0)
        spacerItem.autosaveName = "MenuTidySpacer"
    }

    // MARK: ⌘ Key Monitor

    func setupCmdKeyMonitor() {
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
        guard !isCollapsed, !spacerVisible else { return }
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
        guard !isCollapsed else { return }
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
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
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
                self.collapse()
            }
            autoCollapsePending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoCollapseDelay, execute: work)
        }
    }

    // MARK: Collapse / Expand

    func collapse() {
        isCollapsed = true
        stopAutoCollapseTracking()
        // Collapsing hides the very icons a Reveal panel is listing, so dismiss
        // it. Auto-collapse never fires while the panel is open (see
        // evaluateAutoCollapse), so in practice this only runs on a manual
        // collapse — clicking the chevron while Reveal is up.
        revealPanel?.close()
        revealPanel = nil
        spacerItem.length = 10_000
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
        spacerItem.length = 0
        updateIcon()
        if startTracking {
            startAutoCollapseTracking()
        }
    }

    // MARK: Menu

    func showMenu() {
        // Snapshot the panel's open state *before* performClick opens the menu
        // (which dismisses the panel), so revealHiddenIcons() can toggle it off.
        revealPanelWasOpenAtMenuInvoke = (revealPanel?.isVisible == true)
        let menu = buildMenu()
        chevronItem.menu = menu
        chevronItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.chevronItem.menu = nil
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
            MenuTidySettingsContent { self?.updateIcon() }
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

        var actions: [JorvikMenuBuilder.ActionItem] = [tip]

        // Only offer the reveal action on notched displays, and only while the
        // bar is expanded — when collapsed, every third-party icon is shoved
        // off-screen to the spacer sentinel (~-4400), so there's nothing
        // meaningful to reveal or activate.
        if HiddenIcons.notchHorizontalRange() != nil && !isCollapsed {
            actions.append(.init(title: "-", action: #selector(NSObject.description), target: self))
            actions.append(.init(
                title: "Reveal Hidden Icons\u{2026}",
                action: #selector(revealHiddenIcons),
                target: self
            ))
        }

        actions.append(.init(title: "-", action: #selector(NSObject.description), target: self))
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

        MTDebug.log("--- walk (\(isFullWalk ? "full" : "fast")) notch=\(notchRange.lowerBound)...\(notchRange.upperBound) screenMaxX=\(screenMaxX) ---")

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
                let visibleRightOfNotch = frame.minX >= notchRange.upperBound && frame.minX < screenMaxX
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
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
