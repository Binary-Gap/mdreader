import AppKit
import WebKit

extension MainWindowController: WKNavigationDelegate, WKUIDelegate {

    // MARK: - Content loading

    /// First load on launch: the open file, or the empty state.
    func loadInitial() {
        if let filePath {
            loadMDReader(.file(filePath))
        } else {
            loadMDReader(.empty)
        }
    }

    /// Load an app-controlled document as an `mdreader://` request so it becomes a
    /// real WKWebView back-forward item (the scheme handler serves the themed HTML).
    func loadMDReader(_ doc: NavDocument) {
        guard let url = doc.mdreaderURL else { return }
        webView.load(URLRequest(url: url))
    }

    /// Replace this window's document with a different file (used when a
    /// sidebar entry is clicked without Cmd). Joins WKWebView's back-forward list.
    func openFile(_ path: String) {
        loadMDReader(.file(path))
    }

    /// Records the current file in recent-files history and refreshes the
    /// sidebar's highlight. Fires once per distinct file so history walks that
    /// re-commit the same file don't reshuffle the list.
    private func recordOpen() {
        guard let filePath, filePath != lastRecordedPath else { return }
        lastRecordedPath = filePath
        RecentFiles.record(filePath)
        sidebar.currentPath = filePath
    }

    // MARK: - Navigation delegate

    /// Routes webview navigations through the app's own navigation pipeline:
    /// - `mdreader-recent:` links (empty-state recent files) open the chosen file.
    /// - `mdreader://` (served by the scheme handler) and `file://` relative loads
    ///   are allowed in place.
    /// - User-clicked http(s) links go through `navigate(toAddress:)` so a `.md`
    ///   target is fetched and rendered on the theme (matching address-bar behavior).
    /// Programmatic http(s) loads (raw web nav) pass through.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Empty-state recent-file links.
        if url.scheme == "mdreader-recent" {
            decisionHandler(.cancel)
            // URL parsing strips the "mdreader-recent:" scheme prefix into `path` only for
            // scheme-relative URLs; here the remainder is the absolute file path, which
            // surfaces via `absoluteString` minus the scheme rather than `.path`.
            let encodedPath = String(url.absoluteString.dropFirst("mdreader-recent:".count))
            guard let path = encodedPath.removingPercentEncoding else { return }
            openFile(path)
            return
        }

