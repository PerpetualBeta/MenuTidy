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
        /// How wide the item is. Most are about 36 points, but an item showing
        /// text is not: Ballast puts the song title in the bar and was measured
        /// at 378 points on one track. Width is what decides whether an item
        /// straddles the chevron, so it cannot be inferred.
        let width: CGFloat
        /// Right edge in global screen coordinates.
        var maxX: CGFloat { x + width }
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

    /// One app's leftmost item, or nil if it owns none in the snapshot.
    ///
    /// Used to locate MenuTidy's own chevron. `NSStatusItem`'s button reports a
    /// window frame, and before macOS 27 that was the truth. It is not on 27:
    /// `CGWindowList` shows MenuTidy owns **no window at the menu bar layer at
    /// all**, because the bar is one Window Server window. AppKit still hands
    /// back an `NSWindow`, but its frame is wherever AppKit last put it rather
    /// than where macOS drew the item after its own reflow. Measured on
    /// 2026-09-20: the window said x=361 while Accessibility and a screenshot
    /// of the pixels both said x=896.
    ///
    /// Reflows are frequent when any app has a variable-width item. Ballast puts
    /// the song title in the bar, and one track change moved this app's chevron
    /// 126 points in a single step.
    ///
    /// **This is the cached snapshot, so it can still be stale**: it refreshes on
    /// expand and at launch, not on every reflow. It is wrong less often than the
    /// window frame, which is wrong by hundreds of points, but it is not live.
    static func item(ofBundleIdentifier bundleIdentifier: String) -> Item? {
        snapshot.filter { $0.bundleIdentifier == bundleIdentifier }.min { $0.x < $1.x }
    }

    /// Walk the bar now and hand back what is there, **without touching the
    /// cached snapshot**.
    ///
    /// The cache is deliberately only taken while the bar is expanded, because a
    /// restricted bar under-reports and caching that would shrink the allow-list
    /// a little further every cycle. But there is one question that can only be
    /// answered while collapsed: is this app's own chevron still reachable, or
    /// has a hidden item's leftover rectangle landed on top of it. So this reads
    /// without writing.
    /// Shares `refresh()`'s one-at-a-time guard. Without it a burst of clicks
    /// queues a sweep each, and they run back to back on the work queue long
    /// after the clicks that asked for them.
    ///
    /// It also logs. An earlier cut was silent, which meant the interesting
    /// case — a click that went missing — left no trace at all, and the log read
    /// as if nothing had happened.
    static func probe(completion: @escaping ([Item]) -> Void) {
        guard isPermitted else { completion([]); return }

        let alreadyRunning = stateLock.sync { () -> Bool in
            if _walkInFlight { return true }
            _walkInFlight = true
            return false
        }
        if alreadyRunning {
            MTDebug.log("probe skipped: a walk is already in flight")
            completion([])
            return
        }

        let candidates = candidateApps()
        workQueue.async {
            let started = Date()
            let (items, _) = walk(candidates)
            stateLock.sync { _walkInFlight = false }
            MTDebug.log(String(format: "probe: %d app(s) in %.1fs -> %d item(s)",
                               candidates.count, Date().timeIntervalSince(started), items.count))
            DispatchQueue.main.async { completion(items) }
        }
    }

    /// The bundle identifiers of every app that must stay visible when the bar
    /// collapses to a chevron occupying `chevron`.
    ///
    /// Everything from the chevron rightwards stays, everything left of it goes.
    /// An app owning items on both sides is kept, because the restriction works
    /// per app and hiding it would take away an icon the user asked to keep.
    ///
    /// ## An item that straddles the chevron counts as being on both sides
    ///
    /// The test is the item's **right edge against the middle of the chevron**,
    /// not its left edge against the left of the chevron. An item is hidden only
    /// when it lies wholly to the left.
    ///
    /// This is not tidiness. macOS 27 hides an item **without reclaiming its
    /// space**: the item stops being drawn but keeps its rectangle, leaving a
    /// dead hole in the bar. Measured on 2026-09-20 with Ballast, which puts the
    /// song title in the bar. On a long title its item ran from 870 to 1074
    /// while the chevron sat at 1046. Judged by its left edge alone the item is
    /// "left of the chevron", so it was hidden, and its 204-point hole then lay
    /// across the chevron. **A click anywhere in that hole reaches nothing.**
    /// Verified by posting clicks at thirteen positions from x=800 to x=1090:
    /// not one of them reached this app, while the same sweep with a short title
    /// hit at exactly 1010, 1030 and 1045, the chevron's real rectangle.
    ///
    /// The user's only way back is the chevron, so burying it strands them.
    ///
    /// The midpoint is used rather than the chevron's left edge because
    /// neighbouring items in a packed bar overlap by a point or two. Measuring
    /// to the left edge would keep whatever sits immediately left of the chevron
    /// every time, which would hide almost nothing.
    static func bundleIdentifiers(leftOf chevron: (x: CGFloat, width: CGFloat)) -> [String] {
        let divider = chevron.x
        var keep = Set<String>()
        for item in snapshot where item.x >= divider {
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
                                 x: origin.x,
                                 width: size(of: child)?.width ?? 0))
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

    private static func size(of element: AXUIElement) -> CGSize? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
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
