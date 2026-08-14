import AppKit
import ApplicationServices
import SwiftUI

/// Keeps a TCC permission's state current in a Settings window, so granting it in
/// System Settings is reflected without the window being closed and reopened.
///
/// Every Jorvik app that shows a permission row had the same fault: the state was read
/// once — as the view appeared, or worse, inline in `body` where nothing ever caused a
/// re-render — so a user who granted the permission went on being told to grant it. That
/// reads as a failure of the app, and it is the single most common thing anyone reports
/// about a permission row.
///
/// Getting this right took three separate discoveries, all measured on Save Cannes on
/// 2026-08-14. They are written down here because none of them is guessable and every one
/// of them will otherwise be rediscovered the hard way.
///
/// ## 1. There is a system announcement, and it is easy to conclude wrongly that there is not
///
/// macOS posts `com.apple.accessibility.api` on the **distributed** centre when the
/// Accessibility trust state changes. Observing it with a Combine publisher appeared to do
/// nothing at all: the grant was recorded at 11:43:26 and the row only caught up at
/// 11:43:47, twenty-one seconds later, when the app was brought back to the front.
///
/// That is not evidence the announcement never arrived. A distributed observer defaults to
/// `NSNotificationSuspensionBehavior.coalesce`, which **holds notifications while the app
/// is inactive** and delivers them when it next becomes active — and System Settings is
/// necessarily frontmost at the moment the switch is flipped. So "posted but held" and
/// "never posted" produce precisely the same gap, closing only when you click back.
///
/// Hence `.deliverImmediately`, and hence a target/selector registration: the
/// `DistributedNotificationCenter.publisher(for:)` API **cannot express suspension
/// behaviour**, so `.onReceive` cannot fix this no matter how it is arranged.
///
/// ## 2. The check is cached in the process, and the announcement invalidates that cache
///
/// This is the one that looks like a logic error and is not. `AXIsProcessTrusted()` is
/// cached; the announcement invalidates the cache; **the first read afterwards is the one
/// that refetches, and every read after it inherits that answer.** The announcement
/// arrives *before* `tccd` has committed the new value, so a read taken on the spot
/// refetches the OLD answer and pins it there until the next announcement.
///
/// Measured: the switch went on at 12:23:43, a read at 12:23:43.716 returned false, and
/// **ninety-six further reads over the next seventy seconds all returned false** while the
/// system's own record said allowed. The row tracked every toggle but showed the previous
/// one — indistinguishable from inverted `if` branches.
///
/// So **reading more often makes it worse**: any read can be the one that pins a stale
/// answer. On an announcement this takes no read at all — it holds every read off for
/// `commitSeconds` and then takes exactly one.
///
/// ## 3. Two theories that are wrong, so nobody re-derives them
///
/// - *A rebuild invalidates the grant.* It does not. The stored requirement is
///   `identifier` + `anchor apple generic` + team OU, with **no cdhash**, so re-signing is
///   irrelevant. (`csreq -t -r- < blob` against `codesign -d -r-` to confirm.)
/// - *A process that has had the permission revoked under it can never regain it.* It can,
///   repeatedly — one process was logged alternating granted and revoked six times. What
///   looked like permanence was only the stale cached answer above.
///
/// ## Adoption
///
/// ```swift
/// @StateObject private var accessibility = JorvikPermissionWatcher.accessibility()
///
/// // in the row
/// if accessibility.isGranted { Label("Granted", systemImage: "checkmark.circle.fill") }
/// else { Button("Grant Access") { JorvikPermissionWatcher.promptForAccessibility() } }
/// ```
///
/// Nothing runs unless a watcher exists, so this costs nothing while Settings is closed.
public final class JorvikPermissionWatcher: NSObject, ObservableObject {

    /// Whether the permission is currently granted.
    @Published public private(set) var isGranted: Bool

