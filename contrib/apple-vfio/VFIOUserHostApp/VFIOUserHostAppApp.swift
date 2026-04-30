//
//  VFIOUserHostAppApp.swift
//  VFIOUserHostApp
//
//  Setup-only host app for the VFIOUserPCIDriver dext. Real device interaction
//  happens out-of-process via qemu (bundled at Contents/MacOS/qemu-system-aarch64
//  by the "Embed QEMU" build phase).
//

import AppKit
import SwiftUI

/// Drives the at-launch "move to /Applications" prompt before the SwiftUI
/// window appears. Lives in the app delegate (rather than `App.init`) so we
/// have a real `NSApplication` available for `NSAlert.runModal()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MoveToApplications.runIfNeeded()
    }
}

@main
struct VFIOUserHostAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
