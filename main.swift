import Cocoa
import ServiceManagement
import SwiftUI
import ApplicationServices

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var chevronItem: NSStatusItem!
    var spacerItem: NSStatusItem!
    var cmdMonitor: Any?
    var revealPanel: HiddenIconsPanel?

    var isCollapsed = false
    private let hasLaunchedBeforeKey = "MenuTidy_HasLaunchedBefore"
    private let didSeedDefaultPositionsKey = "MenuTidy_DidSeedDefaultPositions"
    let updateChecker = JorvikUpdateChecker(repoName: "MenuTidy")

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyPillColorKey()

        setupStatusItems()
        setupCmdKeyMonitor()
        updateChecker.checkOnSchedule()

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
        expand()
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
            let cmdPressed = event.modifierFlags.contains(.command)
            if cmdPressed {
                self.showSpacer()
            } else {
                self.hideSpacer()
            }
        }
    }

    func showSpacer() {
        guard !isCollapsed else { return }
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

    // MARK: Collapse / Expand

    func collapse() {
        isCollapsed = true
        spacerItem.length = 10_000
        updateIcon()

        // Safety: if the chevron got pushed off-screen, undo immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard let window = self.chevronItem.button?.window else {
                self.expand()
                return
            }
            let frame = window.frame
            // Chevron is off-screen if it's been pushed past the left edge
            // or squeezed to nothing
            if frame.width < 5 || frame.maxX < 50 || frame.minX < 0 {
                self.expand()
            }
        }
    }

    func expand() {
        isCollapsed = false
        spacerItem.length = 0
        updateIcon()
    }

    // MARK: Menu

    func showMenu() {
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

    @objc func openSettings() {
        JorvikSettingsView.showWindow(
            appName: "MenuTidy",
            updateChecker: updateChecker
        ) { [weak self] in
            MenuTidySettingsContent { self?.updateIcon() }
        }
    }

    @objc func revealHiddenIcons() {
        if revealPanel?.isVisible == true {
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

        // Show the cached snapshot for an instant open, but kick off a fresh
        // detect immediately and update the panel's content in place when it
        // completes. Covers the case where the cache was populated during
        // initial menu bar reflow (and so missed icons that drifted into the
        // notch a moment later) without making the user wait.
        var items = HiddenIcons.cached
        HiddenIcons.log("revealHiddenIcons: AX granted=\(axGranted), cache count=\(items.count)")
        if items.isEmpty && axGranted {
            HiddenIcons.log("revealHiddenIcons: cache empty + AX granted → synchronous detect")
            items = HiddenIcons.detectClipped()
            HiddenIcons.log("revealHiddenIcons: synchronous detect returned \(items.count) item(s)")
        }

        let panel = HiddenIconsPanel(items: items, axGranted: axGranted)
        panel.anchor(to: chevronItem)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        revealPanel = panel

        // Live-update the panel with the post-refresh list. If items differ
        // (count or membership), rebuild — common when the menu bar has
        // shifted between cache time and panel open.
        HiddenIcons.refreshAsync { [weak panel] fresh in
            guard let panel, panel.isVisible else { return }
            HiddenIcons.log("revealHiddenIcons: live update — fresh count=\(fresh.count) (was \(items.count))")
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

        // Only offer the reveal action on notched displays — pointless otherwise.
        if HiddenIcons.notchHorizontalRange() != nil {
            actions.append(.init(title: "-", action: #selector(NSObject.description), target: self))
            actions.append(.init(
                title: "Reveal Hidden Icons\u{2026}",
                action: #selector(revealHiddenIcons),
                target: self
            ))
        }

        return JorvikMenuBuilder.buildMenu(
            appName: "MenuTidy",
            aboutAction: #selector(openAbout),
            settingsAction: #selector(openSettings),
            target: self,
            actions: actions
        )
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

    // MARK: Diagnostic logging
    //
    // Writes to /tmp/menutidy.log (never Console). Tail with:
    //     tail -f /tmp/menutidy.log

    private static let logPath = "/tmp/menutidy.log"

    static func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data, attributes: nil)
        }
    }

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
        log("startCaching: initial AX trusted = \(lastAXTrusted)")
        refreshAsyncFull()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            // The new app might be a status-item host. Small delay so it has
            // time to create its NSStatusItem; full walk picks it up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refreshAsyncFull() }
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
                log("AX state flip: \(lastAXTrusted) → \(now)")
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
    static func refreshAsyncFull() {
        DispatchQueue.global(qos: .utility).async {
            let items = detectClippedFull()
            cacheQueue.sync { _cached = items }
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
    /// results under a single NSLock. Logs per-clipped-item after the
    /// parallel section so log lines stay readable rather than interleaved.
    /// On a full walk, also rebuilds the host-PID cache from the apps that
    /// returned a non-nil AXExtrasMenuBar.
    private static func walk(candidates: [NSRunningApplication], isFullWalk: Bool) -> [HiddenIcon] {
        let started = Date()
        let trusted = AXIsProcessTrusted()
        guard let notchRange = notchHorizontalRange() else {
            log("detect: no notch range — skipping (AX trusted: \(trusted))")
            return []
        }

        let walkType = isFullWalk ? "full" : "fast"
        log("detect (\(walkType)): notch X range = \(notchRange.lowerBound)…\(notchRange.upperBound)  AX trusted = \(trusted)  candidates = \(candidates.count)")

        let lock = NSLock()
        var result: [HiddenIcon] = []
        var hostsFound: Set<pid_t> = []
        var totalItems = 0

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
                // Require a real, rendered frame, then check horizontal overlap
                // with the notch — any pixel of the icon's frame inside the
                // notch range counts as clipped (catches partial-overlap cases
                // like HyperCaps straddling the notch's right edge).
                guard frame.width > 0, frame.height > 0 else { continue }
                // Sanity check: real menu bar status items are 20–60pt wide.
                // AX occasionally returns bogus aggregate frames (Control Centre
                // reports a 5016pt-wide rect when MenuTidy's spacer expands to
                // 10000pt and the menu bar geometry is unusual). Anything
                // wider than the notch itself can't be a partially-clipped
                // status item — it's a misreported aggregate.
                guard frame.width <= 200 else { continue }
                guard frame.maxX > notchRange.lowerBound, frame.minX < notchRange.upperBound else { continue }

                let title = axString(of: item, attribute: kAXTitleAttribute as CFString)
                let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
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
            totalItems += items.count
            result.append(contentsOf: localClipped)
            lock.unlock()
        }

        // After a full walk, the hostsFound set IS the new cache. After a
        // fast walk, hostsFound is a subset of the cache (apps still hosting
        // extras); we don't update the cache here — stale PIDs cost ~25 ms
        // per fast refresh, and they're trimmed on app-terminate notifications.
        if isFullWalk {
            setHostPIDs(hostsFound)
        }

        for clipped in result {
            log("detect:   CLIPPED  \(clipped.appName)  frame=\(clipped.frame)")
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        log("detect (\(walkType)): walked \(candidates.count) apps, \(hostsFound.count) had extras, \(totalItems) total items, \(result.count) clipped — \(elapsed)ms")

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

    private var items: [HiddenIcon]
    private let axGranted: Bool

    init(items: [HiddenIcon], axGranted: Bool) {
        self.items = items
        self.axGranted = axGranted
        let rowH: CGFloat = 32
        let pad: CGFloat = 8
        let headerH: CGFloat = items.isEmpty ? 0 : 22
        let footerH: CGFloat = 22
        let height = pad * 2 + headerH + CGFloat(items.count) * rowH + footerH
        let frame = NSRect(x: 0, y: 0, width: 320, height: max(height, 80))
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
        buildContent(rowHeight: rowH, padding: pad, headerHeight: headerH, footerHeight: footerH)
    }

    func anchor(to statusItem: NSStatusItem) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame
        let originX = buttonFrame.midX - frame.width / 2
        let originY = buttonFrame.minY - frame.height - 4
        setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    /// Replace the panel's content with a fresh list. Called by the
    /// live-update path after a background refresh discovers items that
    /// the cache snapshot at open time didn't have.
    func updateItems(_ newItems: [HiddenIcon]) {
        // No-op if identical — avoids needless rebuild flicker.
        let oldKeys = items.map { "\($0.appName)|\(Int($0.frame.minX))" }
        let newKeys = newItems.map { "\($0.appName)|\(Int($0.frame.minX))" }
        guard oldKeys != newKeys else { return }
        items = newItems

        // Resize to fit and rebuild content. setFrame with display:true
        // resizes contentView synchronously so buildContent's NSVisualEffectView
        // gets the right bounds.
        let rowH: CGFloat = 32
        let pad: CGFloat = 8
        let headerH: CGFloat = items.isEmpty ? 0 : 22
        let footerH: CGFloat = 22
        let height = pad * 2 + headerH + CGFloat(items.count) * rowH + footerH
        var f = frame
        let oldHeight = f.height
        f.size.height = max(height, 80)
        f.origin.y += oldHeight - f.size.height  // keep top edge anchored
        setFrame(f, display: true)
        buildContent(rowHeight: rowH, padding: pad, headerHeight: headerH, footerHeight: footerH)
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        // Dismiss when the user clicks anywhere else.
        DispatchQueue.main.async { [weak self] in
            self?.close()
        }
    }

    private func buildContent(rowHeight: CGFloat, padding: CGFloat, headerHeight: CGFloat, footerHeight: CGFloat) {
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
        var y = bounds.height - padding

        if !items.isEmpty {
            let headerLabel = makeLabel(
                "Left-click to activate · right-click for the icon's menu",
                size: 11,
                colour: .secondaryLabelColor
            )
            headerLabel.frame = NSRect(x: padding, y: y - headerHeight, width: bounds.width - padding * 2, height: headerHeight)
            content.addSubview(headerLabel)
            y -= headerHeight
        }

        for item in items {
            y -= rowHeight
            let row = HiddenIconRow(item: item, panel: self)
            row.frame = NSRect(x: padding, y: y, width: bounds.width - padding * 2, height: rowHeight)
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
        footer.frame = NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: footerHeight)
        content.addSubview(footer)
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
            // AXPress reliably opens the menu (or fires the primary action) on
            // every NSStatusItem regardless of hit-test geometry. Best path
            // for left-click on hidden items.
            AXUIElementPerformAction(item.axElement, kAXPressAction as CFString)
            return
        }

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
