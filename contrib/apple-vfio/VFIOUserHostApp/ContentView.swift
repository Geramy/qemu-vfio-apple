// ContentView: setup checklist shown when the host app launches.
//
// Three rows:
//   1. Location:  is the .app in /Applications?
//   2. System extension: is the dext activated?
//   3. CLI tools: is qemu-system-aarch64 installed in ~/.local/bin?
//      (only shown once QEMU is actually bundled into the .app)

import SwiftUI

struct ContentView: View {
    @StateObject private var activationManager = SystemExtensionActivationManager.shared
    @State private var layout = BundleLayout.current
    @State private var cliStateForBundle: CliState = .missing
    @State private var statusMessage: String = ""
    @State private var statusTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                LocationRow(layout: layout)
                ExtensionRow(activationManager: activationManager)
                if hasAnyBundledTool {
                    CliRow(
                        layout: layout,
                        state: cliStateForBundle,
                        onInstall: { runCliAction(install: true) },
                        onUninstall: { runCliAction(install: false) },
                        onAddToPath: { runAddToPath() }
                    )
                }
            }

            Spacer(minLength: 0)

            Divider()

            footer
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 360, idealHeight: 400)
        .onAppear {
            refreshState()
            startPolling()
        }
        .onDisappear { stopPolling() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QEMU VFIO Setup")
                .font(.title2)
                .fontWeight(.semibold)
            Text("This app installs a DriverKit system extension that lets QEMU pass PCI devices through to virtual machines on Apple Silicon. macOS requires the installer to live inside an app bundle in /Applications.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        let isReady = isLocationOK
            && activationManager.isExtensionKnownActive
            && isCliReady
        let footerText = statusMessage.isEmpty
            ? activationManager.statusMessage
            : statusMessage
        return HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer()

            if isReady {
                Label("Ready", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var isLocationOK: Bool {
        if case .ok = locationState(layout) { return true }
        return false
    }

    /// True if any CLI tool was actually compiled/copied into this bundle —
    /// drives whether the CLI row is shown at all.
    private var hasAnyBundledTool: Bool {
        kCliTools.contains { layout.isToolBundled($0) }
    }

    /// "Ready" requires every bundled CLI wrapper to be installed AND for
    /// `~/.local/bin` to be on PATH. If nothing's bundled (UI-only build with
    /// neither qemu nor vfio-ctl), the CLI row isn't shown and the readiness
    /// check skips it entirely.
    private var isCliReady: Bool {
        guard hasAnyBundledTool else { return true }
        guard case .ok = cliStateForBundle else { return false }
        return pathContainsCliDir()
    }

    private func refreshState() {
        layout = BundleLayout.current
        activationManager.refreshExtensionActiveState()
        cliStateForBundle = cliAggregateState(layout)
    }

    private func runCliAction(install: Bool) {
        let actions = install ? installCli(layout) : uninstallCli()
        statusMessage = actions.joined(separator: "; ")
        refreshState()
    }

    private func runAddToPath() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        let rcGuess: String
        switch shellName {
        case "zsh":               rcGuess = "~/.zshrc"
        case "bash":              rcGuess = "~/.bash_profile"
        case "sh", "dash", "ksh": rcGuess = "~/.profile"
        default:                  rcGuess = "(your shell rc file)"
        }

        let confirm = NSAlert()
        confirm.messageText = "Add \(cliInstallDir().path) to PATH?"
        confirm.informativeText = """
            This will append a small managed block to \(rcGuess) so the qemu \
            command is on your PATH in new terminal windows.
            """
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "Add to PATH")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        switch addCliDirToPath() {
        case .alreadyOnPath:
            statusMessage = "Already on PATH."
        case .alreadyConfigured(let file):
            statusMessage = "PATH entry already present in \(file). Open a new terminal window."
        case .appended(let file):
            statusMessage = "Added to \(file). Open a new terminal window for it to take effect."
        case .unsupportedShell(let name, _):
            statusMessage = "Unsupported shell (\(name)). Add \(cliInstallDir().path) to PATH manually."
        case .failed(let err):
            statusMessage = "Failed: \(err)"
        }
        refreshState()
    }

    private func startPolling() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refreshState() }
        }
    }

    private func stopPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}

// MARK: - Row: Location

private struct LocationRow: View {
    let layout: BundleLayout

