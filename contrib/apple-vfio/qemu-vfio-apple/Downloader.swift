// Downloader.swift — pull a qcow2 image blob from a GHCR OCI artifact,
// resumably, with streaming SHA-256 verification.
//
// Flow:
//
//   1. Parse `ghcr.io/owner/repo:tag` (or @sha256:...) into its pieces.
//   2. Get an anonymous bearer token from ghcr's token endpoint. Works
//      for any public package — no GITHUB_TOKEN needed on the read side.
//   3. Fetch the OCI manifest at /v2/<repo>/manifests/<ref> and pick
//      the first layer (we currently publish single-blob manifests; if
//      that changes we'd pick by mediaType here).
//   4. If the content-addressed cache file for the layer digest already
//      exists at the expected size and hashes correctly, return it.
//   5. Otherwise GET /v2/<repo>/blobs/sha256:<hex> with Authorization
//      and a Range: header pointing past any previously-downloaded
//      .part file. URLSession follows the 307 to the ghcr CDN (the CDN
//      URL is pre-signed and doesn't need auth). Stream the body into
//      the .part file, updating a SHA-256 hasher as we go.
//   6. On completion compare the hash against the manifest digest. If
//      it matches, atomically rename .part to the cached path.
//
// Everything is done synchronously via dispatch semaphores — this is a
// CLI, we don't benefit from async machinery.

import Foundation
import CryptoKit

enum DownloaderError: LocalizedError {
    case badImageRef(String)
    case http(code: Int, url: String, body: String)
    case parse(String)
    case network(String)
    case ioError(String)
    case hashMismatch(expected: String, got: String)
    case packagePrivate(repo: String, settingsURL: String)

    var errorDescription: String? {
        switch self {
        case .badImageRef(let s):           return "bad image reference: \(s)"
        case .http(let c, let u, let b):    return "HTTP \(c) from \(u): \(b.prefix(200))"
        case .parse(let s):                 return "parse error: \(s)"
        case .network(let s):               return "network error: \(s)"
        case .ioError(let s):               return "I/O error: \(s)"
        case .hashMismatch(let e, let g):   return "sha256 mismatch: expected \(e), got \(g)"
        case .packagePrivate(let r, let u):
            let pkgName = r.split(separator: "/").last ?? ""
            return """
            GHCR rejected an anonymous pull token for \(r).
            The package is probably still marked Private.
            Change visibility to Public at:
              \(u)
            or via the CLI:
              gh auth refresh -h github.com -s admin:packages
              gh api -X PATCH /user/packages/container/\(pkgName) -f visibility=public
            """
        }
    }
}

/// Parsed form of `ghcr.io/scottjg/qemu-vfio-apple-images:latest`.
struct ImageRef {
    let registry: String    // "ghcr.io"
    let repo:     String    // "scottjg/qemu-vfio-apple-images"
    let ref:      String    // "latest" or "sha256:..."

    static func parse(_ s: String) throws -> ImageRef {
        // Split off digest (@sha256:...) first, then tag (:...).
        var rest = s
        let ref: String
        if let at = rest.range(of: "@") {
            ref  = String(rest[at.upperBound...])
            rest = String(rest[..<at.lowerBound])
        } else if let colon = rest.range(of: ":", options: .backwards),
                  // A colon inside the registry (e.g. localhost:5000) is not
                  // a tag separator; tag must come after the first `/`.
                  rest[colon.lowerBound...].contains("/") == false
        {
            ref  = String(rest[colon.upperBound...])
            rest = String(rest[..<colon.lowerBound])
        } else {
            ref = "latest"
        }

        // rest is now "<registry>/<repo>". Registry is the part before the
        // first slash iff it contains a dot or colon (otherwise the whole
        // thing is a repo on the default registry — but we only target
        // ghcr here so we require a registry prefix).
        guard let firstSlash = rest.firstIndex(of: "/") else {
            throw DownloaderError.badImageRef(s)
        }
        let registry = String(rest[..<firstSlash])
        let repo     = String(rest[rest.index(after: firstSlash)...])
        if registry.isEmpty || repo.isEmpty {
            throw DownloaderError.badImageRef(s)
        }
        return ImageRef(registry: registry, repo: repo, ref: ref)
    }
}

