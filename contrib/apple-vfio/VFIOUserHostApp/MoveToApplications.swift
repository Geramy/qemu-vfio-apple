// MoveToApplications: at-launch helper that offers to move the .app bundle
// into /Applications and relaunch from there.
//
// macOS requires the host app of a DriverKit extension to live in
// /Applications (or a system-managed location) for the dext to be staged and
// approved. If the user double-clicks the .app from ~/Downloads or a mounted
// DMG, we offer to move it for them rather than make them drag it manually.
//
// The flow:
//   1. If we are already under /Applications/, do nothing.
//   2. If we are running under "/AppTranslocation/" (Gatekeeper translocation
//      from a DMG / quarantined Downloads), the bundle path we see is a
//      read-only sealed copy. We can still copy *from* it into /Applications
//      and relaunch from the destination. The OS cleans up the translocated
//      copy automatically.
//   3. Otherwise show an alert. If the user agrees, copy the bundle into
//      /Applications/<AppName>.app, optionally trash the original location,
//      relaunch from the new path, and exit the current process.
//
// No App Sandbox needed — sandbox is disabled for this app, so writing into
// /Applications and ~/.Trash works without entitlements.

import AppKit
import Foundation

enum MoveToApplications {

    /// Run the move-to-/Applications check. Safe to call once at launch.
    static func runIfNeeded() {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path

        // Already in /Applications — nothing to do.
        if path.hasPrefix("/Applications/") { return }

        // Skip when running from Xcode's DerivedData ("build/Debug/...").
        // Developers explicitly opted into the source location.
        if isLikelyDeveloperBuild(path: path) { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = """
            \(Bundle.main.appName) needs to live in /Applications for the \
            DriverKit system extension to load.

            Move the app to /Applications and relaunch it from there?
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Do Not Move")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let target = try moveBundle(from: bundleURL)
            relaunchAndExit(at: target)
        } catch {
            let err = NSAlert()
            err.messageText = "Could not move \(Bundle.main.appName)"
            err.informativeText = """
                \(error.localizedDescription)

                Try dragging the app to /Applications manually, then launch it \
                from there.
                """
            err.alertStyle = .warning
            err.addButton(withTitle: "OK")
            _ = err.runModal()
        }
    }

    // MARK: - Move

    /// Copies the running bundle into /Applications/<AppName>.app, asking the
    /// user how to handle a pre-existing copy. Returns the destination URL.
    private static func moveBundle(from src: URL) throws -> URL {
        let fm = FileManager.default
        let appsDir = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let dest = appsDir.appendingPathComponent(src.lastPathComponent)

        // If destination exists, ask before clobbering.
        if fm.fileExists(atPath: dest.path) {
            let alert = NSAlert()
            alert.messageText = "Replace existing \(dest.lastPathComponent)?"
            alert.informativeText = """
                A copy of this app already exists in /Applications. Replace it \
                with this version?
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                throw MoveError.cancelled
            }
            try removeSafely(dest)
        }

        // Copy (don't move) — works whether the source is on the same volume,
        // on a DMG, or in a translocated read-only directory.
        do {
            try fm.copyItem(at: src, to: dest)
        } catch let err as NSError {
            // Common failure modes: read-only /Applications, no permission.
            throw MoveError.copyFailed(underlying: err)
        }

        // Best-effort: trash the original if we have write access there.
        // Skip when the source is a translocated copy or on a DMG — those
        // should not be modified.
        if isWritableUserLocation(src.deletingLastPathComponent().path)
            && !isTranslocated(path: src.path)
            && !isOnReadOnlyVolume(url: src)
        {
            try? fm.trashItem(at: src, resultingItemURL: nil)
        }

        return dest
    }

    /// Replace `dest` (file or directory). Tries to trash first; falls back to
    /// outright removal so the new copy can be written.
    private static func removeSafely(_ dest: URL) throws {
        let fm = FileManager.default
        do {
            try fm.trashItem(at: dest, resultingItemURL: nil)
        } catch {
            try fm.removeItem(at: dest)
        }
    }

    // MARK: - Relaunch

    /// Spawn `/usr/bin/open <newURL>` and exit the current process. Using
    /// `open` rather than `NSWorkspace.openApplication` sidesteps the race
    /// where the new instance fails to launch because we still hold the bundle
    /// identifier.
    private static func relaunchAndExit(at newURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", newURL.path]
        do {
            try task.run()
        } catch {
            // If we can't relaunch, leave the user with a working copy and
            // fall through to a normal launch from the old location.
            return
        }
        // Give `open` a brief head start to fork before we exit.
        Thread.sleep(forTimeInterval: 0.2)
        exit(0)
    }

    // MARK: - Heuristics

    private static func isLikelyDeveloperBuild(path: String) -> Bool {
        // Built via Xcode goes to DerivedData/.../Build/Products/<config>/...
        if path.contains("/DerivedData/") { return true }
        // The in-tree build/Debug or build/Release directory.
        if path.contains("/build/Debug/") || path.contains("/build/Release/") {
            return true
        }
        // Xcode previews and indexing.
        if path.contains("/Xcode/") && path.contains("/Products/") { return true }
        return false
    }

    private static func isTranslocated(path: String) -> Bool {
        return path.contains("/AppTranslocation/")
            || path.hasPrefix("/private/var/folders/")
    }

    private static func isOnReadOnlyVolume(url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsReadOnlyKey]
        do {
            let v = try url.resourceValues(forKeys: keys)
            return v.volumeIsReadOnly ?? false
        } catch {
            return false
        }
    }

    private static func isWritableUserLocation(_ path: String) -> Bool {
        return FileManager.default.isWritableFile(atPath: path)
    }
}

private enum MoveError: LocalizedError {
    case cancelled
    case copyFailed(underlying: NSError)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Cancelled."
        case .copyFailed(let err):
            return "Could not copy into /Applications: \(err.localizedDescription)"
        }
    }
}

private extension Bundle {
    var appName: String {
        if let name = infoDictionary?["CFBundleDisplayName"] as? String { return name }
        if let name = infoDictionary?["CFBundleName"] as? String { return name }
        return bundleURL.deletingPathExtension().lastPathComponent
    }
}
