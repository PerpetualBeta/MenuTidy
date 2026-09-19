import AppKit
import ApplicationServices

/// Works out which apps own menu bar items and where those items sit.
///
/// On macOS 27 a status item has no window of its own, so the old trick of
/// reading `CGWindowList` and sorting by x finds nothing. Accessibility still
/// reports them: every app exposes an `AXExtrasMenuBar` element whose children
/// are its status items, each with a position.
///
/// ## Why this is cached rather than read on demand
///
/// **Measured on a real session: one full walk took 29.3 seconds** across 192
/// running applications. Each AX call crosses a process boundary and an app
/// that is busy or wedged blocks until it answers. Doing that on the main
/// thread when the user clicks freezes the app — the click that follows is
/// swallowed and a menu opens tens of seconds late, which is exactly how the
/// first cut of this behaved.
///
/// So the walk happens on a background queue and the result is kept. Callers
/// read the snapshot, which costs nothing.
///
/// Two things make the refresh far cheaper after the first one:
///
/// - Only processes known to own a status item are asked. Most running apps
///   never have one, and `AXExtrasMenuBar` on those is a wasted round trip.
///   The same trick `HiddenIcons` already uses for its own cache.
/// - A refresh is triggered by app launches and quits rather than by a timer.
///
/// ## Why the snapshot is taken while EXPANDED
///
/// A restricted menu bar under-reports: the items macOS is hiding stop being
/// laid out, so a walk during a collapse sees only what survived the last one.
/// Acting on that would shrink the allow-list a little further each time.
/// `refresh()` is therefore called on expand and at launch, never during a
/// collapse.
enum MenuBarInventory {

    struct Item {
        let bundleIdentifier: String
        let appName: String
        /// Left edge in global screen coordinates.
        let x: CGFloat
    }

    /// Whether Accessibility is granted. Without it the walk returns nothing,
    /// which is indistinguishable from "no items" — so callers check this and
    /// say something useful rather than silently hiding nothing.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    // MARK: - Snapshot

    /// Guards the stored snapshot ONLY. Every critical section here is a couple
    /// of assignments.
    ///
    /// The walk deliberately does **not** run on this queue. An earlier version
    /// used one serial queue for both, which meant a main-thread read of
    /// `snapshot` blocked behind an in-flight walk — and a walk can take 29
    /// seconds. That put back the exact freeze the background walk was added to
    /// remove: the menu took a full minute to open. Long work and short locks do
    /// not belong on the same queue.
    private static let stateLock = DispatchQueue(label: "cc.jorviksoftware.MenuTidy.inventory.state")

    /// Where the walking happens. Separate from `stateLock`, and utility QoS
    /// because nothing is waiting on it.
    private static let workQueue = DispatchQueue(label: "cc.jorviksoftware.MenuTidy.inventory.work",
                                                 qos: .utility)

    private static var _snapshot: [Item] = []
    private static var _knownHostPIDs: Set<pid_t> = []
    private static var _haveWalkedOnce = false
    private static var _walkInFlight = false

    /// The most recent inventory. Instant; never walks, never waits on one.
    static var snapshot: [Item] { stateLock.sync { _snapshot } }

    /// Whether a usable snapshot has been taken yet.
    static var hasSnapshot: Bool { stateLock.sync { !_snapshot.isEmpty } }

