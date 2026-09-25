import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [MainWindowController] = []

    // Resolved when launched via `application(_:openFile:)` before didFinishLaunching.
    private var pendingOpenFilePath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resolvedPath = pendingOpenFilePath ?? markdownPathFromCommandLine()

        // `open -g` deliberately suppresses activation so a background test
        // launch doesn't steal focus; WKWebView's window server compositing
        // is then starved and the content never paints. MDREADER_FORCE_ACTIVATE
        // overrides this for automated screenshot/test workflows that need a
        // freshly-launched, unfocused window to render immediately.
        let forceActivate = ProcessInfo.processInfo.environment["MDREADER_FORCE_ACTIVATE"] != nil

        guard let path = resolvedPath else {
            // No file passed: replay the previous session's windows if any,
            // otherwise fall back to a single empty window.
            if !restorePreviousSession() {
                openEmptyWindow()
            }
            NSApp.activate(ignoringOtherApps: forceActivate)
            return
        }

        openWindow(forFileAt: path)
        NSApp.activate(ignoringOtherApps: forceActivate)
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
    }

    // MARK: - Session restore/persist

    /// Reopen every window from the last saved session, restoring each file,
    /// frame, and sidebar state. Returns false if there was nothing to restore.
    private func restorePreviousSession() -> Bool {
        let states = Session.load().windows
        guard !states.isEmpty else { return false }
        for state in states {
            // Skip files that have since vanished; still restore empty windows.
            if let path = state.filePath,
               !FileManager.default.fileExists(atPath: path) {
                continue
            }
            let controller = MainWindowController(filePath: state.filePath)
            controller.onOpenInNewWindow = { [weak self] newPath in
                self?.openWindow(forFileAt: newPath)
            }
            track(controller)
            controller.apply(windowState: state)
        }
        // Every saved window pointed at a now-missing file: fall back to empty.
        return !windowControllers.isEmpty
    }

    /// Snapshot the currently open windows to disk, front-to-back.
    private func saveSession() {
        let states = windowControllers.map { $0.windowState }
        Session(windows: states).save()
    }

    // Handles `open -a MDReader file.md` and Finder "Open With". Fires before
    // applicationDidFinishLaunching when launching, so we stash the path.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let path = absolutePath(for: filename)
        guard FileManager.default.fileExists(atPath: path) else {
            presentMissingFileError(path)
            return false
        }

        if NSApp.isRunning {
            openWindow(forFileAt: path)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingOpenFilePath = path
        }
        return true
    }

    /// The window controller behind the current key window, if any. Used by the
    /// Window menu's always-on-top item, which acts on whichever window is frontmost
    /// rather than a fixed target.
    var keyWindowController: MainWindowController? {
        windowControllers.first { $0.window === NSApp.keyWindow }
    }

    // MARK: - Menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.init(filenameExtension: "md"), .init(filenameExtension: "markdown")].compactMap { $0 }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(forFileAt: url.path)
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openWindow(forFileAt: path)
    }

    @objc func closeCurrentWindow(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func toggleAlwaysOnTopMenuItem(_ sender: NSMenuItem) {
        guard let controller = keyWindowController else { return }
        controller.toggleAlwaysOnTop()
        sender.state = controller.isAlwaysOnTop ? .on : .off
    }

    // MARK: - Go menu (address bar + history)

    @objc func showAddressBarMenuItem(_ sender: Any?) {
        keyWindowController?.showAddressBarMenuItem(sender)
    }

    @objc func navigateBackMenuItem(_ sender: Any?) {
        keyWindowController?.navigateBackMenuItem(sender)
    }

    @objc func navigateForwardMenuItem(_ sender: Any?) {
        keyWindowController?.navigateForwardMenuItem(sender)
    }

    // MARK: - Help menu

    @objc func showKeyboardShortcutsMenuItem(_ sender: Any?) {
        keyWindowController?.toggleKeyboardShortcuts()
    }

    // MARK: - View menu (theme)

    /// The active theme variant, polled by the View menu to label/check its item.
    var currentThemeVariant: ThemeVariant { ThemeVariant.current }

    @objc func toggleThemeMenuItem(_ sender: Any?) {
        switchTheme(to: ThemeVariant.current.toggled)
    }

    /// Flip the app-wide theme variant and rebuild every open window in place so
    /// each surface (webview CSS, sidebar, navbar, window bg) picks up the new
    /// theme. Each window's file/frame/sidebar/zoom is preserved by snapshotting
    /// its `windowState` and re-applying it to the fresh controller; the previously
    /// key window is re-keyed.
    private func switchTheme(to variant: ThemeVariant) {
        guard variant != ThemeVariant.current else { return }
        ThemeVariant.current = variant

        let previousKey = NSApp.keyWindow
        let oldControllers = windowControllers
        var newKeyController: MainWindowController?

        for controller in oldControllers {
            let state = controller.windowState
            let wasKey = controller.window === previousKey

            let replacement = MainWindowController(filePath: state.filePath)
            replacement.onOpenInNewWindow = { [weak self] newPath in
                self?.openWindow(forFileAt: newPath)
            }
            track(replacement)
            replacement.apply(windowState: state)

            controller.window?.close()

            if wasKey { newKeyController = replacement }
        }

        newKeyController?.window?.makeKeyAndOrderFront(self)
    }

    /// Enables/disables the Back and Forward items to match the key window's
    /// history position. Consulted by NSMenuValidation before the Go menu opens.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(navigateBackMenuItem(_:)):
            return keyWindowController?.canGoBack ?? false
        case #selector(navigateForwardMenuItem(_:)):
            return keyWindowController?.canGoForward ?? false
        default:
            return true
        }
    }

    // MARK: - Helpers

    private func markdownPathFromCommandLine() -> String? {
        // arguments[0] is the executable path; the first real arg is the file.
        let args = CommandLine.arguments.dropFirst()
        guard let raw = args.first(where: { !$0.hasPrefix("-") }) else {
            return nil
        }
        let path = absolutePath(for: raw)
        guard FileManager.default.fileExists(atPath: path) else {
            presentMissingFileError(path)
            return nil
        }
        return path
    }

    // Resolves a relative path against the current working directory (matches the
    // Lua viewer's `cwd .. "/" .. path` behavior); expands a leading `~`.
    private func absolutePath(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    private func openWindow(forFileAt path: String) {
        // A file launched via `open --args` arrives both as a command-line arg and
        // as an Apple Event open-doc, so the same path can be requested twice.
        // Reuse an existing window for a path already showing instead of duplicating.
        if let existing = windowControllers.first(where: { $0.filePath == path }) {
            existing.showWindow(self)
            existing.window?.makeKeyAndOrderFront(self)
            return
        }
        let controller = MainWindowController(filePath: path)
        controller.onOpenInNewWindow = { [weak self] newPath in
            self?.openWindow(forFileAt: newPath)
        }
        track(controller)
    }

    /// Opens a window with no file loaded, showing the recent-files empty state.
    private func openEmptyWindow() {
        let controller = MainWindowController()
        controller.onOpenInNewWindow = { [weak self] newPath in
            self?.openWindow(forFileAt: newPath)
        }
        track(controller)
    }

    /// Registers a freshly-created window controller (shows it, makes it key, and
    /// removes it from `windowControllers` once its window closes). Shared by both
    /// `openWindow(forFileAt:)` and `openEmptyWindow()`.
    private func track(_ controller: MainWindowController) {
        windowControllers.append(controller)
        controller.onToggleTheme = { [weak self] in
            self?.toggleThemeMenuItem(nil)
        }
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)

        if let window = controller.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.windowControllers.removeAll { $0 === controller }
            }
        }
    }

    private func presentMissingFileError(_ path: String) {
        let alert = NSAlert()
        alert.messageText = "File not found"
        alert.informativeText = "Could not open markdown file:\n\(path)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