// MARK: - Public entry point

/// Resolve `ref`, download its blob if missing, and return the local
/// path to the cached base qcow2. Idempotent and cheap when up to date.
func downloadImageIfNeeded(ref refStr: String,
                           cache: CacheLayout) throws -> URL
{
    let ref = try ImageRef.parse(refStr)
    log("resolving \(refStr)")

    let token = try getAnonymousToken(for: ref)
    let (digest, size) = try fetchLayerDigest(ref: ref, token: token)
    let digestHex = try hexOfSha256Digest(digest)

    let cached = cachedImageURL(for: digestHex)
    if FileManager.default.fileExists(atPath: cached.path) {
        let have = cacheFileSize(cached)
        if have == size {
            log("cache hit: \(cached.lastPathComponent) (\(formatBytes(Int(size))))")
            return cached
        }
        // The cached file is content-addressed, so reaching here means
        // something modified it after we wrote it (concurrent writer,
        // external process, …). Don't silently delete the evidence —
        // park it next to the cache as `.bad-<timestamp>` so the user
        // can poke at it before the next `prune` reclaims the space.
        // See `quarantineCorruptCachedImage` for the full rationale.
        quarantineCorruptCachedImage(cached, have: have, expected: size)
    }

    try downloadBlob(ref: ref,
                    token: token,
                    digest: digest,
                    expectedSize: size,
                    cachedPath: cached)
    return cached
}

/// Move a cached image whose on-disk size no longer matches the manifest
/// out of the way before re-downloading. We rename instead of unlinking
/// so the user can:
///
///   1. Confirm whether the trailing bytes look like more qcow2 / HTTP
///      response headers / zeros (each suggests a different culprit;
///      see the comment above the call site).
///   2. Recover anything if the corruption turns out to have a benign
///      explanation.
///
/// Naming is `<original>.bad-<unix-seconds>` so multiple bad copies pile
/// up in timestamp order rather than clobbering each other. `cmdPrune`
/// removes these sidecars opportunistically.
func quarantineCorruptCachedImage(_ cached: URL, have: Int64, expected: Int64) {
    let ts = Int(Date().timeIntervalSince1970)
    let sidecar = cached.appendingPathExtension("bad-\(ts)")
    let fm = FileManager.default
    do {
        try fm.moveItem(at: cached, to: sidecar)
        warn("cached file has wrong size (\(have) vs \(expected))")
        warn("  preserved as \(sidecar.lastPathComponent) for inspection")
        warn("  (run `qemu-vfio-apple prune` to reclaim the space)")
        if have > expected {
            // Most useful diagnostic: the bytes immediately past where
            // the legit image should have ended. Tell the user how to
            // look without doing it for them — `xxd` output would just
            // dump megabytes into their terminal.
            warn("  inspect the suffix with:")
            warn("    xxd -s \(expected) -l 64 \(shellQuoteForLog(sidecar.path))")
        }
    } catch {
        // Renaming failed (cross-volume? perms?). Fall back to the old
        // behaviour so we don't deadlock the user — at least they can
        // still boot.
        warn("cached file has wrong size (\(have) vs \(expected)), re-downloading")
        warn("  (could not preserve for inspection: \(error.localizedDescription))")
        try? fm.removeItem(at: cached)
    }
}

