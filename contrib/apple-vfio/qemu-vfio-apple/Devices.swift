// Devices.swift — `list-devices` subcommand: enumerate every PCI
// endpoint the host sees, show which driver has claimed each one,
// and tell the user which can be used with `-device vfio-apple-pci`.
//
// Data source is IOKit (IOPCIDevice). We walk the service tree, group
// each device by its root port, and annotate the rows with readable
// vendor/device names from the bundled pci.ids database.
//
// For passthrough-only enumeration (what the VM launcher wants, i.e.
// *only* devices bound to our dext) see `Passthrough.swift`. This
// file intentionally surfaces everything — the user usually runs
// `list-devices` to answer "what's on this box and what's bound to
// what?", not to pick a target for passthrough.

import Foundation
import IOKit

// MARK: - Model

enum DriverState {
    case ours              // matched by VFIOUserPCIDriver — ready for vfio-pci
    case other(String)     // matched by another driver (kext or dext class name)
    case none              // no driver attached
}

struct PciEntry {
    let bdf: String        // e.g. "03:00.0" — what host=<BDF> matches on
    let root: String       // root-port registry name, e.g. "pcic1-bridge"
    let vendor: UInt16
    let device: UInt16
    let subVendor: UInt16
    let subDevice: UInt16
    let classCode: UInt32  // bits 0..23 of the PCI 0x08 register: prog | sub<<8 | base<<16
    let name: String
    let driver: DriverState
}

// MARK: - Command

func cmdListDevices() -> Int32 {
    guard let entries = collectPciDevices() else {
        warn("failed to query IOPCIDevice")
        return 1
    }

    // Hide PCI bridges (base class 0x06). They aren't useful for passthrough
    // and IOKit reports synthetic 0:0:0 BDFs for them anyway.
    let endpoints = entries.filter { (($0.classCode >> 16) & 0xff) != 0x06 }
    let sorted = endpoints.sorted { $0.bdf < $1.bdf }

    // A BDF only counts as ambiguous from the dext's perspective if two or
    // more *vfio-user-bound* rows share it — apple_dext_connect() only sees
    // VFIOUserPCIDriver instances, so a collision with an Apple-owned driver
    // is invisible to it and would only confuse the user if we marked it.
    var oursBdfCounts: [String: Int] = [:]
    for e in sorted {
        if case .ours = e.driver {
            oursBdfCounts[e.bdf, default: 0] += 1
        }
    }

    let db = PciIdsDB.shared

    // 2-line-per-device layout, wrapped to the terminal width (default 80).
    // Single-row column tables blow well past 200 chars once pci.ids names
    // come into play — we'd rather read the device name in one piece than
    // truncate it.
    //
    //   [*] BB:DD.F  VVVV:DDDD  <name, wrapped>
    //                           <class · driver · root>
    //
    // The marker column is 4 chars ("[*] " or "    "), and a `!` after the
    // BDF flags collisions (two or more vfio-user bound devices sharing the
    // same bus:dev.func across different host roots). Continuation lines
    // and the detail line align to col 24.
    let term = max(60, terminalWidth() ?? 80)
    let indent = String(repeating: " ", count: 24)
    let bodyWidth = term - indent.count

    var anyOurs = false
    var anyCollision = false
    for (i, e) in sorted.enumerated() {
        if i > 0 { print("") }

        let isOurs: Bool
        if case .ours = e.driver { isOurs = true } else { isOurs = false }
        if isOurs { anyOurs = true }
        let collide = isOurs && (oursBdfCounts[e.bdf] ?? 0) > 1
        if collide { anyCollision = true }

        let mark = isOurs ? "[*] " : "    "
        // Pad BDF to 8 chars so VVVV:DDDD always lines up; the `!` slot
        // either holds an exclamation (collision) or a space.
        let bdfCol = e.bdf + (collide ? "!" : " ")
        let ids = String(format: "%04x:%04x", Int(e.vendor), Int(e.device))
        let prefix = "\(mark)\(bdfCol) \(ids)  "

        let nameLines = wrap(displayName(for: e, db: db), width: bodyWidth)
        print("\(prefix)\(nameLines.first ?? "")")
        for line in nameLines.dropFirst() {
            print("\(indent)\(line)")
        }

        // Detail line: class · driver · root. We always print the root
        // since users often need to confirm which physical port a device
        // sits behind, and it's required to disambiguate collisions.
        let details = "\(pciClassDescription(e.classCode)) · " +
                      "\(driverDisplay(e.driver)) · " +
                      "root \(e.root)"
        for line in wrap(details, width: bodyWidth) {
            print("\(indent)\(line)")
        }
    }
    print("")
    if db == nil {
        print("note: pci.ids database not found — showing IOKit names only.")
        print("      Re-bundle the app or set PCI_IDS=/path/to/pci.ids.")
        print("")
    }
    if anyOurs {
        print("[*] = bound to vfio-user; pass through with:")
        if anyCollision {
            print("        qemu-system-aarch64 ... \\")
            print("            -device vfio-apple-pci,host=<BDF>,host-root=<ROOT>")
        } else {
            print("        qemu-system-aarch64 ... -device vfio-apple-pci,host=<BDF>")
        }
    }
    if anyCollision {
        print("")
        print("[!] = two or more vfio-user devices share this BDF; add")
        print("      `host-root=<ROOT>` (shown in the detail line) to disambiguate.")
    }
    print("")
    print("Only devices bound to vfio-user can be passed through. macOS doesn't")
    print("let you detach Apple's built-in drivers at runtime, so to add another")
    print("device you have to extend the dext's IOKitPersonalities match list")
    print("(by vendor/device id) and rebuild + reinstall the driver.")
    return 0
}

