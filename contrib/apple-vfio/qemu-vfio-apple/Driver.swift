// Driver.swift — `driver-status` subcommand: tell the user whether the
// VFIOUserPCIDriver DriverKit extension is activated, waiting for
// approval, or uninstalled.
//
// We shell out to `systemextensionsctl list` rather than calling
// OSSystemExtensionRequest directly. The request-based API needs the
// `com.apple.developer.system-extension.install` entitlement, which
// requires an embedded provisioning profile — Mac CLI tool targets in
// Xcode don't get one (only `.app` bundles do), so install/uninstall
// is driven from the host app's setup checklist and this CLI only
// reports status.

import Foundation

// Derived from the host app's bundle id (see Cache.swift) so a forker who
// renames PRODUCT_BUNDLE_IDENTIFIER in Xcode's UI doesn't need to touch
// this string. The dext convention is `<host-app-id>.VFIOUserPCIDriver`.
let kDextBundleID = hostAppBundleID() + ".VFIOUserPCIDriver"

struct ExtensionState {
    let label: String
    let detail: String?
}

// MARK: - Command

func cmdDriverStatus() -> Int32 {
    let state = querySystemExtensionState(identifier: kDextBundleID)
    print("DriverKit extension:")
    print("  bundle id:      \(kDextBundleID)")
    print("  state:          \(state.label)")
    if let detail = state.detail {
        print("  detail:         \(detail)")
    }
    return 0
}

// MARK: - systemextensionsctl scraping

func querySystemExtensionState(identifier: String) -> ExtensionState {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
    task.arguments = ["list"]
    let stdout = Pipe()
    task.standardOutput = stdout
    task.standardError = Pipe()

    do {
        try task.run()
    } catch {
        return ExtensionState(
            label: "unknown",
            detail: "could not run systemextensionsctl: \(error.localizedDescription)")
    }
    task.waitUntilExit()

    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    for line in out.components(separatedBy: "\n") where line.contains(identifier) {
        // Lines look like:
        //   *   *   scottjg.VFIOUserHostApp.VFIOUserPCIDriver (1.0/1)  [activated enabled]
        //               ↑                                                  ↑ status in brackets
        if let lo = line.range(of: "[", options: .backwards),
           let hi = line.range(of: "]", options: .backwards),
           lo.upperBound <= hi.lowerBound
        {
            let bracket = String(line[lo.upperBound..<hi.lowerBound])
            let label: String
            if bracket.contains("activated enabled") {
                label = "active"
            } else if bracket.contains("waiting for user") {
                label = "waiting for user approval"
            } else if bracket.contains("terminated waiting to uninstall") {
                label = "uninstalling (reboot required)"
            } else {
                label = "staged"
            }
            return ExtensionState(label: label, detail: bracket)
        }
        return ExtensionState(
            label: "found in extensions list",
            detail: line.trimmingCharacters(in: .whitespaces))
    }
    return ExtensionState(label: "not installed", detail: nil)
}
