import Combine
import Foundation
import SystemExtensions

@MainActor
final class SystemExtensionActivationManager: NSObject, ObservableObject {
    static let shared = SystemExtensionActivationManager()

    private enum RequestKind {
        case activation
        case deactivation
    }

    @Published private(set) var statusMessage = "Ready to activate DriverKit extension."
    @Published private(set) var requestInFlight = false
    /// True iff `systemextensionsctl` reports the dext as `[activated enabled]`
    /// (i.e. the user has approved it and it's loaded). A staged-but-not-yet
    /// approved dext does NOT count as active.
    @Published private(set) var isExtensionKnownActive: Bool = false
    /// True iff the dext is staged on disk but waiting for the user to enable
    /// it in System Settings → Login Items & Extensions.
    @Published private(set) var isExtensionWaitingForApproval: Bool = false
    @Published private(set) var deactivationPendingReboot = false

    let extensionIdentifier: String
    private var currentRequestKind: RequestKind?
    private var pendingActivationHandler: (() -> Void)?
    private var pendingDeactivationHandler: (() -> Void)?

    override init() {
        // Bundle.main.bundleIdentifier is always set for a properly built
        // .app — the only way it's nil is if Info.plist is missing, in
        // which case nothing else here would work either. No string
        // fallback so a forker who renamed PRODUCT_BUNDLE_IDENTIFIER in
        // Xcode's UI doesn't silently get the original "scottjg.*" id.
        let appBundleID = Bundle.main.bundleIdentifier!
        self.extensionIdentifier = appBundleID + ".VFIOUserPCIDriver"
        super.init()
        refreshExtensionActiveState()
    }

    func activate(afterActivation: (() -> Void)? = nil) {
        guard !requestInFlight else {
            return
        }

        pendingActivationHandler = afterActivation
        pendingDeactivationHandler = nil
        deactivationPendingReboot = false
        submitActivationRequest(message: "Submitting activation request for \(extensionIdentifier)...")
    }

    func deactivate(afterDeactivation: (() -> Void)? = nil) {
        guard !requestInFlight else {
            return
        }

        pendingActivationHandler = nil
        pendingDeactivationHandler = afterDeactivation
        deactivationPendingReboot = false
        submitDeactivationRequest(message: "Submitting deactivation request for \(extensionIdentifier)...")
    }

    func showStatus(_ message: String) {
        guard statusMessage != message else {
            return
        }
        statusMessage = message
    }

    func refreshExtensionActiveState() {
        let runtime = querySystemExtensionRuntimeState()
        switch runtime {
        case .enabled:
            isExtensionKnownActive = true
            isExtensionWaitingForApproval = false
        case .waitingForApproval:
            isExtensionKnownActive = false
            isExtensionWaitingForApproval = true
        case .otherStaged:
            // Some transient state (terminated, replacing, etc.) — treat as
            // not active and not approval-pending. The next state transition
            // will refine this.
            isExtensionKnownActive = false
            isExtensionWaitingForApproval = false
        case .notInstalled:
            // systemextensionsctl knows nothing about it. Fall back to the
            // disk check so a freshly submitted activation request that the
            // ctl tool hasn't picked up yet still registers as "staged".
            if isExtensionInstalledOnDisk() {
                isExtensionKnownActive = false
                isExtensionWaitingForApproval = true
            } else {
                isExtensionKnownActive = false
                isExtensionWaitingForApproval = false
            }
        }
        if !isExtensionKnownActive {
            deactivationPendingReboot = false
        }
    }

    private enum RuntimeState {
        case notInstalled
        case waitingForApproval
        case enabled
        /// Some other system-extension state we don't model (e.g. terminated,
        /// replacing). Reported verbatim in the bracketed `[state]` column.
        case otherStaged(String)
    }

    /// Shells out to `systemextensionsctl list` and looks for the line
    /// matching this dext. The tool runs unprivileged and typically completes
    /// in <100ms.
    private func querySystemExtensionRuntimeState() -> RuntimeState {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        task.arguments = ["list"]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        do {
            try task.run()
        } catch {
            return .notInstalled
        }
        task.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return .notInstalled
        }

