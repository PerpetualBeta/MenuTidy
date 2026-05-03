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

        // Prefer the cache for instant open. But if the cache is empty,
        // detect synchronously — covers the case where the cache was first
        // populated before AX was granted (stale-empty), or where macOS has
        // just placed an app behind the notch since the last NSWorkspace
        // event fired. Cheap when there's genuinely nothing clipped.
        var items = HiddenIcons.cached
        if items.isEmpty && axGranted {
            items = HiddenIcons.detectClipped()
        }
        HiddenIcons.refreshAsync()

        let panel = HiddenIconsPanel(items: items, axGranted: axGranted)
        panel.anchor(to: chevronItem)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        revealPanel = panel
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

    static var cached: [HiddenIcon] {
        cacheQueue.sync { _cached }
    }

    /// Idempotent. Wires up event-driven refresh and triggers an initial fetch.
    static func startCaching() {
        guard !cachingStarted else { return }
        cachingStarted = true

        lastAXTrusted = AXIsProcessTrusted()
        refreshAsync()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Small delay so the launching app has time to create its status item.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refreshAsync() }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshAsync() }
        }

        // macOS doesn't fire a notification when AX permission changes, so
        // poll. Cheap (one syscall every few seconds), and only matters until
        // the user grants AX once — after that the polled value never flips
        // back unless they revoke. On any flip false→true we kick a fresh
        // detect so the panel sees real data on its next open.
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let now = AXIsProcessTrusted()
            if now != lastAXTrusted {
                lastAXTrusted = now
                if now { refreshAsync() }
            }
        }
    }

    /// Schedules a background re-detect and updates the cache when done.
    static func refreshAsync() {
        DispatchQueue.global(qos: .utility).async {
            let items = detectClipped()
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

    /// Walks every running app's `AXExtrasMenuBar` and returns only the status
    /// items whose logical X centre falls inside the notch's horizontal range
    /// — i.e. the ones the menu bar can't render because the notch is there.
    static func detectClipped() -> [HiddenIcon] {
        guard let notchRange = notchHorizontalRange() else { return [] }
        var result: [HiddenIcon] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited else { continue }
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let appEl = AXUIElementCreateApplication(pid)
            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
                  let extras = extrasRef else { continue }
            let extrasEl = extras as! AXUIElement

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(extrasEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let items = childrenRef as? [AXUIElement] else { continue }

            for item in items {
                let frame = axFrame(of: item)
                // Require a real, rendered frame whose X centre falls inside
                // the notch. Items with zero-size frames are AX entries that
                // don't correspond to a rendered menu bar icon (Control Centre
                // exposes many of these as internal children) — including them
                // floods the panel with phantom entries.
                guard frame.width > 0, frame.height > 0 else { continue }
                guard notchRange.contains(frame.midX) else { continue }

                let title = axString(of: item, attribute: kAXTitleAttribute as CFString)
                result.append(HiddenIcon(
                    appName: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    appIcon: app.icon,
                    title: title,
                    frame: frame,
                    axElement: item
                ))
            }
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

    private let items: [HiddenIcon]
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
