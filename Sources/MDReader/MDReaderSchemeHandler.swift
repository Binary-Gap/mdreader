import Foundation
import WebKit

/// Serves `mdreader://` URLs as themed HTML so every app-controlled document
/// (empty state, local file, remote markdown) is a real WKWebView back-forward
/// item. Web pages are already real http(s) items, so WKWebView's native list
/// becomes the single navigation source of truth.
final class MDReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdreader"

    private let renderer: MarkdownRenderer
    // Tasks still live (not yet stopped). Guards against responding to a task
    // WKWebView already stopped (which throws). Touched only on the main thread.
    private var liveTasks = Set<ObjectIdentifier>()

    init(renderer: MarkdownRenderer) {
        self.renderer = renderer
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        liveTasks.insert(ObjectIdentifier(task))
        guard let url = task.request.url else {
            respond(task, html: renderer.html(forMarkdown: "# Invalid URL"), baseHref: nil)
            return
        }
        switch url.host {
        case "empty":
            respond(task, html: renderer.emptyStateHTML(recentPaths: RecentFiles.list()), baseHref: nil)
        case "file":
            guard let path = Self.queryValue(url, "path") else {
                respond(task, html: Self.errorHTML(renderer, "Missing file path"), baseHref: nil); return
            }
            let dir = (path as NSString).deletingLastPathComponent
            // Trailing slash + percent-encoding so <base href> is a valid dir URL.
            let baseHref = URL(fileURLWithPath: dir, isDirectory: true).absoluteString
            respond(task, html: renderer.html(forMarkdownAt: path), baseHref: baseHref)
        case "remote-md":
            guard let raw = Self.queryValue(url, "url"), let remote = URL(string: raw) else {
                respond(task, html: Self.errorHTML(renderer, "Missing/invalid URL"), baseHref: nil); return
            }
            fetchRemote(remote, for: task)
        default:
            respond(task, html: Self.errorHTML(renderer, "Unknown mdreader host"), baseHref: nil)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(task))
    }

    // MARK: - Remote fetch

    private func fetchRemote(_ url: URL, for task: WKURLSchemeTask) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let html: String
                let baseHref = url.deletingLastPathComponent().absoluteString
                if let data, error == nil, let text = String(data: data, encoding: .utf8) {
                    html = self.renderer.html(forMarkdown: text)
                } else {
                    let msg = error?.localizedDescription ?? "Could not fetch \(url.absoluteString)"
                    html = Self.errorHTML(self.renderer, msg)
                }
                self.respond(task, html: html, baseHref: baseHref)
            }
        }.resume()
    }

    // MARK: - Responding (guarded)

    private func respond(_ task: WKURLSchemeTask, html: String, baseHref: String?) {
        // Drop if WKWebView already stopped this task (responding then throws).
        guard liveTasks.contains(ObjectIdentifier(task)), let requestURL = task.request.url else { return }
        let injected = Self.injectBaseHref(html, baseHref: baseHref)
        let data = Data(injected.utf8)
        let response = URLResponse(url: requestURL, mimeType: "text/html",
                                   expectedContentLength: data.count, textEncodingName: "utf-8")
        // didReceive/didFinish throw an ObjC exception if the task was stopped between
        // the guard and here; the liveTasks guard + main-thread confinement make that
        // window effectively nil, but keep the calls last so a stop mid-emit is rare.
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
        liveTasks.remove(ObjectIdentifier(task))
    }

    // MARK: - Helpers

    private static func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    private static func errorHTML(_ renderer: MarkdownRenderer, _ message: String) -> String {
        renderer.html(forMarkdown: "# Could not open\n\n\(message)")
    }

    /// Splice `<base href="…">` right after `<head>` so relative resources resolve
    /// against the real file/remote directory instead of the mdreader URL.
    private static func injectBaseHref(_ html: String, baseHref: String?) -> String {
        guard let baseHref, let range = html.range(of: "<head>") else { return html }
        var out = html
        out.replaceSubrange(range, with: "<head>\n<base href=\"\(baseHref)\">")
        return out
    }
}