/// Tiny shell-quoter used only for the diagnostic `xxd` line above.
/// We don't want to import VMLauncher's `shellQuote` here because that
/// file isn't part of the same module boundary in every build mode;
/// duplicating a four-line helper is cheaper than threading it.
private func shellQuoteForLog(_ s: String) -> String {
    if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=".contains($0) }) {
        return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - GHCR API

/// Returns an anonymous bearer token scoped for pulling `ref`'s repo.
/// Public packages accept the token unauthenticated; private packages
/// would need a real PAT passed via GH_TOKEN, which we haven't wired
/// because the launcher is aimed at published images.
func getAnonymousToken(for ref: ImageRef) throws -> String {
    var comp = URLComponents()
    comp.scheme = "https"
    comp.host   = ref.registry
    comp.path   = "/token"
    comp.queryItems = [
        URLQueryItem(name: "service", value: ref.registry),
        URLQueryItem(name: "scope",   value: "repository:\(ref.repo):pull"),
    ]
    guard let url = comp.url else {
        throw DownloaderError.badImageRef("\(ref.registry)/\(ref.repo)")
    }

    let (data, code) = try syncGet(url: url, headers: [:])
    // A 401 at the unauthenticated token endpoint almost always means
    // the package is marked private. The raw registry error
    // ("UNAUTHORIZED: authentication required") is ambiguous because
    // we *didn't ask* to authenticate — surface something actionable.
    if code == 401 && ref.registry == "ghcr.io" {
        let parts    = ref.repo.split(separator: "/")
        let owner    = parts.first.map(String.init) ?? ""
        let pkgName  = parts.last.map(String.init)  ?? ""
        let pkgURL   = "https://github.com/users/\(owner)/packages/container/\(pkgName)/settings"
        throw DownloaderError.packagePrivate(repo: ref.repo, settingsURL: pkgURL)
    }
    guard code == 200 else {
        throw DownloaderError.http(code: code, url: url.absoluteString,
                                   body: String(data: data, encoding: .utf8) ?? "")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["token"] as? String ?? json["access_token"] as? String
    else {
        throw DownloaderError.parse("missing token in \(url.absoluteString) response")
    }
    return token
}

/// Fetch the image manifest and return (digest, size) of the single
/// qcow2 blob layer we published. When (later) we start shipping
/// base+delta or multi-arch manifests this is the place to handle
/// layer selection / index traversal.
func fetchLayerDigest(ref: ImageRef, token: String) throws -> (String, Int64) {
    let url = URL(string: "https://\(ref.registry)/v2/\(ref.repo)/manifests/\(ref.ref)")!

    // We accept both the modern OCI manifest and Docker v2; ghcr serves
    // either depending on how the artifact was pushed. For an index
    // (multi-manifest descriptor) we'd recurse — out of scope for v1.
    let accept = [
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "*/*",
    ].joined(separator: ", ")

    let (data, code) = try syncGet(url: url, headers: [
        "Authorization": "Bearer \(token)",
        "Accept":        accept,
    ])
    guard code == 200 else {
        throw DownloaderError.http(code: code, url: url.absoluteString,
                                   body: String(data: data, encoding: .utf8) ?? "")
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DownloaderError.parse("manifest is not a JSON object")
    }

    if let mt = json["mediaType"] as? String, mt.contains("index") || mt.contains("list") {
        throw DownloaderError.parse("image reference resolves to a multi-arch index; the launcher does not yet pick a platform (mediaType=\(mt))")
    }

    guard let layers = json["layers"] as? [[String: Any]], !layers.isEmpty else {
        throw DownloaderError.parse("manifest has no layers")
    }

    // Pick the first layer whose mediaType looks like a qcow2 disk. Fall
    // back to layers[0] if no media type matches — matches what `oras push`
    // writes today and leaves room for adding delta layers later.
    let preferredLayer: [String: Any] = layers.first(where: {
        ($0["mediaType"] as? String)?.contains("qcow2") == true
    }) ?? layers[0]

    guard let digest = preferredLayer["digest"] as? String,
          let size   = parseInt64(preferredLayer["size"])
    else {
        throw DownloaderError.parse("layer missing digest/size")
    }

    log("image digest: \(digest)  size: \(formatBytes(Int(size)))")
    return (digest, size)
}

/// JSON can surface integer values as Int, Int64, or NSNumber depending
/// on magnitude and the deserializer's mood; this collapses all three
/// into a single Int64. Returns nil on any other type.
private func parseInt64(_ any: Any?) -> Int64? {
    if let n = any as? Int64   { return n }
    if let n = any as? Int     { return Int64(n) }
    if let n = any as? NSNumber { return n.int64Value }
    return nil
}

/// Convert `sha256:abcd...` into the lowercase-hex digest body.
func hexOfSha256Digest(_ digest: String) throws -> String {
    guard digest.hasPrefix("sha256:") else {
        throw DownloaderError.parse("digest not sha256: \(digest)")
    }
    let hex = String(digest.dropFirst("sha256:".count)).lowercased()
    guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
        throw DownloaderError.parse("malformed sha256 hex: \(hex)")
    }
    return hex
}

// MARK: - Blob download with resume + streaming sha256

/// Download the blob pointed at by `digest`, resuming from any existing
/// `.part` file and verifying the hash as bytes arrive. On success the
/// `.part` file is atomically renamed to `cachedPath`.
func downloadBlob(ref: ImageRef,
                  token: String,
                  digest: String,
                  expectedSize: Int64,
                  cachedPath: URL) throws
{
    let digestHex = try hexOfSha256Digest(digest)
    let partPath  = cachedPathPart(cachedPath)

    // If we have a partial, rehash it to seed the SHA-256 state. This
    // lets us resume a 4+ GB download from where it was cut off; the
    // rehash is I/O bound and completes in seconds even for large files.
    var offset: Int64 = 0
    var hasher = SHA256()
    let fm = FileManager.default
    if fm.fileExists(atPath: partPath.path) {
        let have = cacheFileSize(partPath)
        if have >= expectedSize {
            // Almost certainly stale from a previous mis-sized download.
            warn("partial file at \(partPath.lastPathComponent) is >= expected size, restarting")
            try? fm.removeItem(at: partPath)
        } else {
            log("resuming from \(formatBytes(Int(have))) / \(formatBytes(Int(expectedSize)))")
            try rehashInto(&hasher, fileAt: partPath)
            offset = have
        }
    }

    // Open (or create) the .part file for append-writes.
    if !fm.fileExists(atPath: partPath.path) {
        fm.createFile(atPath: partPath.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: partPath) else {
        throw DownloaderError.ioError("could not open \(partPath.path) for writing")
    }
    defer { try? handle.close() }
    try handle.seekToEnd()

    let url = URL(string: "https://\(ref.registry)/v2/\(ref.repo)/blobs/\(digest)")!
    var headers: [String: String] = [
        "Authorization": "Bearer \(token)",
        "Accept":        "*/*",
    ]
    if offset > 0 {
        headers["Range"] = "bytes=\(offset)-"
    }

    let reporter = ProgressReporter(total: expectedSize, initial: offset)
    try streamGet(url: url, headers: headers) { chunk in
        hasher.update(data: chunk)
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                            count: chunk.count,
                            deallocator: .none)
            handle.write(data)
        }
        reporter.add(chunk.count)
    }

    try handle.close()

    // Final hash check.
    let got = hasher.finalize().hexString
    if got != digestHex {
        try? fm.removeItem(at: partPath)
        throw DownloaderError.hashMismatch(expected: digestHex, got: got)
    }
    let finalSize = cacheFileSize(partPath)
    if finalSize != expectedSize {
        try? fm.removeItem(at: partPath)
        throw DownloaderError.parse("size mismatch: expected \(expectedSize), got \(finalSize)")
    }

    // Atomic rename; if someone else populated the cache while we were
    // downloading, prefer their copy (it's content-addressed so it's the
    // same bytes).
    if fm.fileExists(atPath: cachedPath.path) {
        try? fm.removeItem(at: partPath)
    } else {
        try fm.moveItem(at: partPath, to: cachedPath)
    }
    reporter.finish()
    log("cached \(cachedPath.lastPathComponent)")
}