        // Our own scheme (handler serves it) and file:// relative loads: allow in place.
        if url.scheme == MDReaderSchemeHandler.scheme || url.scheme == "file" {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            // Back/forward navigations are replayed verbatim: never rewrite or re-theme a
            // page reached via history. Otherwise returning to a github.com `/blob/` page
            // (or any page whose URL our classifier would re-theme) would get cancelled and
            // redirected forward again, so Back appears dead. Let WKWebView's list stand.
            if navigationAction.navigationType == .backForward {
                decisionHandler(.allow)
                return
            }
            // Any http(s) nav that resolves to raw markdown BYTES (a .md/.markdown URL,
            // or a github.com blob/edit/raw file view) is cancelled here — BEFORE it
            // commits as a history item — and re-loaded through the themed remote-md
            // path. Catching it pre-commit (rather than after, in chrome sync) keeps the
            // unrendered raw page out of the back-forward list, so Back works. Covers
            // both link clicks and JS-routed navigations (e.g. GitHub's "Raw" button).
            if let rawMarkdownURL = Self.rawMarkdownSource(for: url) {
                decisionHandler(.cancel)
                filePath = nil
                loadMDReader(.remoteMarkdown(url: rawMarkdownURL.absoluteString))
                return
            }
            // A user-clicked link to a non-markdown http(s) target: run it through the
            // same classifier the address bar uses (so relative resolution + web loads
            // stay consistent). Programmatic/JS web loads pass through untouched.
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                navigate(toAddress: url.absoluteString)
                return
            }
        }

        decisionHandler(.allow)
    }

    /// A link with `target="_blank"` / `rel="noopener"` (or a `window.open`) asks
    /// WebKit for a fresh webview instead of navigating the current frame, so it
    /// never reaches `decidePolicyFor`. We open no new window (single-window reader):
    /// route the requested URL through the same classifier used for clicks and the
    /// address bar, so a linked `.md` (incl. a GitHub `/raw`/`/blob` link) renders
    /// themed in this window. Returning nil tells WebKit not to create a webview.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            navigate(toAddress: url.absoluteString)
        }
        return nil
    }

    /// mdreader:// + normal http loads commit here; JS-routed web sub-navigations
    /// bypass the delegate and are caught by the KVO `url` observer instead. Both
    /// funnel into `syncChromeFromURL`.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncChromeFromURL()
    }

    /// After a live-reload reload finishes, restore the pre-reload scroll offset.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        restorePendingScrollIfNeeded()
    }

    /// GitHub ships Hotwire Turbo, whose thin `.turbo-progress-bar` is shown/hidden via
    /// inline `opacity`/`visibility` (never removed from the DOM). On a WebKit back-forward
    /// restore, Turbo can resurrect a snapshot that froze the bar mid-animation, so it
    /// stays painted. Force the inline styles hidden (matching Turbo's own hide) on GitHub
    /// pages so Back doesn't leave the loading sliver lit. Native Back semantics and
    /// bfcache are untouched; purely cosmetic, page-side.
    private func removeOrphanedTurboProgressBar() {
        guard let host = webView.url?.host,
              host == "github.com" || host.hasSuffix(".github.com") else { return }
        let js = """
        var bar = document.querySelector('.turbo-progress-bar');
        if (bar) { bar.style.opacity = '0'; bar.style.visibility = 'hidden'; bar.style.width = '0'; }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        // A back-forward snapshot restore can repaint the frozen bar AFTER this runs;
        // re-apply once the restore settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Chrome sync

    /// Derive window chrome (filePath, title, address prefill, nav buttons) from the
    /// current webView.url. Single source of truth = WKWebView's back-forward list.
    func syncChromeFromURL() {
        guard let url = webView.url else { return }
        let addressText: String
        if url.scheme == MDReaderSchemeHandler.scheme {
            switch url.host {
            case "empty":
                filePath = nil
                window?.title = Self.windowTitle(for: nil)
                addressText = ""
            case "file":
                let path = Self.mdreaderQuery(url, "path") ?? ""
                filePath = path.isEmpty ? nil : path
                window?.title = Self.windowTitle(for: filePath)
                addressText = filePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
                recordOpen()
                updateFileWatcher(for: filePath)
            case "remote-md":
                let remote = Self.mdreaderQuery(url, "url") ?? ""
                filePath = nil
                window?.title = Self.remoteTitle(for: remote)
                addressText = remote
                updateFileWatcher(for: nil)
            default:
                filePath = nil
                window?.title = "MDReader"
                addressText = ""
                updateFileWatcher(for: nil)
            }
        } else {
            // Raw web page (http(s)).
            filePath = nil
            let str = url.absoluteString
            window?.title = Self.remoteTitle(for: str)
            addressText = str
            updateFileWatcher(for: nil)
        }
        removeOrphanedTurboProgressBar()
        lastAddressText = addressText
        // Keep a visible bar in sync when the document changes from elsewhere
        // (sidebar pick, in-doc link), but never stomp text the user is typing.
        if isNavBarVisible && !navBar.isAddressFieldEditing {
            navBar.setAddressText(addressText)
        }
        refreshNavButtons()
    }

    /// If `url` is an http(s) page whose bytes are raw markdown that we should render
    /// themed rather than show as source, return the URL to FETCH (canonicalized).
    /// Returns nil otherwise (real web page, or a github.com app page like `/blob/`
    /// that only *looks* like `.md` but serves HTML — its `.raw`/`.blob` form maps to
    /// raw.githubusercontent.com via `canonicalGitHubRawURL`, which is what we fetch).
    static func rawMarkdownSource(for url: URL) -> URL? {
        // A github.com blob/edit/raw URL: only its canonical raw form serves bytes.
        if url.host == "github.com" || url.host == "www.github.com" {
            guard let raw = canonicalGitHubRawURL(url) else { return nil }
            return raw
        }
        // Any other host: trust the .md/.markdown extension (raw.githubusercontent.com,
        // gists' raw host, a plain server serving a .md file, etc.).
        return looksLikeMarkdown(url) ? url : nil
    }

    private static func mdreaderQuery(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - Live reload (watch the open file on disk)

    /// Point the file watcher at `path` (or tear it down for nil / non-file docs).
    /// Rebuilds only when the target path actually changes so history walks that
    /// re-commit the same file don't churn the watcher.
    func updateFileWatcher(for path: String?) {
        guard path != watchedPath else { return }
        watchedPath = path
        guard let path else {
            fileWatcher = nil
            return
        }
        fileWatcher = FileWatcher(path: path) { [weak self] in
            self?.reloadCurrentFile()
        }
    }

    /// Re-render the open file after an on-disk change, preserving scroll position.
    /// Reloading re-runs the mdreader://file scheme request, which re-reads the
    /// file bytes; the captured scrollY is restored once the new content commits.
    func reloadCurrentFile() {
        guard filePath != nil,
              let url = webView.url, url.scheme == MDReaderSchemeHandler.scheme,
              url.host == "file" else { return }
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self] result, _ in
            guard let self else { return }
            if let pair = result as? [NSNumber], pair.count == 2 {
                self.pendingScrollRestore = (pair[0].doubleValue, pair[1].doubleValue)
            }
            self.webView.reload()
        }
    }

    /// Restore the scroll offset captured before a live reload, if any. Called
    /// once the reloaded document finishes loading.
    func restorePendingScrollIfNeeded() {
        guard let (x, y) = pendingScrollRestore else { return }
        pendingScrollRestore = nil
        webView.evaluateJavaScript("window.scrollTo(\(x), \(y));", completionHandler: nil)
    }

    // MARK: - Menu actions

    /// Reveal + focus the address bar (Go > Location, Cmd+L).
    @objc func showAddressBarMenuItem(_ sender: Any?) {
        showAddressBar()
    }

    /// Walk back in history (Go > Back, Cmd+[).
    @objc func navigateBackMenuItem(_ sender: Any?) {
        goBack()
    }

    /// Walk forward in history (Go > Forward, Cmd+]).
    @objc func navigateForwardMenuItem(_ sender: Any?) {
        goForward()
    }

    // MARK: - Back/forward (WKWebView native list is authoritative)

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
            refreshNavButtons()
        }
    }

    func goForward() {
        if webView.canGoForward {
            webView.goForward()
            refreshNavButtons()
        }
    }

    func refreshNavButtons() {
        navBar.updateNavButtons(canGoBack: canGoBack, canGoForward: canGoForward)
        navPill.updateNavButtons(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    // MARK: - Address bar

    /// Reveal the docked address bar, pushing the webview top down to its bottom so
    /// both the bar and the content are fully visible. Hides the floating pill (the
    /// bar's own hamburger + back/forward take over) while shown.
    func showAddressBar() {
        guard !isNavBarVisible else {
            navBar.focusAddress(prefill: lastAddressText)
            return
        }
        isNavBarVisible = true
        navBar.isHidden = false
        navBar.alphaValue = 0
        // Sidebar open -> its header hosts the toggle; otherwise show it in the bar.
        navBar.setShowsHamburger(!isSidebarVisible)
        navBar.updateNavButtons(canGoBack: canGoBack, canGoForward: canGoForward)
        updateNavPillVisibility()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            navBarHeightConstraint?.animator().constant = NavBarView.barHeight
            navBar.animator().alphaValue = 1
            contentContainer.layoutSubtreeIfNeeded()
        }
        navBar.focusAddress(prefill: lastAddressText)
    }

    func hideAddressBar() {
        guard isNavBarVisible else { return }
        isNavBarVisible = false
        // Drop first-responder focus back to the webview so vim keys work again.
        window?.makeFirstResponder(webView)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            navBarHeightConstraint?.animator().constant = 0
            navBar.animator().alphaValue = 0
            contentContainer.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, !self.isNavBarVisible else { return }
            self.navBar.isHidden = true
            self.navBar.alphaValue = 1
        })
        updateNavPillVisibility()
    }

    private static func remoteTitle(for url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return "\(host) - MDReader"
    }

    /// Classify a submitted address (local path or http(s) URL) and navigate to it.
    /// Local paths / file:// open as a file; http(s) that looks like raw markdown is
    /// fetched and rendered through the themed renderer; any other http(s) loads raw
    /// in the webview.
    func navigate(toAddress address: String) {
        hideAddressBar()

        // http(s): remote.
        if let parsed = URL(string: address), let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            // A github.com blob/edit URL serves the GitHub app HTML, not the file;
            // rewrite it to raw.githubusercontent.com so the .md fetch gets real markdown.
            let url = Self.canonicalGitHubRawURL(parsed) ?? parsed
            if Self.looksLikeMarkdown(url) {
                loadMDReader(.remoteMarkdown(url: url.absoluteString))   // handler fetches
            } else {
                webView.load(URLRequest(url: url))                        // raw web = real http item
            }
            return
        }

        // Otherwise treat as a local filesystem path (supports ~ and file://).
        let path = Self.resolveLocalPath(address)
        guard FileManager.default.fileExists(atPath: path) else {
            presentAddressError("File not found: \(path)")
            return
        }
        loadMDReader(.file(path))
    }

    /// Expand a local path string (file:// URL, ~, or plain path) to an absolute path.
    private static func resolveLocalPath(_ address: String) -> String {
        if address.hasPrefix("file://"), let url = URL(string: address) {
            return url.path
        }
        return (address as NSString).expandingTildeInPath
    }

    /// Rewrite a github.com file-viewing URL to its `raw.githubusercontent.com`
    /// equivalent, which serves the file bytes instead of the GitHub app page (or a
    /// redirect). Handles the `/blob/…` and web-editor `/edit/…` forms (which carry a
    /// branch segment) and the `/raw/…` form (whose tail, e.g. `refs/heads/master/path`,
    /// maps to raw.githubusercontent.com verbatim). Returns nil for any other URL
    /// (including URLs already on raw.githubusercontent.com) so the caller falls back
    /// to the original.
    /// Example: github.com/owner/repo/blob/branch/path -> raw.githubusercontent.com/owner/repo/branch/path.
    static func canonicalGitHubRawURL(_ url: URL) -> URL? {
        guard url.host == "github.com" || url.host == "www.github.com" else { return nil }
        // Path components (leading "/" already filtered out): [owner, repo, keyword, ...].
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4 else { return nil }
        let owner = parts[0], repo = parts[1], keyword = parts[2]

        let rest: String
        switch keyword {
        case "blob", "edit":
            // [owner, repo, keyword, branch, ...path]; strip the keyword only.
            guard parts.count >= 5 else { return nil }
            rest = parts[3...].joined(separator: "/")
        case "raw":
            // [owner, repo, "raw", ...tail]; tail already matches raw host layout.
            rest = parts[3...].joined(separator: "/")
        default:
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.path = "/\(owner)/\(repo)/\(rest)"
        return components.url
    }

    /// Heuristic: does this http(s) URL point at raw markdown we should fetch and
    /// theme, rather than load as a web page? True for a `.md`/`.markdown` path.
    private static func looksLikeMarkdown(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private func presentAddressError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not open address"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

extension MainWindowController: NavBarDelegate {
    func navBar(_ navBar: NavBarView, didSubmitAddress address: String) {
        navigate(toAddress: address)
    }

    func navBarDidRequestDismiss(_ navBar: NavBarView) {
        hideAddressBar()
    }

    // NavControlsDelegate (shared by the docked bar and the floating pill).
    func navControlsDidToggleSidebar() {
        toggleSidebar()
    }

    func navControlsDidGoBack() {
        goBack()
    }

    func navControlsDidGoForward() {
        goForward()
    }
}