private func driverDisplay(_ state: DriverState) -> String {
    switch state {
    case .ours:           return "vfio-user (this driver)"
    case .other(let cls): return cls
    case .none:           return "(unbound)"
    }
}

/// Render the human-readable NAME column for a PCI entry.
///
/// Preference order:
///   1. pci.ids: "<vendor> <device> [subsystem]" — most informative,
///      e.g. "NVIDIA Corporation GA102 [GeForce RTX 3080]"
///   2. pci.ids vendor only + IOKit name when the device id is unknown
///   3. IOKit registry name as a last resort (e.g. "wlan", "display",
///      "pci10de,22e8" for unmatched endpoints)
private func displayName(for e: PciEntry, db: PciIdsDB?) -> String {
    guard let db = db else { return e.name }
    let info = db.lookup(vendor: e.vendor, device: e.device,
                         subVendor: e.subVendor, subDevice: e.subDevice)
    var parts: [String] = []
    if let v = info.vendorName { parts.append(v) }
    if let d = info.deviceName {
        parts.append(d)
    } else if !e.name.isEmpty {
        // We have the vendor name from pci.ids but the chip is unknown;
        // append IOKit's name so the row still says something useful.
        parts.append(e.name)
    }
    if let sub = info.subsystemName,
       sub != info.deviceName,                  // avoid "Foo [Foo]"
       sub != info.vendorName {                 // avoid "Vendor [Vendor]"
        parts.append("[\(sub)]")
    }
    if parts.isEmpty { return e.name }
    return parts.joined(separator: " ")
}

// MARK: - Terminal formatting

/// Best-effort terminal width in columns. Tries TIOCGWINSZ on stdout first
/// (works when piped to `less` is not in play); falls back to the COLUMNS
/// env var; returns nil if both fail so the caller can pick a default.
private func terminalWidth() -> Int? {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        return Int(ws.ws_col)
    }
    if let s = ProcessInfo.processInfo.environment["COLUMNS"],
       let n = Int(s), n > 0 {
        return n
    }
    return nil
}

