import AppKit
import Foundation

/// Hides menu bar items on macOS 27 by asking macOS to do it.
///
/// ## Why this exists
///
/// macOS 27 draws the whole menu bar as a single Window Server window. Before
/// 27 each status item was its own window, which is what MenuTidy's spacer
/// relied on: an over-wide item pushed its neighbours off the edge. There are
/// no neighbouring windows to push any more, so the spacer hides nothing and no
/// amount of work on it ever will. Measured on 27.0 (26A428): the top strip of
/// the screen contains exactly one window at the menu bar layer and it belongs
/// to Window Server.
///
/// ## What replaces it
///
/// macOS 27 can hide menu bar items itself. Its *assessment mode* — the exam
/// lockdown facility — restricts the bar to an allow-list and reflows it. This
/// drives that directly: collapse activates a restriction naming the items that
/// should stay, expand drops it. It is instant, needs no restart of the target
/// apps, and macOS does the reflow, so there is no fake spacer and no gap.
///
/// ## Clean room
///
/// Every declaration below was derived by introspecting the Objective-C runtime
/// and `dyld_info -exports` on a macOS 27 machine. Other projects drive the same
/// OS facility; none of their source was read or used. The mangled export
/// confirms the initialiser's real signature:
///
///     init(allowedSystemItems: [NSNumber], allowedBundleIdentifiers: [String])
///
/// ## The two lists are independent
///
/// `allowedBundleIdentifiers` governs third-party items. `allowedSystemItems`
/// governs the clock and Control Centre, and passing `com.apple.controlcenter`
/// as a bundle identifier does **not** keep them — measured: with an empty
/// system list the clock and Control Centre vanish along with the target app.
///
/// `allowedSystemItems` holds raw values of a Swift enum,
/// `MBSystemItemIdentifier`, which is Int-backed and `CaseIterable`. Its case
/// names are not exported as symbols and cannot be read out, so rather than
/// guess them this passes every raw value in a generous range and lets macOS
/// keep whichever it recognises. Verified: the clock and Control Centre stay.
///
/// ## Caveat
///
/// This is private API. It can change or vanish in any macOS update, so every
/// entry point fails soft: if the classes do not resolve, `isAvailable` is false
/// and the caller falls back to leaving the bar alone rather than breaking.
enum MenuBarRestriction {

    // MARK: - Availability

    /// The private framework that owns assessment mode. Opened once, lazily, and
    /// deliberately never closed: the classes it registers are used for the life
    /// of the process.
    private static let frameworkLoaded: Bool = {
        let path = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
        return dlopen(path, RTLD_LAZY) != nil
    }()

    private static let configurationClass: AnyClass? = {
        guard frameworkLoaded else { return nil }
        return NSClassFromString("MBAssessmentModeConfiguration")
    }()

    private static let assertionClass: AnyClass? = {
        guard frameworkLoaded else { return nil }
        return NSClassFromString("MBAssessmentModeAssertion")
    }()

    /// Whether this Mac can hide items this way at all. False on anything before
    /// macOS 27, and false if a future macOS removes or renames the classes.
    static var isAvailable: Bool {
        guard #available(macOS 27.0, *) else { return false }
        return configurationClass != nil && assertionClass != nil
    }

    // MARK: - Objective-C plumbing
    //
    // MenuTidy is built with plain `swiftc` and has no bridging header, so the
    // private classes are reached through `objc_msgSend` rather than by adding
    // an Objective-C file and changing the shared release makefile. `objc_msgSend`
    // is not callable from Swift directly; it is resolved at runtime and cast to
    // a C function pointer of the right shape, which is the standard way to do
    // this and keeps the whole feature inside one Swift file.

    private static let msgSend: UnsafeMutableRawPointer? = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")