    /// Refresh in the background. Cheap to call often.
    static func refresh(completion: (() -> Void)? = nil) {
        guard isPermitted else { completion?(); return }

        // One walk at a time. Several clicks in a row would otherwise queue up
        // several 29-second sweeps behind each other for no benefit.
        let alreadyRunning = stateLock.sync { () -> Bool in
            if _walkInFlight { return true }
            _walkInFlight = true
            return false
        }
        if alreadyRunning { completion?(); return }

        let candidates = candidateApps()
        workQueue.async {
            let started = Date()
            let (items, hosts) = walk(candidates)
            MTDebug.log(String(format: "inventory walk: %d app(s) in %.1fs -> %d item(s)",
                               candidates.count, Date().timeIntervalSince(started), items.count))
            stateLock.sync {
                // A walk that finds nothing is far more likely to be a wedged AX
                // call than a genuinely empty menu bar, so keep the previous
                // snapshot rather than replacing it with nothing.
                if !items.isEmpty {
                    _snapshot = items
                    _knownHostPIDs = hosts
                    _haveWalkedOnce = true
                }
                _walkInFlight = false
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// The bundle identifiers of every app with an item at or right of `x`.
    ///
    /// This is the allow-list for a collapse: everything from the chevron
    /// rightwards stays, everything left of it goes. An app owning items on
    /// both sides is kept, because the restriction works per app and hiding it
    /// would take away an icon the user asked to keep.
    static func bundleIdentifiers(atOrRightOf x: CGFloat) -> [String] {
        var keep = Set<String>()
        for item in snapshot where item.x >= x {
            keep.insert(item.bundleIdentifier)
        }
        return Array(keep)
    }

    // MARK: - Private

    /// After the first walk, only ask processes already known to own an item.
    /// Anything launched since is included too, so a newly started menu bar app
    /// is picked up on the next refresh.
    private static func candidateApps() -> [NSRunningApplication] {
        let all = NSWorkspace.shared.runningApplications
        let (known, walked) = stateLock.sync { (_knownHostPIDs, _haveWalkedOnce) }
        guard walked else { return all }
        return all.filter { known.contains($0.processIdentifier) || $0.launchDate.map { $0 > Date().addingTimeInterval(-300) } ?? false }
    }

    /// How long to wait on any one app before giving up on it.
    ///
    /// This is what made the first walk take half a minute. The default AX
    /// messaging timeout is generous, so a single busy or wedged app can stall
    /// the sweep for seconds on its own, and a first walk covers every running
    /// process. A quarter of a second is far longer than a healthy app needs to
    /// answer "do you own a menu bar item", and an app that cannot answer in
    /// that time is not one whose icons we can place anyway.
    private static let messagingTimeout: Float = 0.25

    private static func walk(_ apps: [NSRunningApplication]) -> ([Item], Set<pid_t>) {
        let targets = apps.filter { $0.bundleIdentifier != nil && $0.processIdentifier > 0 }

        // Walked concurrently as well as with a timeout. The work is almost
        // entirely waiting on other processes, so doing them one at a time means
        // the sweep costs the SUM of every app's latency rather than the worst
        // of them.
        var perApp = [([Item], pid_t?)](repeating: ([], nil), count: targets.count)
        let resultLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let app = targets[index]
            guard let bundleIdentifier = app.bundleIdentifier else { return }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, messagingTimeout)

            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barValue) == .success,
                  let bar = barValue else { return }

            var childValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement,
                                                kAXChildrenAttribute as CFString,
                                                &childValue) == .success,
                  let children = childValue as? [AXUIElement] else {
                resultLock.lock(); perApp[index] = ([], app.processIdentifier); resultLock.unlock()
                return
            }

            var mine: [Item] = []
            for child in children {
                // A negative x is a real item belonging to a running app that is
                // not laid out in the bar right now. Treating it as leftmost
                // would put it on the wrong side of the chevron.
                guard let origin = position(of: child), origin.x >= 0 else { continue }
                mine.append(Item(bundleIdentifier: bundleIdentifier,
                                 appName: app.localizedName ?? bundleIdentifier,
                                 x: origin.x))
            }
            resultLock.lock(); perApp[index] = (mine, app.processIdentifier); resultLock.unlock()
        }

        var items: [Item] = []
        var hosts = Set<pid_t>()
        for (found, pid) in perApp {
            items.append(contentsOf: found)
            if let pid { hosts.insert(pid) }
        }
        return (items.sorted { $0.x < $1.x }, hosts)
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
}
