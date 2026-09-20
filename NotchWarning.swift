import AppKit
import SwiftUI

/// A short message that drops out of the notch and takes itself away again.
///
/// ## Why this is not a system notification
///
/// MenuTidy asks for no notification permission and this is not worth asking
/// for one: the user would meet a permission prompt on first launch in exchange
/// for a warning they may never need. A panel of our own needs no permission,
/// appears in the part of the screen the message is actually about, and cannot
/// pile up in Notification Centre.
///
/// ## Why this is not RMW's pill
///
/// RememberMyWindows has one of these and it looks the part, but it is wired
/// into that app: it asks `WindowManager.shared.isScreenLocked`, reads RMW's
/// own `ThemeColor` setting, and carries a subtitle badge that only ever shows
/// `fn` or the caps lock symbol. Lifting it out is a refactor of RMW rather
/// than a copy, so this is a small independent one. If a third app wants a
/// notch pill, that is the moment to extract a shared one covering all three.
/// The geometry rules below are the part worth agreeing on, and they follow
/// RMW's, which were established by looking at a real screen.
enum NotchWarning {

    /// Show `title` over `detail`. Replaces any pill already on screen.
    static func show(title: String, detail: String) {
        guard !screenIsLocked else { return }
        current?.dismissNow()
        let panel = NotchWarningPanel(title: title, detail: detail)
        current = panel
        panel.present()
    }

    private static var current: NotchWarningPanel?

    /// Never draw over the lock screen. A pill there would sit on top of the
    /// login UI with no way for anyone to dismiss it.
    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}

// MARK: - Geometry

/// The screen with the notch, or the built-in one, or failing both the main one.
///
/// The pill hangs from the notch, so it belongs on the display that has one. A
/// Mac with no notch at all still gets a pill; it simply hangs from the top
/// centre of the built-in screen instead, which is where a notch would be.
private func builtInScreen() -> NSScreen {
    if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
        return notched
    }
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { continue }
        if CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 { return screen }
    }
    return NSScreen.main ?? NSScreen.screens[0]
}

/// Width of the hardware notch in points, or 0 on a display without one.
///
/// The two auxiliary areas are the strips of menu bar either side of the
/// cutout, so the gap between them is the cutout. Read rather than hardcoded:
/// it differs between models and changes with the display mode.
private func notchWidth(of screen: NSScreen) -> CGFloat {
    guard let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea else { return 0 }
    return max(0, right.minX - left.maxX)
}

/// How far the pill must reach past the notch on each side.
///
/// Matching the notch exactly is not enough. `auxiliaryTopLeftArea` gives the
/// *layout* boundary beside the cutout, but the cutout is a physical hole:
/// those pixels are in the framebuffer and behind the camera housing, so nobody
/// ever sees them. A pill exactly notch-wide puts its two vertical edges where
/// they cannot be seen and reads as unbordered. A screenshot cannot show you
/// this, because the framebuffer has the edges even when the glass does not.
///
/// There is no API for the physical cutout, so this cannot be derived. It is a
/// knob, carrying the value RMW settled on by looking at a real 14-inch
/// MacBook Pro:
///
///     defaults write cc.jorviksoftware.MenuTidy notchClearance -float 8
private func notchClearance() -> CGFloat {
    guard UserDefaults.standard.object(forKey: "notchClearance") != nil else { return 6 }
    return max(0, CGFloat(UserDefaults.standard.double(forKey: "notchClearance")))
}

// MARK: - The panel

private final class NotchWarningPanel: NSPanel {

    // Named `headline`/`subtext` rather than `title`/`detail` because NSWindow
    // already has a `title`, and a stored property cannot override it.
    private let headline: String
    private let subtext: String
    private let pillWidth: CGFloat
    private let pillHeight: CGFloat
    private let notchDepth: CGFloat
    private var timer: Timer?

    /// How long the pill stays before it removes itself.
    private static let dwell: TimeInterval = 5.0
    /// Length of the fade, used on the way in and the way out.
    private static let fade: TimeInterval = 0.25

    init(title: String, detail: String) {
        self.headline = title
        self.subtext = detail

        let screen = builtInScreen()
        // A menu bar with no safe area still has a height; 24 is the classic
        // one and is only reached on a Mac with no notch.
        self.notchDepth = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        self.pillHeight = notchDepth + 44

        // Wide enough for the words, and never narrower than the notch plus its
        // clearance, or the edges vanish behind the camera housing.
        let widest = max(Self.drawnWidth(title, size: 13, weight: .semibold),
                         Self.drawnWidth(detail, size: 11, weight: .regular))
        // `title`/`detail` are the initialiser's arguments here, not the
        // properties; the properties are set above.
        let intrinsic = widest + 28 * 2
        let notch = notchWidth(of: screen)
        self.pillWidth = max(intrinsic, notch > 0 ? notch + notchClearance() * 2 : 0)

        super.init(contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        // Above the menu bar, which on macOS 27 is a single Window Server
        // window rather than one window per item.
        level = NSWindow.Level(Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    private static func drawnWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    func present() {
        let screen = builtInScreen()
        let frame = screen.frame
        setFrame(NSRect(x: frame.midX - pillWidth / 2,
                        y: frame.maxY - pillHeight,
                        width: pillWidth,
                        height: pillHeight),
                 display: true)

        let hosting = NSHostingView(rootView: NotchWarningView(title: headline,
                                                              detail: subtext,
                                                              notchDepth: notchDepth))
        hosting.frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        hosting.autoresizingMask = [NSView.AutoresizingMask.width, .height]
        contentView = hosting

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            animator().alphaValue = 1
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.dwell, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        timer?.invalidate(); timer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.close()
        })
    }

    /// Go at once, with no fade. Used when a second pill replaces this one.
    func dismissNow() {
        timer?.invalidate(); timer = nil
        close()
    }
}

// MARK: - The view

private struct NotchWarningView: View {
    let title: String
    let detail: String
    let notchDepth: CGFloat

    var body: some View {
        // Square at the top so it merges with the notch, rounded below so it
        // reads as hanging from it.
        UnevenRoundedRectangle(topLeadingRadius: 0,
                               bottomLeadingRadius: 14,
                               bottomTrailingRadius: 14,
                               topTrailingRadius: 0)
            .fill(Color.black)
            .overlay(alignment: .bottom) {
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.bottom, 10)
            }
            .ignoresSafeArea()
    }
}
