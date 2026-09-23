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
/// ## Fast sweeps, and why they are not enough on their own
///
/// Most running apps never own a status item, so `AXExtrasMenuBar` on those is
/// a wasted round trip. A **fast** sweep therefore asks only the process ids
/// already known to own one. That is the same trick `HiddenIcons` uses.
///
/// The catch, and it went unnoticed from 2.2.0 to 2.3.0: that set is built from
/// **process ids**, and it is replaced wholesale by every sweep. An app that
/// restarts has a new id the set has never heard of. An app that was merely
/// busy and missed the messaging timeout answered nothing, which used to be
/// recorded as "owns no status item". Either way it fell out of the set, and
/// `candidateApps` never asks a process that is not in the set, so it could
/// never come back.
///
/// **That is not a cosmetic cache miss.** An app missing from the snapshot is
/// missing from the allow-list, and an app missing from the allow-list is
/// hidden by the restriction *whichever side of the chevron it sits on*.
/// Measured on 2026-09-21: a fast sweep asked 23 apps and found 17 items while
/// a full sweep 49 seconds later asked 190 and found 21.
///
/// Two things stop it now. A busy app keeps whatever standing it had rather
/// than being dropped (see `refresh`), and a fast sweep is promoted to a
/// **full** one whenever the fast set can no longer be trusted to be complete
/// (see `effectiveScope`).
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

    /// How wide a sweep to take.
    enum Scope {
        /// Ask only the processes already known to own a status item.
        case fast
        /// Ask every running application.
        case full
    }

    private static var _snapshot: [Item] = []
    private static var _knownHostPIDs: Set<pid_t> = []
    private static var _haveWalkedOnce = false
    private static var _walkInFlight = false
    /// When the last full sweep finished, and which processes were running at
    /// the time. Together they decide whether the fast set is still complete.
    /// When the live snapshot was taken. A collapse decision is only as good
    /// as this is fresh, and the bar reflows on its own, so the age belongs in
    /// the log next to the decision.
    private static var _snapshotAt: Date?
    private static var _lastFullSweepAt: Date?
    private static var _lastFullSweepAppPIDs: Set<pid_t> = []

    /// The most recent inventory. Instant; never walks, never waits on one.
    static var snapshot: [Item] { stateLock.sync { _snapshot } }

    /// Whether a usable snapshot has been taken yet.
    static var hasSnapshot: Bool { stateLock.sync { !_snapshot.isEmpty } }

    /// How long ago the live snapshot was taken, or nil if there is none.
    static var snapshotAge: TimeInterval? {
        stateLock.sync { _snapshotAt }.map { Date().timeIntervalSince($0) }
    }

    /// Refresh in the background. Cheap to call often.
    ///
    /// `scope` is a floor, not a ceiling: a `.fast` request is promoted to a
    /// full sweep whenever the fast set can no longer be trusted. See
    /// `effectiveScope`.
    static func refresh(scope requested: Scope = .fast, completion: (() -> Void)? = nil) {
        guard isPermitted else { completion?(); return }

        // One walk at a time. Several clicks in a row would otherwise queue up
        // several 29-second sweeps behind each other for no benefit.
        let alreadyRunning = stateLock.sync { () -> Bool in
            if _walkInFlight { return true }
            _walkInFlight = true
            return false
        }
        if alreadyRunning { completion?(); return }

        // Enumerated once and handed to both, rather than asked for twice on
        // the calling thread.
        let running = NSWorkspace.shared.runningApplications
        let scope = effectiveScope(requested: requested, running: running)
        let candidates = candidateApps(scope: scope, running: running)
        let knownBefore = stateLock.sync { _knownHostPIDs }
        workQueue.async {
            let started = Date()
            let (items, hosts, unreachable) = walk(candidates)
            MTDebug.log(String(format: "inventory walk (%@): %d app(s) in %.1fs -> %d item(s)",
                               scope == .full ? "full" : "fast",
                               candidates.count, Date().timeIntervalSince(started), items.count))
            if scope == .full, !knownBefore.isEmpty {
                // The whole reason the full sweep exists. Any host recovered
                // here was missing from the fast set, which means it was
                // missing from the last allow-list, which means the last
                // collapse hid it whichever side of the chevron it was on.
                // Silent until this line existed.
                let names = hosts.subtracting(knownBefore)
                    .compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
                if !names.isEmpty {
                    MTDebug.log("inventory: full sweep recovered \(names.count) host(s) the fast set had lost: "
                                + names.sorted().joined(separator: ", "))
                }
            }
            stateLock.sync {
                // A walk that finds nothing is far more likely to be a wedged AX
                // call than a genuinely empty menu bar, so keep the previous
                // snapshot rather than replacing it with nothing.
                if !items.isEmpty {
                    _snapshot = items
                    _snapshotAt = Date()
                    // An app that could not be reached keeps whatever standing
                    // it had. Dropping it was permanent, because a process that
                    // is not in this set is never asked again.
                    _knownHostPIDs = hosts.union(_knownHostPIDs.intersection(unreachable))
                    _haveWalkedOnce = true
                    if scope == .full {
                        _lastFullSweepAt = Date()
                        _lastFullSweepAppPIDs = Set(candidates.map { $0.processIdentifier })
                    }
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

        let candidates = candidateApps(scope: .fast, running: NSWorkspace.shared.runningApplications)
        workQueue.async {
            let started = Date()
            let (items, _, _) = walk(candidates)
            stateLock.sync { _walkInFlight = false }
            MTDebug.log(String(format: "probe: %d app(s) in %.1fs -> %d item(s)",
                               candidates.count, Date().timeIntervalSince(started), items.count))
            DispatchQueue.main.async { completion(items) }
        }
    }

    // MARK: - How full the bar is

    /// How much of the screen's width the status items need, as a fraction.
    ///
    /// The **sum of the item widths**, not the distance from the leftmost item
    /// to the rightmost. Those are not the same thing once macOS is hiding
    /// anything, because Accessibility reports a hidden item at the position it
    /// would have had. Measured 2026-09-20 with 23 items: the span read 98% of
    /// the screen while the items themselves came to 59%.
    ///
    /// Read from the snapshot, which is only ever taken while the bar is
    /// expanded, so it describes everything the user owns rather than whatever
    /// survived the last collapse.
    ///
    /// nil when no snapshot has been taken yet. That is not the same as an
    /// empty menu bar and must not be treated as 0%.
    static func occupancy(ofScreenWidth width: CGFloat) -> CGFloat? {
        let items = snapshot
        guard !items.isEmpty, width > 0 else { return nil }
        return items.reduce(0) { $0 + $1.width } / width
    }

    // MARK: - The system clock

    /// The app that owns the clock, and Notification Centre with it.
    private static let clockOwnerBundleIdentifier = "com.apple.MenuBarAgent"

    /// Accessibility identifier of the clock itself. Control Centre is the
    /// other item this same app owns, so the two have to be told apart.
    private static let clockAccessibilityIdentifier = "com.apple.menuextra.clock"

    /// The clock's element and where it is drawn, read live.
    ///
    /// Not taken from the snapshot, for two reasons. `item(ofBundleIdentifier:)`
    /// returns an app's LEFTMOST item, and the clock is the rightmost of this
    /// app's two, so that lookup answers Control Centre. And this is asked on a
    /// click, where a stale answer sends the click to the wrong place.
    ///
    /// The cost is one Accessibility query against one system daemon, measured
    /// at under 30 ms, rather than the full sweep that `refresh()` exists to
    /// keep off the click path. Callers still run it off the main thread.
    static func systemClock() -> (element: AXUIElement, x: CGFloat, width: CGFloat)? {
        guard isPermitted,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == clockOwnerBundleIdentifier
              }) else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString,
                                            &barValue) == .success,
              let bar = barValue,
              let clock = clockElement(under: bar as! AXUIElement, depth: 0),
              let origin = position(of: clock) else { return nil }
        return (clock, origin.x, size(of: clock)?.width ?? 0)
    }

    /// Where one process's leftmost status item is drawn, read **live**.
    ///
    /// One Accessibility round trip to one process, the same shape as
    /// `systemClock()` and measured there at under 30 ms. Takes a process id
    /// rather than a bundle identifier so a caller sampling in a loop does not
    /// re-enumerate every running app each time.
    ///
    /// **Call this off the main thread.** Asking Accessibility about our own
    /// process needs our own main thread free to answer, so a main-thread call
    /// about ourselves waits out the messaging timeout and returns nothing.
    static func liveLeftmostItemX(ofProcessIdentifier pid: pid_t) -> CGFloat? {
        guard isPermitted else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString,
                                            &barValue) == .success,
              let bar = barValue else { return nil }
        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString,
                                            &childValue) == .success,
              let children = childValue as? [AXUIElement] else { return nil }
        // Same rule as the walk: a negative x is an item that is not laid out
        // in the bar at the moment, not a position.
        return children.compactMap { position(of: $0)?.x }.filter { $0 >= 0 }.min()
    }

    /// Find the clock beneath `element`.
    ///
    /// It is a grandchild rather than a child: each of this app's items sits
    /// inside its own `AXGroup`, and the group carries no identifier and no
    /// actions. Only the element inside it does.
    private static func clockElement(under element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 3 else { return nil }
        var identifier: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString,
                                         &identifier) == .success,
           (identifier as? String) == clockAccessibilityIdentifier {
            return element
        }
        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &childValue) == .success,
              let children = childValue as? [AXUIElement] else { return nil }
        for child in children {
            if let found = clockElement(under: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Whether macOS is hiding menu bar items of its own accord right now.
    ///
    /// macOS 27 puts a chevron of its own in the bar when it runs out of room.
    /// It is an `AXButton` sitting directly in MenuBarAgent's menu bar,
    /// alongside the two `AXGroup`s that hold Control Centre and the clock, and
    /// it is there **only** while macOS is hiding something. Measured
    /// 2026-09-20: absent on a bar with room, present at x=890 w=18 on an
    /// overfull one, described as "Show Hidden Menu Bar Items".
    ///
    /// This is worth far more than guessing from widths, because it is a fact
    /// rather than a prediction: when this is true, icons are being dropped
    /// this moment, allow-listed ones included, and each one leaves its
    /// rectangle behind for clicks to fall into.
    ///
    /// Matched on the **role**, not the description. The description is
    /// English and would quietly stop matching in any other language.
    static var macOSIsHidingItems: Bool {
        guard isPermitted,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == clockOwnerBundleIdentifier
              }) else { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString,
                                            &barValue) == .success,
              let bar = barValue else { return false }
        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString,
                                            &childValue) == .success,
              let children = childValue as? [AXUIElement] else { return false }
        return children.contains { child in
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString,
                                                &role) == .success else { return false }
            return (role as? String) == (kAXButtonRole as String)
        }
    }

    /// The app behind the Notification Centre panel.
    private static let notificationCentreBundleIdentifier = "com.apple.notificationcenterui"

    /// Whether the Notification Centre panel is on screen right now.
    ///
    /// Matched by the owning process's bundle identifier rather than by the
    /// window's name. The name is localised — this Mac reports "Notification
    /// Centre", a US one reports "Notification Center" — and matching on it
    /// would stop working abroad with no error and no clue why.
    ///
    /// Only the owner's process id is read, never the window name, so this does
    /// not require Screen Recording.
    static var isNotificationCentreShowing: Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                == notificationCentreBundleIdentifier
        }
    }

    /// Ask the clock to act on a press, as if it had been clicked.
    ///
    /// This is how Notification Centre is opened without posting a synthetic
    /// mouse event. It is refused while a restriction is active — measured
    /// 2026-09-20, the call returns success and nothing opens — so the caller
    /// has to lift the restriction first.
    ///
    /// The element is looked up here rather than passed in, so that the lookup
    /// happens AFTER the restriction has gone. An element found while the bar
    /// was still restricted describes an item macOS was not drawing.
    @discardableResult
    static func pressSystemClock() -> Bool {
        guard let clock = systemClock() else { return false }
        AXUIElementSetMessagingTimeout(clock.element, messagingTimeout)
        return AXUIElementPerformAction(clock.element, kAXPressAction as CFString) == .success
    }

    /// Pairs of items reporting the same rectangle, within `tolerance` points.
    ///
    /// **Two real items never overlap**, so a collision means macOS has dropped
    /// something and left its rectangle behind. That is the overfull-bar
    /// artefact, and it is a far better signal of it than either trigger
    /// `warnIfTheBarIsTooFull` had: measured 2026-09-23 on a bar carrying 24
    /// items, the summed width came to **61%** of the screen, below the 80%
    /// threshold, and macOS had not added its own overflow chevron either, yet
    /// **11 pairs sat within 2 points of each other** and two pairs were exactly
    /// identical. Neither existing trigger fired while the bar was visibly over
    /// capacity.
    ///
    /// The width sum cannot see this by design — it deliberately sums widths
    /// rather than measuring the span, because a hidden item is reported at the
    /// position it would have had. Collisions are what that choice gives up,
    /// and this puts it back.
    static func collidingPairs(tolerance: CGFloat = 2) -> [(Item, Item)] {
        let items = snapshot
        var pairs: [(Item, Item)] = []
        for (i, a) in items.enumerated() {
            for b in items[(i + 1)...] {
                if abs(a.x - b.x) <= tolerance && abs(a.maxX - b.maxX) <= tolerance {
                    pairs.append((a, b))
                }
            }
        }
        return pairs
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
        let divider = chevron.x + chevron.width / 2
        var keep = Set<String>()
        for item in snapshot where item.maxX > divider {
            keep.insert(item.bundleIdentifier)
        }
        return Array(keep)
    }

    // MARK: - Private

    /// A full sweep asks every running app. A fast one asks only the processes
    /// already known to own a status item.
    private static func candidateApps(scope: Scope,
                                      running all: [NSRunningApplication]) -> [NSRunningApplication] {
        guard scope == .fast else { return all }
        let (known, walked) = stateLock.sync { (_knownHostPIDs, _haveWalkedOnce) }
        guard walked else { return all }
        return all.filter { known.contains($0.processIdentifier) }
    }

    /// Promote a fast sweep to a full one when the fast set can no longer be
    /// trusted to be complete.
    ///
    /// This replaces a five-minute `launchDate` window that only half worked.
    /// That window caught an app during the five minutes after it started and
    /// never again, so an app that restarted while the bar sat collapsed, or
    /// that surfaced its status item late, stayed invisible for the rest of the
    /// session.
    ///
    /// Two triggers, both cheap:
    ///
    /// - **The set of running processes has changed** since the last full
    ///   sweep. The fast set is keyed by process id, so anything started, quit
    ///   or restarted makes it incomplete by definition. This is exact rather
    ///   than a guess at a timeout.
    /// - **The last full sweep has aged out.** A process list that has not
    ///   changed is not proof the bar has not: some apps create their status
    ///   item long after they launch.
    private static func effectiveScope(requested: Scope,
                                       running: [NSRunningApplication]) -> Scope {
        guard requested == .fast else { return .full }
        let (walked, sweptAt, sweptPIDs) = stateLock.sync {
            (_haveWalkedOnce, _lastFullSweepAt, _lastFullSweepAppPIDs)
        }
        guard walked, let sweptAt else { return .full }
        if Date().timeIntervalSince(sweptAt) >= fullSweepMaxAge { return .full }
        return Set(running.map { $0.processIdentifier }) == sweptPIDs ? .fast : .full
    }

    /// How stale a full sweep may get before the next refresh is promoted to
    /// one, in seconds.
    ///
    /// A full sweep was measured at **1.1 seconds** across 190 running apps on
    /// 2026-09-21, on a background queue, with the messaging timeout below
    /// doing the heavy lifting. One a minute is a small fraction of one core's
    /// background time, and it bounds how long an app that created its status
    /// item late can stay missing from the allow-list. Missing from the
    /// allow-list means hidden on the next collapse, so the bound is the point.
    private static let fullSweepMaxAge: TimeInterval = 60

    /// How long to wait on any one app before giving up on it.
    ///
    /// This is what made the first walk take half a minute. The default AX
    /// messaging timeout is generous, so a single busy or wedged app can stall
    /// the sweep for seconds on its own, and a first walk covers every running
    /// process. A quarter of a second is far longer than a healthy app needs to
    /// answer "do you own a menu bar item", and an app that cannot answer in
    /// that time is not one whose icons we can place anyway.
    private static let messagingTimeout: Float = 0.25

    /// Ask each app what status items it owns.
    ///
    /// Returns the items, the process ids that **answered**, and the process
    /// ids that **could not be reached**. The third one matters: "no reply" and
    /// "no menu bar items" used to be the same answer here, and conflating them
    /// dropped a merely busy app out of the fast set for good.
    private static func walk(_ apps: [NSRunningApplication]) -> ([Item], Set<pid_t>, Set<pid_t>) {
        let targets = apps.filter { $0.bundleIdentifier != nil && $0.processIdentifier > 0 }

        // Walked concurrently as well as with a timeout. The work is almost
        // entirely waiting on other processes, so doing them one at a time means
        // the sweep costs the SUM of every app's latency rather than the worst
        // of them.
        var perApp = [([Item], pid_t?, Bool)](repeating: ([], nil, false), count: targets.count)
        let resultLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let app = targets[index]
            guard let bundleIdentifier = app.bundleIdentifier else { return }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, messagingTimeout)

            var barValue: CFTypeRef?
            let barResult = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barValue)
            guard barResult == .success, let bar = barValue else {
                // `.cannotComplete` is what the messaging timeout above returns
                // for an app that was busy or wedged. It is NOT the same
                // statement as "this app has no status items", and treating the
                // two alike is what removed a busy app from the allow-list for
                // the rest of the session. Every other error is a settled
                // answer: the app has no extras menu bar, or no Accessibility
                // support at all.
                if barResult == .cannotComplete {
                    resultLock.lock(); perApp[index] = ([], nil, true); resultLock.unlock()
                }
                return
            }

            var childValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement,
                                                kAXChildrenAttribute as CFString,
                                                &childValue) == .success,
                  let children = childValue as? [AXUIElement] else {
                resultLock.lock(); perApp[index] = ([], app.processIdentifier, false); resultLock.unlock()
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
            resultLock.lock(); perApp[index] = (mine, app.processIdentifier, false); resultLock.unlock()
        }

        var items: [Item] = []
        var hosts = Set<pid_t>()
        var unreachable = Set<pid_t>()
        for (index, entry) in perApp.enumerated() {
            let (found, pid, couldNotBeReached) = entry
            items.append(contentsOf: found)
            if let pid { hosts.insert(pid) }
            if couldNotBeReached { unreachable.insert(targets[index].processIdentifier) }
        }
        return (items.sorted { $0.x < $1.x }, hosts, unreachable)
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
