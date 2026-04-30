// SPDX-License-Identifier: GPL-2.0-or-later
//
// Lookup helper for the upstream `pci.ids` database
// (https://pci-ids.ucw.cz/), which we ship inside the host app's
// Resources at build time. The format is text with three indent levels:
//
//   vendor   vendor name
//   <TAB>device   device name
//   <TAB><TAB>subvendor subdevice  subsystem name
//
// Lines starting with `#` are comments and bare `C` (after the device
// list) introduces the class-code section, which we currently ignore —
// pciClassDescription() in Devices.swift already gives nice class names.

import Foundation

final class PciIdsDB {

    struct DeviceInfo {
        let vendorName: String?
        let deviceName: String?
        let subsystemName: String?
    }

    // MARK: - Lookup

    /// Look up `vendor`, `device`, and (optionally) the
    /// subsystem-vendor/subsystem-device pair. Any field that is absent
    /// from the database is returned as `nil` — callers should fall back
    /// to the raw hex.
    func lookup(vendor: UInt16,
                device: UInt16,
                subVendor: UInt16,
                subDevice: UInt16) -> DeviceInfo {
        let v = vendors[vendor]
        let d = v?.devices[device]
        var sub: String? = nil
        if subVendor != 0 || subDevice != 0 {
            let key = (UInt32(subVendor) << 16) | UInt32(subDevice)
            sub = d?.subsystems[key]
        }
        return DeviceInfo(vendorName: v?.name,
                          deviceName: d?.name,
                          subsystemName: sub)
    }

    // MARK: - Loading

    /// Resolve and parse the bundled pci.ids file. Returns `nil` if the
    /// file isn't present, can't be read, or doesn't look like pci.ids.
    /// Loading is lazy and one-shot: a process only ever reads the file
    /// the first time we render `qemu-vfio-apple list-devices`.
    static let shared: PciIdsDB? = PciIdsDB.loadDefault()

    private static func loadDefault() -> PciIdsDB? {
        guard let url = resolveURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let db = PciIdsDB()
        db.parse(data)
        return db.vendors.isEmpty ? nil : db
    }

