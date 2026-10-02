import Foundation

/// Human-readable formatting — a direct port of `linux/flinger/core/formats.py`.
///
/// Transmission reports sizes in SI units (1000-based), so we do too. Every
/// function here is pure and AppKit-free; the unit tests assert the same
/// expectations as the Python suite so the two apps read identically.
public enum Format: Sendable {
    public static func size(_ n: Double) -> String {
        var value = n
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if abs(value) < 1000 {
                return unit == "B"
                    ? String(format: "%.0f B", value)
                    : String(format: "%.1f %@", value, unit)
            }
            value /= 1000
        }
        return String(format: "%.1f PB", value)
    }

    public static func size(_ n: Int64) -> String { size(Double(n)) }

    public static func speed(_ n: Double) -> String { "\(size(n))/s" }

    public static func speed(_ n: Int) -> String { speed(Double(n)) }

    /// Compact speed for the menu bar, where every pixel is contested:
    /// "1.2M" rather than "1.2 MB/s". Empty for zero.
    public static func speedShort(_ n: Int) -> String {
        guard n > 0 else { return "" }
        var value = Double(n)
        for unit in ["", "K", "M", "G"] {
            if value < 1000 {
                return value < 10 && !unit.isEmpty
                    ? String(format: "%.1f%@", value, unit)
                    : String(format: "%.0f%@", value, unit)
            }
            value /= 1000
        }
        return String(format: "%.0fT", value)
    }

    public static func eta(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "" }
        if seconds >= 86400 { return "\(seconds / 86400)d \(seconds % 86400 / 3600)h" }
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    public static let statusNames: [Int: String] = [
        0: "Paused",
        1: "Queued to verify",
        2: "Verifying",
        3: "Queued to download",
        4: "Downloading",
        5: "Queued to seed",
        6: "Seeding",
    ]

    public static func statusName(_ code: Int) -> String {
        statusNames[code] ?? "Unknown (\(code))"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    public static func date(_ epoch: Int?) -> String {
        guard let epoch, epoch > 0 else { return "—" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: Remote → local path mapping

    /// Translate a path on the server to its location under a local mount.
    /// Returns nil when the mapping isn't configured or doesn't apply.
    public static func mapRemotePath(_ remotePath: String, remotePrefix: String, localPrefix: String) -> String? {
        guard !remotePath.isEmpty, !remotePrefix.isEmpty, !localPrefix.isEmpty else { return nil }
        let path = trimTrailingSlashes(remotePath)
        let prefix = trimTrailingSlashes(remotePrefix)
        let relative: String
        if path == prefix {
            relative = ""
        } else if path.hasPrefix(prefix + "/") {
            relative = String(path.dropFirst(prefix.count + 1))
        } else {
            return nil
        }
        let local = trimTrailingSlashes(localPrefix)
        return relative.isEmpty ? local : "\(local)/\(relative)"
    }

    /// Deepest common ancestor of the server-side download dirs — used to infer
    /// the share root when no explicit remote prefix is configured.
    public static func commonRemoteRoot(_ paths: [String]) -> String? {
        let absolute = paths
            .filter { !$0.isEmpty && $0.hasPrefix("/") }
            .map { trimTrailingSlashes($0) }
        guard let first = absolute.first else { return nil }

        var common = components(of: first)
        for path in absolute.dropFirst() {
            let parts = components(of: path)
            var shared: [String] = []
            for (a, b) in zip(common, parts) {
                guard a == b else { break }   // common *prefix*, not intersection
                shared.append(a)
            }
            common = shared
            if common.isEmpty { break }
        }
        return common.isEmpty ? nil : "/" + common.joined(separator: "/")
    }

    /// Find where `remoteDir` lives under the local mount.
    ///
    /// Tries the prefix mapping first, then falls back to suffix probing: walk
    /// remoteDir's path suffixes (longest first) and take the first one that
    /// exists under the mount — this self-discovers the alignment even when the
    /// share is exported at a different depth than the configured/derived
    /// prefix. Only ever returns a path that exists locally.
    public static func resolveLocalPath(
        remoteDir: String,
        remotePrefix: String,
        localPrefix: String,
        exists: (String) -> Bool
    ) -> String? {
        guard !remoteDir.isEmpty, !localPrefix.isEmpty else { return nil }
        if let mapped = mapRemotePath(remoteDir, remotePrefix: remotePrefix, localPrefix: localPrefix),
           exists(mapped) {
            return mapped
        }
        let parts = components(of: remoteDir)
        let local = trimTrailingSlashes(localPrefix)
        for i in parts.indices {
            let candidate = local + "/" + parts[i...].joined(separator: "/")
            if exists(candidate) { return candidate }
        }
        return nil
    }

    /// Best-effort human name for a magnet URI or .torrent path.
    public static func linkDisplayName(_ link: String) -> String {
        if link.hasPrefix("magnet:") {
            let query = link.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
                .dropFirst().first.map(String.init) ?? ""
            if let dn = queryValue(named: "dn", in: query), !dn.isEmpty { return dn }
            return "(magnet link)"
        }
        let last = trimTrailingSlashes(link).split(separator: "/").last.map(String.init) ?? ""
        let name = last.removingPercentEncoding ?? last
        return name.isEmpty ? link : name
    }

    // MARK: Name truncation

    /// File extensions worth keeping visible when a name is shortened. An
    /// allowlist rather than "whatever follows the last period", so
    /// `filename.otherinfo` isn't mistaken for a file and `[YTS.MX]` isn't an
    /// extension `MX]`. Lower-case; matching is case-insensitive. Mirrored in
    /// the Python core (`KNOWN_EXTENSIONS`) — keep the two lists identical.
    public static let knownExtensions: Set<String> = [
        // video
        "mkv", "mp4", "m4v", "avi", "mov", "wmv", "mpg", "mpeg", "ts", "m2ts", "webm",
        "flv", "vob", "ogv", "3gp", "divx",
        // audio
        "mp3", "flac", "aac", "m4a", "m4b", "ogg", "opus", "wav", "wma", "ape", "alac",
        "aiff", "dsf",
        // images
        "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff", "svg",
        // documents and books
        "pdf", "epub", "mobi", "azw", "azw3", "cbr", "cbz", "djvu", "txt", "doc",
        "docx", "rtf",
        // archives and disk images
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img",
        "dmg", "pkg", "exe", "msi", "apk", "deb", "rpm", "appimage", "bin",
        // subtitles and torrent-adjacent
        "srt", "sub", "idx", "ass", "ssa", "vtt", "nfo", "sfv", "par2", "cue", "torrent",
    ]

    /// Split a torrent name into stem and trailing file extension (`".mkv"`),
    /// so the list can keep the extension visible when it shortens the name.
    /// Only `knownExtensions` count, and the stem must be non-empty; otherwise
    /// `(name, "")`.
    public static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard knownExtensions.contains(ext.lowercased()) else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Shorten `name` from the end while keeping its extension:
    /// `Reacher.S04E05.1080p.WEB-DL.mkv` becomes `Reacher.S04E05.1080p…mkv`.
    ///
    /// `fits` is the caller's measurement — points on screen, characters in a
    /// test — and must be monotone (if a string fits, so does every prefix of
    /// it). The ellipsis replaces the extension's period so the break reads
    /// as one mark; trailing spaces and periods on the kept stem are dropped
    /// for the same reason. Returns the name untouched when it fits, and the
    /// bare `…ext` tail when nothing does.
    public static func truncateName(_ name: String, fits: (String) -> Bool) -> String {
        if fits(name) { return name }
        let (stem, ext) = splitExtension(name)
        let tail = "…" + ext.dropFirst()
        let characters = Array(stem)
        func candidate(_ n: Int) -> String {
            var kept = characters[..<n]
            while let last = kept.last, last == " " || last == "." { kept.removeLast() }
            return String(kept) + tail
        }
        var lo = 0
        var hi = characters.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(candidate(mid)) { lo = mid } else { hi = mid - 1 }
        }
        return candidate(lo)
    }

    // MARK: Helpers

    private static func trimTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out == "/" ? "" : out
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// `parse_qs`-compatible lookup: `+` means space, then percent-decode.
    private static func queryValue(named key: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2, String(halves[0]) == key else { continue }
            let raw = halves[1].replacingOccurrences(of: "+", with: " ")
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }
}