    private typealias SendNoArgs = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias SendTwoObjects = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Unmanaged<AnyObject>?
    private typealias SendObjectAndBlock = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (NSError?) -> Void) -> Void
    private typealias SendVoid = @convention(c) (AnyObject, Selector) -> Void

    /// `[[cls alloc] init]` for a class we have no header for.
    private static func makeInstance(of cls: AnyClass) -> AnyObject? {
        guard let msgSend else { return nil }
        let send = unsafeBitCast(msgSend, to: SendNoArgs.self)
        guard let allocated = send(cls, NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        return send(allocated, NSSelectorFromString("init"))?.takeRetainedValue()
    }

    // MARK: - State

    /// Apple's own menu bar owners, always kept whatever the user's layout.
    ///
    /// `allowedSystemItems` keeps the clock and Control Centre *drawn*, but that
    /// is not the same as keeping them usable: if the app that owns them is
    /// missing from `allowedBundleIdentifiers`, the clock is visible and
    /// **clicking it does nothing**, so Notification Centre cannot be opened.
    /// Measured on 2026-09-19 — the same fault reported against Hidden Bar as
    /// issue #421.
    ///
    /// It was also intermittent, which is worse than broken: these items sit far
    /// right, so whether they landed in the snapshot depended on where the
    /// chevron happened to be and how the displays were arranged. Some collapses
    /// included MenuBarAgent and some did not.
    ///
    /// Hiding the clock or Control Centre is never what anyone wants from a menu
    /// bar tidier, so it is decided here rather than left to the layout.
    private static let alwaysAllowedBundleIdentifiers = [
        "com.apple.MenuBarAgent",     // the clock, and Notification Centre with it
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
    ]

    /// Every raw value the system-item enum might use. Passing a range rather
    /// than specific cases is deliberate — see the note above on why the real
    /// case names cannot be read. Values macOS does not recognise are ignored.
    /// 0 to 63 is verified to keep the clock and Control Centre drawn. Widening
    /// it to 255 was tried on 2026-09-19 to see whether an identifier above the
    /// range explained Notification Centre being unreachable while collapsed. It
    /// did not, so the narrower verified range stands.
    private static let allSystemItemIdentifiers: [NSNumber] = (0..<64).map(NSNumber.init(value:))

    // MARK: - Applying

    // MARK: - The holder process

    /// Argument that puts a MenuTidy process into holder mode.
    static let holderFlag = "--hold-menu-bar-restriction"

    /// The process currently holding the restriction, if any.
    private static var holder: Process?

    /// Apply the restriction and stay alive until killed. Never returns.
    ///
    /// Runs in a second copy of this same binary, launched with `holderFlag`.
    /// Using our own executable rather than a separate helper target means no
    /// new build product, no extra signing rule and no change to the shared
    /// release pipeline — the holder inherits the app's own signature and
    /// notarisation because it IS the app.
    ///
    /// It deliberately never creates an NSApplication. It is spawned directly
    /// rather than through Launch Services, so it does not register as a second
    /// instance of MenuTidy, shows no icon and owns no menu bar item.
    static func runAsHolder(keeping bundleIdentifiers: [String]) -> Never {
        guard isAvailable,
              let configurationClass,
              let assertionClass,
              let msgSend,
              let configuration = makeInstanceOfConfiguration(configurationClass,
                                                              bundles: bundleIdentifiers),
              let assertion = makeInstance(of: assertionClass) else {
            exit(1)
        }
        let activate = unsafeBitCast(msgSend, to: SendObjectAndBlock.self)
        activate(assertion,
                 NSSelectorFromString("activateWithConfiguration:completionHandler:"),
                 configuration) { error in
            if let error {
                MTDebug.log("holder: activation FAILED: \(error.localizedDescription)")
            }
        }
        // Never outlive the app that started us. If MenuTidy crashes rather
        // than terminating us, this process would otherwise hold the menu bar
        // restricted forever with nothing left to release it. Once our parent
        // dies we are reparented to launchd (pid 1), which is the signal.
        let parentWatch = Timer(timeInterval: 2.0, repeats: true) { _ in
            if getppid() == 1 { exit(0) }
        }
        RunLoop.main.add(parentWatch, forMode: .common)

        // Held for the life of this process. No invalidate() on the way out:
        // it is not the undo, and exiting is.
        withExtendedLifetime(assertion) { RunLoop.main.run() }
        exit(0)
    }

    /// Start a holder for `bundleIdentifiers`, replacing any existing one.
    ///
    /// The new holder is started BEFORE the old one is killed, so the bar never
    /// flashes back to its unrestricted state in between — the same ordering the
    /// in-process path used.
    @discardableResult
    private static func startHolder(keeping bundleIdentifiers: [String]) -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [holderFlag] + bundleIdentifiers
        do {
            try process.run()
        } catch {
            MTDebug.log("holder: could not start: \(error.localizedDescription)")
            return false
        }
        let previous = holder
        holder = process
        if let previous, previous.isRunning { previous.terminate() }
        MTDebug.log("holder: pid \(process.processIdentifier) holding \(bundleIdentifiers.count) app(s)")
        return true
    }

    /// Kill the holder. This is the complete release.
    private static func stopHolder() {
        guard let process = holder else { return }
        holder = nil
        if process.isRunning { process.terminate() }
        MTDebug.log("holder: pid \(process.processIdentifier) terminated — restriction fully released")
    }

    /// Restrict the menu bar to `bundleIdentifiers`, hiding every other
    /// third-party item. The clock and Control Centre are always kept.
    ///
    /// Safe to call repeatedly: a new restriction is activated *before* the old
    /// one is dropped, so the bar never flashes back to its unrestricted state
    /// between the two.
    ///
    /// - Returns: whether the restriction was applied.
    @discardableResult
    static func restrict(toVisible bundleIdentifiers: [String]) -> Bool {
        var bundleIdentifiers = bundleIdentifiers
        for identifier in alwaysAllowedBundleIdentifiers where !bundleIdentifiers.contains(identifier) {
            bundleIdentifiers.append(identifier)
        }
        guard isAvailable else { return false }
        let started = startHolder(keeping: bundleIdentifiers)
        if started {
            MTDebug.log("menu bar restricted, keeping: \(bundleIdentifiers.sorted().joined(separator: ", "))")
        }
        return started
    }

    /// Drop the restriction and let every item come back.
    ///
    /// Killing the holder, not invalidating an assertion. See `runAsHolder` for
    /// why: invalidate() is not the undo, and leaves Notification Centre dead
    /// for the life of whichever process called activate.
    static func release() {
        guard holder != nil else { return }
        stopHolder()
        MTDebug.log("menu bar restriction released")
    }

    /// True while a restriction is applied.
    static var isRestricting: Bool { holder != nil }

    // MARK: - Private

    private static func makeInstanceOfConfiguration(_ cls: AnyClass, bundles: [String]) -> AnyObject? {
        guard let msgSend else { return nil }
        let alloc = unsafeBitCast(msgSend, to: SendNoArgs.self)
        guard let allocated = alloc(cls, NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        let initWith = unsafeBitCast(msgSend, to: SendTwoObjects.self)
        return initWith(allocated,
                        NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
                        allSystemItemIdentifiers as NSArray,
                        bundles as NSArray)?.takeRetainedValue()
    }
}