    /// Walks every plausible location for pci.ids:
    ///   1. `$PCI_IDS` env var (developer override)
    ///   2. The .app bundle's Resources/ next to firmware (installed app)
    ///   3. Same directory as the executable (xcodebuild Debug build)
    ///   4. Common system paths (homebrew / pciutils)
    /// Returns the first one that exists and is readable.
    private static func resolveURL() -> URL? {
        let fm = FileManager.default

        if let env = ProcessInfo.processInfo.environment["PCI_IDS"],
           !env.isEmpty, fm.isReadableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }

        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            // Inside an .app: .../Foo.app/Contents/MacOS/qemu-vfio-apple
            //                                ^^^^^^^^
            //                                we want Contents/Resources/pci.ids
            let macos = exe.deletingLastPathComponent()
            let contents = macos.deletingLastPathComponent()
            if contents.lastPathComponent == "Contents" {
                let res = contents.appendingPathComponent("Resources/pci.ids")
                if fm.isReadableFile(atPath: res.path) { return res }
            }
            // Sibling file (handy for `swift run`-style builds and for
            // dropping a fresh copy next to the binary during dev).
            let sibling = macos.appendingPathComponent("pci.ids")
            if fm.isReadableFile(atPath: sibling.path) { return sibling }
        }

        for p in [
            "/opt/homebrew/share/misc/pci.ids",
            "/usr/local/share/misc/pci.ids",
            "/usr/share/misc/pci.ids",
            "/opt/homebrew/share/pciutils/pci.ids",
        ] {
            if fm.isReadableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    // MARK: - Internals

    private final class Device {
        let name: String
        // Subsystem key is (subvendor << 16) | subdevice — 32 bits is plenty
        // and keeps lookups branchless without nested dictionaries.
        var subsystems: [UInt32: String] = [:]
        init(name: String) { self.name = name }
    }

    private final class Vendor {
        let name: String
        var devices: [UInt16: Device] = [:]
        init(name: String) { self.name = name }
    }

    private var vendors: [UInt16: Vendor] = [:]

    /// Parse the pci.ids text into the in-memory tables. We only walk the
    /// file once at startup, but we still try to be allocation-stingy: we
    /// scan UTF-8 bytes directly and only build Strings for the trailing
    /// human-readable name on each line.
    private func parse(_ data: Data) {
        var current: Vendor? = nil
        var currentDev: Device? = nil

        // We accept LF line endings only — pci.ids upstream is unix.
        // `Data.split` here is fine; the file is ~1.5 MB and we do this
        // exactly once per process.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)

        for raw in lines {
            if raw.isEmpty { continue }
            // Strip carriage returns just in case.
            let line: Data.SubSequence = (raw.last == 0x0D)
                ? raw.dropLast() : raw

            if line.isEmpty { continue }
            // Comments start with '#'.
            if line.first == 0x23 /* '#' */ { continue }

            // Class-code section starts with "C ". We don't use it.
            // Everything from there on either starts with 'C' at indent 0
            // or with TAB(s) under one of those Cs — none of which clash
            // with hex digits, so we can just stop on the first 'C ' line.
            if line.first == 0x43 /* 'C' */ &&
               line.count >= 2 && line[line.startIndex + 1] == 0x20 /* ' ' */ {
                break
            }

            // Vendor lines: "VVVV  Vendor name"
            if line.first != 0x09 /* TAB */ {
                guard let v = parseVendor(line) else { continue }
                current = v.vendor
                currentDev = nil
                vendors[v.id] = v.vendor
                continue
            }

            // Device or subsystem lines have at least one TAB.
            // Single TAB → device. Two TABs → subsystem. The file always
            // uses real tabs for indentation.
            let after1 = line.index(after: line.startIndex)
            if after1 == line.endIndex { continue }
            if line[after1] == 0x09 /* second TAB */ {
                // Subsystem line: "\t\tSSSS DDDD  Subsystem name"
                let body = line[line.index(after: after1)...]
                guard let dev = currentDev else { continue }
                guard let (sub, name) = parseSubsystem(body) else { continue }
                dev.subsystems[sub] = name
            } else {
                // Device line: "\tDDDD  Device name"
                let body = line[after1...]
                guard let vend = current else { continue }
                guard let (id, name) = parseHexNameLine(body, hexLen: 4)
                else { continue }
                let dev = Device(name: name)
                vend.devices[UInt16(id & 0xffff)] = dev
                currentDev = dev
            }
        }
    }

    // Parsed-vendor return type so we can hand both the id and the object
    // back without the caller hashing twice.
    private struct ParsedVendor { let id: UInt16; let vendor: Vendor }

    private func parseVendor(_ line: Data.SubSequence) -> ParsedVendor? {
        guard let (id, name) = parseHexNameLine(line, hexLen: 4) else { return nil }
        return ParsedVendor(id: UInt16(id & 0xffff), vendor: Vendor(name: name))
    }

    /// `body` looks like "VVVV  Some Name". Returns `(value, name)`.
    private func parseHexNameLine(_ body: Data.SubSequence,
                                  hexLen: Int) -> (UInt32, String)? {
        guard body.count >= hexLen + 2 else { return nil }
        var value: UInt32 = 0
        var idx = body.startIndex
        for _ in 0..<hexLen {
            guard let nyb = hexNibble(body[idx]) else { return nil }
            value = (value << 4) | UInt32(nyb)
            idx = body.index(after: idx)
        }
        // Skip whitespace separator (always two spaces in upstream pci.ids
        // but we tolerate any run of spaces).
        while idx < body.endIndex && body[idx] == 0x20 {
            idx = body.index(after: idx)
        }
        guard idx < body.endIndex else { return nil }
        let nameBytes = body[idx...]
        guard let name = String(bytes: nameBytes, encoding: .utf8),
              !name.isEmpty
        else { return nil }
        return (value, name)
    }

    /// Subsystem line body: "SSSS DDDD  Subsystem name".
    /// Returns `((subvend << 16) | subdev, name)`.
    private func parseSubsystem(_ body: Data.SubSequence) -> (UInt32, String)? {
        guard body.count >= 4 + 1 + 4 + 2 else { return nil }
        var idx = body.startIndex

        var sv: UInt32 = 0
        for _ in 0..<4 {
            guard let nyb = hexNibble(body[idx]) else { return nil }
            sv = (sv << 4) | UInt32(nyb)
            idx = body.index(after: idx)
        }
        guard body[idx] == 0x20 else { return nil }
        idx = body.index(after: idx)

        var sd: UInt32 = 0
        for _ in 0..<4 {
            guard let nyb = hexNibble(body[idx]) else { return nil }
            sd = (sd << 4) | UInt32(nyb)
            idx = body.index(after: idx)
        }

        while idx < body.endIndex && body[idx] == 0x20 {
            idx = body.index(after: idx)
        }
        guard idx < body.endIndex else { return nil }
        guard let name = String(bytes: body[idx...], encoding: .utf8),
              !name.isEmpty
        else { return nil }

        return ((sv << 16) | sd, name)
    }

    @inline(__always)
    private func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30                 // '0'-'9'
        case 0x61...0x66: return b - 0x61 + 10            // 'a'-'f'
        case 0x41...0x46: return b - 0x41 + 10            // 'A'-'F'
        default:          return nil
        }
    }
}