    /// How often the state is re-read while the watcher is alive. The checks are all cheap
    /// lookups, and this only runs while a Settings window is open.
    public static let pollSeconds: TimeInterval = 1

    /// How long to stop reading for after a system announcement, so nothing races the
    /// commit and pins a stale answer. See the note above — this is the whole trick.
    public static let commitSeconds: TimeInterval = 1.5

    /// Posted by macOS when the Accessibility API's trust state changes. Long-standing,
    /// but undocumented, which is why a poll backs it up rather than replacing it.
    public static let accessibilityAnnouncement = Notification.Name("com.apple.accessibility.api")

    private let check: () -> Bool
    private let announcement: Notification.Name?
    private var poll: Timer?
    private var quietUntil: Date = .distantPast

    /// - Parameters:
    ///   - announcement: a distributed notification that signals this permission may have
    ///     changed, if one exists. Only Accessibility has one; for everything else the
    ///     poll and returning to the app do the work.
    ///   - check: reads the current state. Must be cheap — it is called once a second.
    public init(announcement: Notification.Name? = nil, check: @escaping () -> Bool) {
        self.check = check
        self.announcement = announcement
        self.isGranted = check()
        super.init()

        if let announcement {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(announced), name: announcement, object: nil,
                suspensionBehavior: .deliverImmediately)
        }
        // Returning to the app covers the ordinary route, since granting a permission means
        // bringing System Settings to the front and coming back.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reactivated),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // And the poll covers the case that is actually complained about: both windows
        // visible at once, where the app never goes inactive and so nothing tells it
        // anything. Scheduled in the common modes so tracking a menu cannot stall it.
        let timer = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            self?.reread()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    deinit {
        poll?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// Re-read now, unless a change is still settling.
    public func reread() {
        if Date() < quietUntil { return }
        let now = check()
        if now != isGranted { isGranted = now }
    }

    @objc private func announced() {
        // Deliberately no read here: the announcement means the cached answer is about to
        // become wrong, not that the new one is available yet.
        quietUntil = Date().addingTimeInterval(Self.commitSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitSeconds) { [weak self] in
            guard let self else { return }
            self.quietUntil = .distantPast
            self.reread()
        }
    }

    @objc private func reactivated() { reread() }

    // MARK: - The permissions Jorvik apps actually ask for

    /// Accessibility — the only one with a system announcement.
    public static func accessibility() -> JorvikPermissionWatcher {
        JorvikPermissionWatcher(announcement: accessibilityAnnouncement) { AXIsProcessTrusted() }
    }

    /// Screen Recording. No announcement exists for it, so the poll is what makes the row
    /// correct rather than a backstop.
    public static func screenRecording() -> JorvikPermissionWatcher {
        JorvikPermissionWatcher { CGPreflightScreenCaptureAccess() }
    }

    // Input Monitoring and camera/microphone deliberately have no convenience constructor
    // here. They would need `IOKit.hid` and `AVFoundation`, and this file is vendored into
    // apps that link neither — an import they cannot satisfy would break their build for
    // the sake of one line. Those apps pass their own closure instead:
    //
    //     JorvikPermissionWatcher { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    //                               == kIOHIDAccessTypeGranted }
    //     JorvikPermissionWatcher { AVCaptureDevice.authorizationStatus(for: .video)
    //                               == .authorized }
    //
    // Everything above works with AppKit and ApplicationServices alone, which every Jorvik
    // app already links.

    // MARK: - Asking for it

    /// Show the system's Accessibility prompt, which also adds the app to the list.
    @discardableResult
    public static func promptForAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open a specific pane of System Settings' Privacy & Security section.
    ///
    /// Worth having because the prompt only appears once per app: a user who dismissed it
    /// has no way back except being taken there.
    public static func openSettings(pane: Pane) {
        guard let url = URL(string: pane.rawValue) else { return }
        NSWorkspace.shared.open(url)
    }

    public enum Pane: String {
        case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case camera = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    }
}
