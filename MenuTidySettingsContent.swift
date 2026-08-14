import SwiftUI
import ApplicationServices

/// App-specific settings sections shown inside JorvikSettingsView:
///  - Auto-Collapse (enable + delay)
///  - Permissions (Accessibility status + grant button)
///  - Menu Bar Icon (JorvikKit's standard pill settings)
///
/// Accessibility is required by the Reveal Hidden Icons feature so MenuTidy
/// can enumerate other apps' status items via the AX API. Without it, the
/// reveal panel comes up empty.
///
/// Launch at Login and Updates sections are provided by JorvikSettingsView
/// itself, so they don't need to appear here.
struct MenuTidySettingsContent: View {
    var onPillChanged: () -> Void
    var onAutoCollapseChanged: () -> Void

    /// Kept current by JorvikKit — see `JorvikPermissionWatcher` for why a permission row
    /// needs a watcher rather than a read, and why reading it more often makes it worse.
    @StateObject private var accessibility = JorvikPermissionWatcher.accessibility()

    var body: some View {
        MenuTidyAutoCollapseSettings(onChanged: onAutoCollapseChanged)

        Section("Permissions") {
            HStack {
                Text("Accessibility")
                Spacer()
                if accessibility.isGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Grant Access") {
                        JorvikPermissionWatcher.promptForAccessibility()
                    }
                    .font(.caption)
                }
            }
        }

        MenuBarPillSettings(onChanged: onPillChanged)
    }
}

/// Settings section for auto-collapse — promoted from a hidden `defaults write`
/// flag to a first-class setting. Backs the `autoCollapse` (Bool) and
/// `autoCollapseDelay` (whole seconds) UserDefaults keys; the app re-reads them
/// live via `onChanged` so changes apply without a relaunch.
struct MenuTidyAutoCollapseSettings: View {
    static let maxSeconds = 999

    @State private var enabled = UserDefaults.standard.bool(forKey: "autoCollapse")
    @State private var seconds = MenuTidyAutoCollapseSettings.loadSeconds()
    var onChanged: (() -> Void)?

    /// Absent key → 2 s default; present → clamped to 0…max. 0 is valid and
    /// means "collapse the moment the pointer leaves the menu bar".
    static func loadSeconds() -> Int {
        let d = UserDefaults.standard
        let raw = d.object(forKey: "autoCollapseDelay") == nil ? 2 : d.integer(forKey: "autoCollapseDelay")
        return min(maxSeconds, max(0, raw))
    }

    var body: some View {
        Section("Auto-Collapse") {
            Toggle("Automatically collapse the menu bar", isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "autoCollapse")
                    onChanged?()
                }

            HStack {
                Text("Collapse after")
                Spacer()
                TextField("", value: $seconds, format: .number)
                    .labelsHidden()
                    .frame(width: 54)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $seconds, in: 0...Self.maxSeconds)
                    .labelsHidden()
                Text(seconds == 1 ? "second" : "seconds")
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            .onChange(of: seconds) { _, newValue in
                // TextField can produce out-of-range values; the Stepper can't.
                let clamped = min(Self.maxSeconds, max(0, newValue))
                if clamped != newValue { seconds = clamped; return }  // re-fires with clamped
                UserDefaults.standard.set(clamped, forKey: "autoCollapseDelay")
                onChanged?()
            }

            Text("Tidies the menu bar this many seconds after the pointer leaves it. Set to 0 to collapse the moment you move away.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
