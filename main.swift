import Cocoa
import ServiceManagement
import SwiftUI

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var chevronItem: NSStatusItem!
    var spacerItem: NSStatusItem!
    var cmdMonitor: Any?

    var isCollapsed = false
    private let hasLaunchedBeforeKey = "MenuTidy_HasLaunchedBefore"
    private var aboutPopover: NSPopover?
    private var aboutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItems()
        setupCmdKeyMonitor()

        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: hasLaunchedBeforeKey)
        if hasLaunchedBefore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.collapse()
            }
        } else {
            UserDefaults.standard.set(true, forKey: hasLaunchedBeforeKey)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        expand()
    }

    // MARK: Status Items

    func setupStatusItems() {
        // Preferred positions: lower number = further right.
        // Chevron at 150 = near system items (rightmost of our items)
        // Spacer at 300 = among third-party items (further left)
        // This puts the layout as:
        //   [third-party items ~315] [spacer ~300] [chevron ~150] [system ~139]
        // When spacer expands, items to its left overflow. Chevron survives.

        UserDefaults.standard.set(150, forKey: "NSStatusItem Preferred Position MenuTidyChevron")
        UserDefaults.standard.set(300, forKey: "NSStatusItem Preferred Position MenuTidySpacer")

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
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MenuTidy")
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
            let screenRight = NSScreen.main?.frame.maxX ?? 2560
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
        guard let button = chevronItem.button else { return }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = true
        let hc = NSHostingController(rootView: AboutView(appName: "MenuTidy", onDismiss: { [weak self] in self?.closeAbout() }))
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        p.contentViewController = hc
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        aboutPopover = p
        aboutMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeAbout()
        }
    }

    func closeAbout() {
        aboutPopover?.performClose(nil)
        aboutPopover = nil
        if let m = aboutMonitor { NSEvent.removeMonitor(m); aboutMonitor = nil }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(title: "About MenuTidy", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())

        let tip = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        tip.attributedTitle = NSAttributedString(
            string: "⌘+drag icons to the right of the\nspacer to keep them always visible",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        menu.addItem(tip)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit MenuTidy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        return menu
    }

    @objc func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {}
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
