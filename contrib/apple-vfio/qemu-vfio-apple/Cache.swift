// Cache.swift — on-disk layout for downloaded base images + per-VM state.
//
// Two directories matter:
//
//   ~/Library/Caches/<host-app-id>.qemu-vfio-apple/images/
//       Content-addressed cache of downloaded qcow2 blobs. Each file is
//       named `sha256-<hex>.qcow2`. Pulling the same digest twice is a
//       no-op; switching tags that happen to point at the same digest
//       share storage. Safe to `rm -rf` — `qemu-vfio-apple pull` will
//       re-populate.
//
//   ~/Library/Application Support/<host-app-id>.qemu-vfio-apple/vms/<name>/
//       Per-VM *mutable* state. The overlay qcow2 (writable, backed by
//       a file in images/) and the EFI vars file live here. Deleting
//       this directory throws away VM progress but not the base image.
//
// Splitting these two follows Apple's guidance: Caches is wiped by the
// system under disk pressure and excluded from Time Machine by default;
// Application Support is preserved. We want users to lose downloaded
// images but keep their VM state on cleanup.
//
// The directory name matches this tool's PRODUCT_BUNDLE_IDENTIFIER
// (`<host-app-id>.qemu-vfio-apple`) so state sits under the host app's
// reverse-DNS namespace on disk and a forker's renamed app gets its
// own state directory.

import Foundation

struct CacheLayout {
    let root:      URL   // ~/Library/Caches/<kBundleDirName>
    let imagesDir: URL   // root/images
    let supportRoot: URL // ~/Library/Application Support/<kBundleDirName>
    let vmsDir:    URL   // supportRoot/vms
}

/// Bundle id of the host VFIOUserHostApp, resolved at runtime.
///
/// When this CLI runs from inside the .app (the sanctioned path — the
/// `~/.local/bin` shim execs into `Contents/MacOS/qemu-vfio-apple`),
/// `Bundle.main` walks up to the .app's Info.plist and returns the host
/// app's id directly.
///
/// When run standalone (e.g. straight out of `Build/Products/Debug` for
/// dev iteration), there's no .app parent so `Bundle.main` falls back to
/// this binary's embedded `__TEXT,__info_plist` section
/// (CREATE_INFOPLIST_SECTION_IN_BINARY = YES on the qemu-vfio-apple
/// target). That returns the CLI tool's own bundle id, which by
/// convention is `<host-app-id>.qemu-vfio-apple` — strip the suffix to
/// recover the host app id.
///
/// Used here for the cache/state directory names and by Driver.swift to
/// derive the dext bundle id (`<host-app-id>.VFIOUserPCIDriver`). Means a
/// forker can rename `PRODUCT_BUNDLE_IDENTIFIER` for the three targets in
/// Xcode's UI without touching any Swift source.
func hostAppBundleID() -> String {
    let mainID = Bundle.main.bundleIdentifier ?? ""
    let toolSuffix = ".qemu-vfio-apple"
    if mainID.hasSuffix(toolSuffix) {
        return String(mainID.dropLast(toolSuffix.count))
    }
    return mainID
}

let kBundleDirName = hostAppBundleID() + ".qemu-vfio-apple"

/// Produce the cache layout and create any missing directories. Called
/// at the top of every subcommand — cheap on hot path (FileManager just
/// returns success if the directory already exists).
func ensureCacheLayout() -> CacheLayout {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser

    let cacheRoot = home
        .appendingPathComponent("Library/Caches")
        .appendingPathComponent(kBundleDirName)
    let imagesDir = cacheRoot.appendingPathComponent("images")

    let supportRoot = home
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent(kBundleDirName)
    let vmsDir = supportRoot.appendingPathComponent("vms")

    for url in [cacheRoot, imagesDir, supportRoot, vmsDir] {
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            die("failed to create \(url.path): \(error.localizedDescription)")
        }
    }

    return CacheLayout(root: cacheRoot,
                       imagesDir: imagesDir,
                       supportRoot: supportRoot,
                       vmsDir: vmsDir)
}

/// Content-addressed path inside the images cache for the given sha256
/// (lowercase hex, no `sha256:` prefix). The `.part` sibling is used
/// during download and atomically renamed on completion.
func cachedImageURL(for digestHex: String) -> URL {
    let cache = ensureCacheLayout()
    return cache.imagesDir.appendingPathComponent("sha256-\(digestHex).qcow2")
}

func cachedImagePartURL(for digestHex: String) -> URL {
    cachedImageURL(for: digestHex).appendingPathExtension("part")
}

/// Directory holding writable state for the VM whose name is `vmName`.
/// Created on first access.
func vmStateDirURL(for vmName: String) -> URL {
    let cache = ensureCacheLayout()
    let dir = cache.vmsDir.appendingPathComponent(vmName)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Path to the per-VM writable qcow2 overlay. Created lazily by
/// VMLauncher via `qemu-img create -b <cached-base>`.
func overlayURL(for vmName: String) -> URL {
    vmStateDirURL(for: vmName).appendingPathComponent("overlay.qcow2")
}

/// Path to the per-VM mutable EFI vars file. Created on first boot by
/// copying the bundled template.
func efiVarsURL(for vmName: String) -> URL {
    vmStateDirURL(for: vmName).appendingPathComponent("edk2-aarch64-vars.fd")
}

/// Resolve the overlay URL to use, honoring an explicit `--overlay`
/// override. When overridden we also create the parent directory so
/// users can drop an overlay anywhere writable.
func resolvedOverlayURL(_ opts: Options) -> URL {
    if let override = opts.overlayPath {
        let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return url
    }
    return overlayURL(for: opts.vmName)
}