    var body: some View {
        switch locationState(layout) {
        case .ok:
            ChecklistRow(
                title: "Located in /Applications",
                detail: layout.bundleURL.path,
                state: .ok
            )
        case .wrongPlace(let path):
            ChecklistRow(
                title: "Move to /Applications",
                detail: "Currently at \(path). Drag this app to /Applications, then open it from there.",
                state: .needsAction
            ) {
                Button("Show in Finder") {
                    revealBundleInFinder(layout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Row: System extension

private struct ExtensionRow: View {
    @ObservedObject var activationManager: SystemExtensionActivationManager

    var body: some View {
        if activationManager.isExtensionKnownActive {
            ChecklistRow(
                title: "System extension active",
                detail: activationManager.extensionIdentifier,
                state: .ok
            ) {
                Button("Uninstall Driver") { confirmAndDeactivate() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(activationManager.requestInFlight)
            }
        } else if activationManager.isExtensionWaitingForApproval {
            ChecklistRow(
                title: "Approve system extension",
                detail: "macOS staged the driver but is waiting for you to enable it in System Settings → Login Items & Extensions → Driver Extensions.",
                state: .needsAction
            ) {
                Button("Open Settings") { openSystemSettingsExtensions() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        } else if activationManager.deactivationPendingReboot {
            ChecklistRow(
                title: "Restart required",
                detail: "Reboot the Mac to finish removing the previous version of the driver.",
                state: .needsAction
            )
        } else if activationManager.requestInFlight {
            ChecklistRow(
                title: "Activation in progress…",
                detail: activationManager.statusMessage,
                state: .pending
            )
        } else {
            ChecklistRow(
                title: "Activate system extension",
                detail: "macOS will ask you to approve the driver in System Settings → Privacy & Security.",
                state: .needsAction
            ) {
                HStack(spacing: 8) {
                    Button("Activate") {
                        activationManager.activate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Open Settings") {
                        openSystemSettingsExtensions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func confirmAndDeactivate() {
        let alert = NSAlert()
        alert.messageText = "Uninstall the VFIO driver?"
        alert.informativeText = """
            This will deactivate \(activationManager.extensionIdentifier) and \
            remove it from /Library/SystemExtensions. macOS may require a \
            reboot to finish removing the driver.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            activationManager.deactivate()
        }
    }
}

// MARK: - Row: CLI tools

private struct CliRow: View {
    let layout: BundleLayout
    let state: CliState
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onAddToPath: () -> Void

    /// Names of the CLI tools we actually installed/will install for this
    /// bundle. UI-only builds (no dist/) only ship qemu-vfio-apple.
    private var bundledToolNames: [String] {
        kCliTools.filter { layout.isToolBundled($0) }
    }

    private var toolList: String {
        bundledToolNames.joined(separator: ", ")
    }

    var body: some View {
        switch state {
        case .ok:
            let onPath = pathContainsCliDir()
            ChecklistRow(
                title: onPath
                    ? "CLI tools installed (\(toolList))"
                    : "Add \(cliInstallDir().path) to PATH",
                detail: onPath
                    ? "Wrappers in \(cliInstallDir().path) launch the bundled binaries."
                    : "Installed in \(cliInstallDir().path), but that directory isn't on your PATH — new terminal windows won't find the commands.",
                state: onPath ? .ok : .needsAction
            ) {
                HStack(spacing: 8) {
                    if !onPath {
                        Button("Add to PATH") { onAddToPath() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Button("Uninstall") { onUninstall() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        case .stale(let path, let reason):
            ChecklistRow(
                title: "Reinstall CLI tools",
                detail: "\(path) (\(reason)). Reinstall to point at this app.",
                state: .needsAction
            ) {
                HStack(spacing: 8) {
                    Button("Reinstall") { onInstall() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Remove") { onUninstall() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        case .missing:
            ChecklistRow(
                title: "Install CLI tools",
                detail: "Adds wrappers in \(cliInstallDir().path) for: \(toolList).",
                state: .needsAction
            ) {
                Button("Install") { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Reusable checklist row

private enum RowState {
    case ok
    case needsAction
    case pending
}

private struct ChecklistRow<Trailing: View>: View {
    let title: String
    let detail: String
    let state: RowState
    @ViewBuilder var trailing: () -> Trailing

    init(title: String,
         detail: String,
         state: RowState,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.state = state
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconView
                .font(.title3)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            trailing()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsAction:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .pending:
            ProgressView().controlSize(.small)
        }
    }
}

#Preview {
    ContentView()
}