/// Greedy word-wrap on spaces, to at most `width` columns per line.
/// A single token longer than `width` is left unbroken on its own line —
/// we'd rather overflow slightly than mangle a vendor/device name.
private func wrap(_ text: String, width: Int) -> [String] {
    let words = text.split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
    if words.isEmpty { return [""] }
    var lines: [String] = []
    var line = ""
    for w in words {
        if line.isEmpty {
            line = w
        } else if line.count + 1 + w.count <= width {
            line += " " + w
        } else {
            lines.append(line)
            line = w
        }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

// MARK: - IOKit walk

private func collectPciDevices() -> [PciEntry]? {
    guard let matching = IOServiceMatching("IOPCIDevice") else { return nil }
    var iter: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
    guard kr == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }

    var rows: [PciEntry] = []
    var dev = IOIteratorNext(iter)
    while dev != 0 {
        defer {
            IOObjectRelease(dev)
            dev = IOIteratorNext(iter)
        }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(dev, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { continue }

        let bdf      = parsePcidebug(dict["pcidebug"]) ?? "??:??.?"
        let root     = pciRootNameForDevice(dev) ?? "?"
        let vendor   = readU16Property(dict["vendor-id"])
        let device   = readU16Property(dict["device-id"])
        let subVend  = readU16Property(dict["subsystem-vendor-id"])
        let subDev   = readU16Property(dict["subsystem-id"])
        let cls      = readU32Property(dict["class-code"])
        let driver   = driverStateForPciDevice(dev)

        // Name priority: device-tree `name` ("wlan", "bluetooth-pcie") →
        // registry-entry name (usually the same) → IOName (which is the
        // synthesized "pciVENDOR,DEVICE" form for unmatched endpoints, less
        // useful but always present).
        let name: String
        if let data = dict["name"] as? Data,
           let s = cStringFromData(data), !s.isEmpty {
            name = s
        } else if let s = dict["name"] as? String, !s.isEmpty {
            name = s
        } else if let s = ioRegistryName(dev), !s.isEmpty {
            name = s
        } else if let s = dict["IOName"] as? String, !s.isEmpty {
            name = s
        } else {
            name = "?"
        }

        rows.append(PciEntry(
            bdf: bdf,
            root: root,
            vendor: vendor,
            device: device,
            subVendor: subVend,
            subDevice: subDev,
            classCode: cls,
            name: name,
            driver: driver
        ))
    }
    return rows
}

/// `pcidebug` strings look like "1:0:0" (decimal bus:dev:func). Root-port
/// IOPCIDevices add a parenthesised "(segment:linkid)" suffix that we strip
/// here — the segment is recovered separately by walking up to the root.
/// We format BDF as hex `BB:DD.F` to match the QEMU/Linux vfio-pci syntax
/// that the dext side speaks.
private func parsePcidebug(_ raw: Any?) -> String? {
    guard let s = raw as? String, !s.isEmpty else { return nil }

    var head = s
    if let lp = s.firstIndex(of: "(") {
        head = String(s[..<lp])
    }

    let parts = head.split(separator: ":")
    guard parts.count >= 3,
          let bus = UInt8(parts[0]),
          let dv  = UInt8(parts[1]),
          let fn  = UInt8(parts[2])
    else { return nil }
    return String(format: "%02x:%02x.%x", bus, dv, fn)
}

/// Walk up the IOService plane to the topmost IOPCIDevice ancestor (the
/// root port) and return its registry-entry name (e.g. `pci-bridge0`,
/// `pcic1-bridge`). This is what users see in System Information and is
/// the only stable way to disambiguate endpoints whose hardware bus:dev.func
/// happens to repeat under different roots — Apple Silicon doesn't expose a
/// proper PCI segment id, and the parens in `pcidebug` aren't unique.
private func pciRootNameForDevice(_ dev: io_object_t) -> String? {
    var topmostPCI: io_object_t = 0
    var current: io_object_t = dev
    IOObjectRetain(current)
    while true {
        if isIOPCIDevice(current) {
            if topmostPCI != 0 { IOObjectRelease(topmostPCI) }
            IOObjectRetain(current)
            topmostPCI = current
        }
        var parent: io_object_t = 0
        let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
        IOObjectRelease(current)
        if kr != KERN_SUCCESS || parent == 0 { break }
        current = parent
    }
    defer { if topmostPCI != 0 { IOObjectRelease(topmostPCI) } }
    guard topmostPCI != 0 else { return nil }
    return ioRegistryName(topmostPCI)
}

private func isIOPCIDevice(_ obj: io_object_t) -> Bool {
    var name = [CChar](repeating: 0, count: 128)
    guard IOObjectGetClass(obj, &name) == KERN_SUCCESS else { return false }
    return String(cString: name) == "IOPCIDevice"
}

/// Walk the IOService-plane children of a PCI device to figure out which
/// driver (if any) has matched it. A device has at most one matched driver
/// in practice, but we tolerate multiple children and prefer ours when seen.
///
/// Detection rules:
///   - `CFBundleIdentifier == kDextBundleID` on a child → ours (DriverKit
///     dexts publish their bundle id this way).
///   - Registry-entry name matches the dext class → ours (fallback for
///     when the property dictionary doesn't carry the bundle id).
///   - Any other child → `.other(<registry name>)`. We use the registry
///     name (e.g. `AppleBCMWLANBusInterfacePCIe`, `AppleUSBXHCITR`) since
///     it's the most user-recognisable label IOKit exposes.
private func driverStateForPciDevice(_ pciDev: io_object_t) -> DriverState {
    var iter: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(pciDev, kIOServicePlane, &iter) == KERN_SUCCESS else {
        return .none
    }
    defer { IOObjectRelease(iter) }

    var firstName: String? = nil
    var ours = false
    var child = IOIteratorNext(iter)
    while child != 0 {
        defer {
            IOObjectRelease(child)
            child = IOIteratorNext(iter)
        }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(child, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        {
            if let bid = dict["CFBundleIdentifier"] as? String, bid == kDextBundleID {
                ours = true
            }
        }

        if let name = ioRegistryName(child), !name.isEmpty {
            if firstName == nil { firstName = name }
            if name == "VFIOUserPCIDriver" { ours = true }
        }
    }

    if ours { return .ours }
    if let name = firstName { return .other(name) }
    return .none
}

private func readU16Property(_ v: Any?) -> UInt16 {
    guard let data = v as? Data, data.count >= 2 else { return 0 }
    return data.withUnsafeBytes { bp -> UInt16 in
        let p = bp.bindMemory(to: UInt8.self)
        return UInt16(p[0]) | (UInt16(p[1]) << 8)
    }
}

private func readU32Property(_ v: Any?) -> UInt32 {
    guard let data = v as? Data, data.count >= 4 else { return 0 }
    return data.withUnsafeBytes { bp -> UInt32 in
        let p = bp.bindMemory(to: UInt8.self)
        return UInt32(p[0])
            | (UInt32(p[1]) << 8)
            | (UInt32(p[2]) << 16)
            | (UInt32(p[3]) << 24)
    }
}

private func cStringFromData(_ data: Data) -> String? {
    var bytes = [UInt8](data)
    if !bytes.contains(0) { bytes.append(0) }
    return bytes.withUnsafeBufferPointer { bp -> String? in
        guard let base = bp.baseAddress else { return nil }
        return String(cString: base)
    }
}

private func ioRegistryName(_ obj: io_object_t) -> String? {
    var name = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetName(obj, &name) == KERN_SUCCESS {
        return String(cString: name)
    }
    return nil
}

/// Decode the upper 24 bits of the PCI class register (bits 8..31 of what
/// IOKit stores in `class-code`): base class << 16 | subclass << 8 | progIF.
private func pciClassDescription(_ classCode: UInt32) -> String {
    let baseClass = (classCode >> 16) & 0xff
    let subClass  = (classCode >>  8) & 0xff
    switch (baseClass, subClass) {
    case (0x00, _):    return "Unclassified"
    case (0x01, 0x06): return "SATA controller"
    case (0x01, 0x08): return "NVMe controller"
    case (0x01, _):    return "Storage controller"
    case (0x02, 0x00): return "Ethernet controller"
    case (0x02, 0x80): return "Network controller"
    case (0x02, _):    return "Network controller"
    case (0x03, 0x00): return "VGA controller"
    case (0x03, _):    return "Display controller"
    case (0x04, _):    return "Multimedia"
    case (0x05, _):    return "Memory controller"
    case (0x06, 0x00): return "Host bridge"
    case (0x06, 0x04): return "PCI bridge"
    case (0x06, _):    return "Bridge"
    case (0x07, _):    return "Communication"
    case (0x08, _):    return "System peripheral"
    case (0x0b, _):    return "Processor"
    case (0x0c, 0x03): return "USB controller"
    case (0x0c, _):    return "Serial bus controller"
    case (0x0d, _):    return "Wireless controller"
    case (0x10, _):    return "Encryption controller"
    case (0x11, _):    return "Signal processing"
    default:           return String(format: "class 0x%06x", classCode & 0xffffff)
    }
}