        for line in output.components(separatedBy: "\n") {
            guard line.contains(extensionIdentifier) else { continue }
            // The bracketed state is the most reliable signal. Look at the
            // last [...] segment on the line so we don't mis-trigger on a
            // bundle id that happens to have brackets.
            let lower = line.lowercased()
            if lower.contains("[activated enabled]") {
                return .enabled
            }
            if lower.contains("waiting for user") {
                return .waitingForApproval
            }
            if let open = line.range(of: "[", options: .backwards),
               let close = line.range(of: "]", options: .backwards),
               open.upperBound <= close.lowerBound
            {
                return .otherStaged(String(line[open.upperBound..<close.lowerBound]))
            }
            return .otherStaged("unknown")
        }
        return .notInstalled
    }

    func resolvePendingDeactivationIfDriverStopped(driverStillRunning: Bool) {
        guard deactivationPendingReboot, !driverStillRunning else {
            return
        }

        deactivationPendingReboot = false
        isExtensionKnownActive = false
        statusMessage = "Driver services stopped. You can activate the driver again without reboot."
    }

    private func isExtensionInstalledOnDisk() -> Bool {
        let sysExtDir = "/Library/SystemExtensions"
        guard let uuidDirs = try? FileManager.default.contentsOfDirectory(atPath: sysExtDir) else {
            return false
        }

        let dextName = extensionIdentifier + ".dext"
        return uuidDirs.contains { dir in
            FileManager.default.fileExists(atPath: "\(sysExtDir)/\(dir)/\(dextName)")
        }
    }

    private func submitActivationRequest(message: String) {
        requestInFlight = true
        currentRequestKind = .activation
        statusMessage = message

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func submitDeactivationRequest(message: String) {
        requestInFlight = true
        currentRequestKind = .deactivation
        statusMessage = message

        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension SystemExtensionActivationManager: OSSystemExtensionRequestDelegate {
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // The dext is staged in /Library/SystemExtensions but won't load
        // until the user enables it in System Settings. Surface that in the
        // UI immediately rather than waiting for the next polling tick.
        isExtensionWaitingForApproval = true
        statusMessage = "Approve the system extension in System Settings → Login Items & Extensions."
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        statusMessage = "Replacing an existing system extension with the bundled version."
        return .replace
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch currentRequestKind {
        case .deactivation:
            switch result {
            case .completed:
                refreshExtensionActiveState()
                deactivationPendingReboot = false
                requestInFlight = false
                currentRequestKind = nil
                statusMessage = "System extension deactivated."
                let handler = pendingDeactivationHandler
                pendingDeactivationHandler = nil
                handler?()
            case .willCompleteAfterReboot:
                refreshExtensionActiveState()
                requestInFlight = false
                currentRequestKind = nil
                deactivationPendingReboot = true
                let handler = pendingDeactivationHandler
                pendingDeactivationHandler = nil
                statusMessage = "Deactivation will complete after reboot. Reboot the Mac, then activate the driver again."
                handler?()
            @unknown default:
                requestInFlight = false
                currentRequestKind = nil
                deactivationPendingReboot = false
                pendingDeactivationHandler = nil
                statusMessage = "Deactivation finished with an unknown result: \(result.rawValue)."
            }

        case .activation:
            requestInFlight = false
            currentRequestKind = nil

            switch result {
            case .completed:
                refreshExtensionActiveState()
                deactivationPendingReboot = false
                statusMessage = "System extension activated."
                let handler = pendingActivationHandler
                self.pendingActivationHandler = nil
                pendingDeactivationHandler = nil
                handler?()
            case .willCompleteAfterReboot:
                deactivationPendingReboot = false
                statusMessage = "Activation accepted and will complete after reboot."
                pendingActivationHandler = nil
                pendingDeactivationHandler = nil
            @unknown default:
                deactivationPendingReboot = false
                statusMessage = "Activation finished with an unknown result: \(result.rawValue)."
                pendingActivationHandler = nil
                pendingDeactivationHandler = nil
            }

        case .none:
            requestInFlight = false
            statusMessage = "System extension request completed."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        requestInFlight = false
        currentRequestKind = nil
        pendingActivationHandler = nil
        pendingDeactivationHandler = nil
        deactivationPendingReboot = false
        statusMessage = "System extension request failed: \(error.localizedDescription)"
    }
}
