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

            // Two-stage update:
            //
            // 1. Replace script — does rm/mv/chown synchronously (sync because
            //    we need to know it succeeded before we quit). Runs admin via
            //    AppleScript when the bundle is root-owned (.pkg install),
            //    plain bash otherwise. It does NOT wait for us to quit; it
            //    just replaces the bundle in-place. macOS keeps our mmap'd
            //    binary alive by inode, so we keep functioning long enough
            //    to spawn the relauncher.
            //
            // 2. Relaunch script — user-owned (NEVER admin), detaches via
            //    nohup/&, watches for our process to disappear, then opens
            //    the new bundle. The detachment works because user-spawned
            //    processes aren't subject to the AppleScript admin session
            //    cleanup that was killing the previous one-stage script.
            //
            // Logging goes to /tmp/jorvik_update.log so we can diagnose any
            // future failures end-to-end without having to repro live.
            let currentAppURL = Bundle.main.bundleURL
            let currentPath = currentAppURL.path
            let newAppPath = appBundle.path
            let needsElevation = bundleNeedsElevatedReplace()

            let logPath = "/tmp/jorvik_update.log"
            let replacePath = "/tmp/jorvik_replace.sh"
            let relaunchPath = "/tmp/jorvik_relaunch.sh"

            let replaceScript = """
            #!/bin/bash
            set -e
            exec >>\(logPath) 2>&1
            echo "[$(date '+%H:%M:%S')] replace: start (uid=$(id -u), running as $(whoami))"
            echo "[$(date '+%H:%M:%S')] replace: rm '\(currentPath)'"
            rm -rf '\(currentPath)'
            echo "[$(date '+%H:%M:%S')] replace: mv '\(newAppPath)' → '\(currentPath)'"
            mv '\(newAppPath)' '\(currentPath)'
            \(needsElevation ? "echo \"[$(date '+%H:%M:%S')] replace: chown root:wheel\"\nchown -R root:wheel '\(currentPath)'" : "")
            rm -rf '\(extractDir.path)'
            echo "[$(date '+%H:%M:%S')] replace: done"
            """

            let relaunchScript = """
            #!/bin/bash
            exec >>\(logPath) 2>&1
            echo "[$(date '+%H:%M:%S')] relaunch: waiting for old MenuTidy to quit"
            while pgrep -f '\(currentPath)/Contents/MacOS/' >/dev/null; do
                sleep 0.3
            done
            echo "[$(date '+%H:%M:%S')] relaunch: opening new instance"
            /usr/bin/open '\(currentPath)'
            rm -f \(replacePath) \(relaunchPath)
            echo "[$(date '+%H:%M:%S')] relaunch: done"
            """

            try replaceScript.write(toFile: replacePath, atomically: true, encoding: .utf8)
            try relaunchScript.write(toFile: relaunchPath, atomically: true, encoding: .utf8)

            for path in [replacePath, relaunchPath] {
                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["+x", path]
                try chmod.run()
                chmod.waitUntilExit()
            }

            // Stage 1: replace bundle (sync, possibly admin-elevated)
            if needsElevation {
                let appleScriptSource = #"do shell script "/bin/bash \#(replacePath)" with administrator privileges"#
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
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = [replacePath]
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    status = .error("Replacement failed (exit code \(proc.terminationStatus))")
                    return
                }
            }

            // Stage 2: spawn user-owned relauncher (detaches reliably)
            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/bash")
            relauncher.arguments = ["-c", "nohup /bin/bash \(relaunchPath) </dev/null >/dev/null 2>&1 &"]
            try relauncher.run()
            relauncher.waitUntilExit()

            // Quit; the relauncher is now waiting for our PID to disappear
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