/// Stream `url` (following redirects) and invoke `onChunk` for each
/// body chunk. URLSession retains Authorization across same-host
/// redirects and drops it on cross-host redirects, which matches the
/// ghcr → pkg-containers (pre-signed) hop we expect.
func streamGet(url: URL,
               headers: [String: String],
               onChunk: @escaping (Data) throws -> Void) throws
{
    final class Delegate: NSObject, URLSessionDataDelegate {
        var onChunk: ((Data) throws -> Void)?
        var error:   Error?
        var httpStatus: Int = 0
        var bodyHead: Data = Data()   // first ~512 bytes captured for error messages
        let done = DispatchSemaphore(value: 0)

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
        {
            if let http = response as? HTTPURLResponse {
                httpStatus = http.statusCode
            }
            completionHandler(.allow)
        }

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard error == nil else { return }
            if httpStatus >= 400 {
                // Collect a bit of the error body for the message.
                if bodyHead.count < 512 {
                    bodyHead.append(data.prefix(512 - bodyHead.count))
                }
                return
            }
            do {
                try onChunk?(data)
            } catch let e {
                error = e
                dataTask.cancel()
            }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
            if let err = err, error == nil { error = err }
            done.signal()
        }
    }

    let delegate = Delegate()
    delegate.onChunk = onChunk

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 3600 * 6  // multi-GB downloads over slow links
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    var req = URLRequest(url: url)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let task = session.dataTask(with: req)
    task.resume()
    delegate.done.wait()

    if delegate.httpStatus >= 400 {
        throw DownloaderError.http(code: delegate.httpStatus,
                                   url: url.absoluteString,
                                   body: String(data: delegate.bodyHead, encoding: .utf8) ?? "")
    }
    if let e = delegate.error {
        throw DownloaderError.network(e.localizedDescription)
    }
}

