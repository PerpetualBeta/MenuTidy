import Foundation
import AppKit

enum UpdateCheckInterval: Int, CaseIterable, Identifiable {
    case daily = 86400
    case weekly = 604800
    case monthly = 2592000
    case never = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .daily: "Every day"
        case .weekly: "Every week"
        case .monthly: "Every 30 days"
        case .never: "Never"
        }
    }
}

enum UpdateStatus: Equatable {
    case unknown
    case checking
    case upToDate(version: String)
    case available(version: String, url: String)
    case downloading(progress: String)
    case error(String)
}

@Observable
final class JorvikUpdateChecker {
    let repoName: String

    var status: UpdateStatus = .unknown
    var checkInterval: UpdateCheckInterval {
        didSet { UserDefaults.standard.set(checkInterval.rawValue, forKey: "updateCheckInterval") }
    }
    var autoInstall: Bool {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "autoInstallUpdates") }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    init(repoName: String) {
        self.repoName = repoName
        let stored = UserDefaults.standard.integer(forKey: "updateCheckInterval")
        self.checkInterval = UpdateCheckInterval(rawValue: stored) ?? .weekly
        self.autoInstall = UserDefaults.standard.bool(forKey: "autoInstallUpdates")
    }

    private var scheduledTimer: Timer?

    func checkOnSchedule() {
        // Check immediately if enough time has elapsed
        checkIfDue()

        // Schedule a repeating timer to re-check periodically while the app
        // is running. Menu bar utilities often run for days without relaunch,
        // so the launch-time check alone is insufficient.
        scheduledTimer?.invalidate()
        guard checkInterval != .never else { return }
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard checkInterval != .never else { return }

        let lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        let elapsed = Date().timeIntervalSince(lastCheck)

        if elapsed >= Double(checkInterval.rawValue) {
            Task { await checkNow() }
        }
    }

    @MainActor
    func checkNow() async {
        status = .checking

        guard let url = URL(string: "https://api.github.com/repos/PerpetualBeta/\(repoName)/releases/latest") else {
            status = .error("Invalid repo URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                status = .error("GitHub API returned an error")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String else {
                status = .error("Could not parse GitHub response")
                return
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")

            if isNewer(remote: remoteVersion, local: currentVersion) {
                status = .available(version: remoteVersion, url: htmlURL)

                if autoInstall {
                    // Find the zip asset
                    if let assets = json["assets"] as? [[String: Any]],
                       let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                       let downloadURL = zipAsset["browser_download_url"] as? String {
                        await autoInstallUpdate(from: downloadURL)
                    }
                }
            } else {
                status = .upToDate(version: currentVersion)
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func openReleasePage() {
        if case .available(_, let url) = status, let releaseURL = URL(string: url) {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    // MARK: - Bundle ownership

    /// True when the running app's bundle on disk is owned by a uid other
    /// than the current user — almost always means it was installed via
    /// `.pkg` (the macOS Installer sets root:wheel ownership), and any
    /// in-place replacement attempt requires admin authentication.
    private func bundleNeedsElevatedReplace() -> Bool {
        let path = Bundle.main.bundleURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attrs[.ownerAccountID] as? NSNumber else {
            // If we can't read attrs, conservatively try unelevated first
            // — the only loss is one wasted attempt before the user sees
            // the existing failure path.
            return false
        }
        return owner.uint32Value != getuid()
    }

    // MARK: - Auto-install

    @MainActor
    private func autoInstallUpdate(from urlString: String) async {
        guard let url = URL(string: urlString) else { return }

        status = .downloading(progress: "Downloading...")

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)

            status = .downloading(progress: "Installing...")

            let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("JorvikUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            // Extract zip
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", tempURL.path, extractDir.path]
            try unzip.run()
            unzip.waitUntilExit()

            guard unzip.terminationStatus == 0 else {
                status = .error("Failed to extract update")
                return
            }

            // Find the .app in the extracted directory
            let items = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            guard let appBundle = items.first(where: { $0.pathExtension == "app" }) else {
                status = .error("No .app found in update")
                return
            }

            // Replace the running app using a post-quit shell script.
            // FileManager can't move SIP-protected signed bundles while
            // running; we have to detach a script that waits for us to quit
            // and then does the move.
            //
            // Privilege handling: when the app was installed via .pkg, the
            // bundle is owned by root:wheel and the user can't rm-rf it.
            // Detect ownership; if root-owned, run the same script as root
            // via NSAppleScript's "with administrator privileges" — the user
            // sees one Touch ID / password prompt per update. If user-owned
            // (zip-installed, dragged in), no elevation needed.
            let currentAppURL = Bundle.main.bundleURL
            let currentPath = currentAppURL.path
            let newAppPath = appBundle.path
            let pid = ProcessInfo.processInfo.processIdentifier
            let uid = getuid()
            let needsElevation = bundleNeedsElevatedReplace()

            let script = """
            #!/bin/bash
            # Wait for the app to quit
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            # Remove old app
            rm -rf '\(currentPath)'
            # Move new app into place
            mv '\(newAppPath)' '\(currentPath)'
            \(needsElevation ? "# Restore root ownership to match the original .pkg install\nchown -R root:wheel '\(currentPath)'" : "")
            # Clean up the extracted dir
            rm -rf '\(extractDir.path)'
            # Relaunch as the user (works whether we're running as root or user)
            launchctl asuser \(uid) /usr/bin/open '\(currentPath)'
            # Self-destruct
            rm -f /tmp/jorvik_update.sh
            """

            let scriptPath = "/tmp/jorvik_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptPath]
            try chmod.run()
            chmod.waitUntilExit()

            if needsElevation {
                // do shell script blocks; launch the bash script detached
                // so AppleScript returns immediately (otherwise it would
                // wait forever, and the bash script is itself waiting for
                // us to quit).
                let appleScriptSource = #"do shell script "nohup /bin/bash \#(scriptPath) </dev/null >/dev/null 2>&1 &" with administrator privileges"#
                guard let osa = NSAppleScript(source: appleScriptSource) else {
                    status = .error("Could not compile updater")
                    return
                }
                var asError: NSDictionary?
                _ = osa.executeAndReturnError(&asError)
                if let asError {
                    let brief = (asError["NSAppleScriptErrorBriefMessage"] as? String)
                        ?? (asError["NSAppleScriptErrorMessage"] as? String)
                        ?? "authentication required"
                    status = .error("Update cancelled — \(brief)")
                    return
                }
            } else {
                let launcher = Process()
                launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
                launcher.arguments = [scriptPath]
                try launcher.run()
            }

            // Quit so the script can replace us
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            status = .error("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Version comparison

    private func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
