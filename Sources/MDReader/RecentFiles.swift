import Foundation

/// Tracks recently-opened markdown files, persisted to JSON so the sidebar
/// history survives across app launches and is shared by every window.
enum RecentFiles {
    private static let maxEntries = 20

    private static var storeURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/mdreader/recent-files.json")
    }

    /// Record a file as just opened, moving it to the front if already present
    /// and trimming the list to `maxEntries`.
    static func record(_ path: String) {
        var paths = readRaw()
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > maxEntries {
            paths.removeLast(paths.count - maxEntries)
        }
        write(paths)
    }

    /// Drop a file from the recent-files store entirely (user removed it from
    /// the sidebar). No-op if the path isn't present.
    static func remove(_ path: String) {
        var paths = readRaw()
        let before = paths.count
        paths.removeAll { $0 == path }
        guard paths.count != before else { return }
        write(paths)
    }

    /// Recently-opened paths, most recent first, filtered to files that still
    /// exist on disk. Stale entries are left in the store untouched (they only
    /// drop off the front-facing list, not the persisted file) and naturally
    /// age out as `record` trims the list.
    static func list() -> [String] {
        readRaw().filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func readRaw() -> [String] {
        guard let data = try? Data(contentsOf: storeURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    private static func write(_ paths: [String]) {
        let url = storeURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