/// Buffered GET that reads the entire response into memory — used for
/// the small JSON responses (token, manifest), not for blobs.
func syncGet(url: URL, headers: [String: String]) throws -> (Data, Int) {
    var buf = Data()
    var status = 0
    final class Box { var v: Int = 0 }
    let statusBox = Box()

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }

    var req = URLRequest(url: url)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

    let sem = DispatchSemaphore(value: 0)
    var netError: Error?
    session.dataTask(with: req) { data, resp, err in
        if let err = err { netError = err }
        if let http = resp as? HTTPURLResponse { statusBox.v = http.statusCode }
        if let data = data { buf = data }
        sem.signal()
    }.resume()
    sem.wait()
    status = statusBox.v

    if let e = netError {
        throw DownloaderError.network(e.localizedDescription)
    }
    return (buf, status)
}

// MARK: - Helpers

func cachedPathPart(_ u: URL) -> URL { u.appendingPathExtension("part") }

func cacheFileSize(_ u: URL) -> Int64 {
    let attrs = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
    return (attrs[.size] as? NSNumber)?.int64Value ?? 0
}

/// Read `url` in chunks and feed them into `hasher`. Used to re-seed
/// the hash state when resuming a partial download.
func rehashInto(_ hasher: inout SHA256, fileAt url: URL) throws {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        throw DownloaderError.ioError("could not open \(url.path) for rehash")
    }
    defer { try? handle.close() }

    let chunkSize = 4 * 1024 * 1024
    while autoreleasepool(invoking: { () -> Bool in
        let chunk = handle.readData(ofLength: chunkSize)
        if chunk.isEmpty { return false }
        hasher.update(data: chunk)
        return true
    }) {}
}

/// Simple stderr progress bar. Emits at most every 250 ms so the
/// terminal isn't spammed on fast links.
final class ProgressReporter {
    let total: Int64
    var bytes: Int64
    var lastEmit: Date
    let start: Date
    let startBytes: Int64

    init(total: Int64, initial: Int64) {
        self.total = total
        self.bytes = initial
        self.startBytes = initial
        self.start = Date()
        self.lastEmit = Date(timeIntervalSince1970: 0)
    }

    func add(_ n: Int) {
        bytes += Int64(n)
        let now = Date()
        if now.timeIntervalSince(lastEmit) >= 0.25 {
            emit(now: now)
            lastEmit = now
        }
    }

    func finish() {
        emit(now: Date())
        fputs("\n", stderr)
    }

    private func emit(now: Date) {
        let pct = total > 0 ? Double(bytes) / Double(total) * 100 : 0
        let elapsed = now.timeIntervalSince(start)
        let throughput: Double = elapsed > 0
            ? Double(bytes - startBytes) / elapsed
            : 0
        let etaStr: String
        if throughput > 0 && bytes < total {
            let remaining = Double(total - bytes) / throughput
            etaStr = formatDuration(remaining)
        } else {
            etaStr = "--:--"
        }
        let rateStr = formatBytes(Int(throughput)) + "/s"
        let line = String(format: "  %@ / %@  %5.1f%%  %@  ETA %@",
                          formatBytes(Int(bytes)),
                          formatBytes(Int(total)),
                          pct,
                          rateStr,
                          etaStr)
        fputs("\r\(line)        ", stderr)
        fflush(stderr)
    }
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s)
    let h = t / 3600
    let m = (t % 3600) / 60
    let sec = t % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
}

// MARK: - Small extensions

extension Character {
    var isHexDigit: Bool {
        return ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}

extension SHA256.Digest {
    var hexString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}
