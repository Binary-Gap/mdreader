import AppKit
import Foundation

/// Persisted state for a single window: the file it shows (nil = empty state),
/// its on-screen frame, and whether the recent-files sidebar was open.
struct WindowState: Codable, Equatable {
    var filePath: String?
    var frame: CGRect
    var sidebarVisible: Bool
    /// Zoom level (WKWebView magnification). Optional so sessions written before
    /// zoom persistence still decode; a nil restores the default 1.0.
    var magnification: CGFloat?
}

/// The whole app session: every open window, in front-to-back order. Written on
/// quit and replayed on the next launch when no file is passed on the command
/// line, so the app reopens exactly the windows (and files) that were open.
struct Session: Codable, Equatable {
    var windows: [WindowState]

    /// Path to the persisted session file. Overridable via MDREADER_SESSION_FILE
    /// so a test run can redirect it away from the user's real session.
    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["MDREADER_SESSION_FILE"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/mdreader/session.json")
    }

    /// Load the last session, or an empty one if the file is absent or invalid
    /// (logs and never crashes).
    static func load() -> Session {
        guard let data = try? Data(contentsOf: fileURL) else {
            return Session(windows: [])
        }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            NSLog("MDReader: invalid session.json (\(error)); starting fresh.")
            return Session(windows: [])
        }
    }

    /// Persist this session, creating the config directory if needed. Failures
    /// are logged and swallowed (a missing session is non-fatal on next launch).
    func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("MDReader: could not save session.json (\(error)).")
        }
    }
}
