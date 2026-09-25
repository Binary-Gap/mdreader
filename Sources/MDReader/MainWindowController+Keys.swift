import AppKit

extension MainWindowController {

    // MARK: - Key handling

    private var isAddressFieldEditing: Bool { navBar.isAddressFieldEditing }

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only the key window's controller should act, so multiple open
            // windows don't all react to one keystroke. The event's `window` is
            // unreliable here (key events routed to the out-of-process WKWebView
            // content arrive without it set), so compare against NSApp.keyWindow.
            guard self.window === NSApp.keyWindow else { return event }
            // When the address field is being edited, let all keys reach the field
            // editor (so bare-key vim bindings don't hijack typing). The field's own
            // delegate handles Return/Escape.
            if self.isAddressFieldEditing { return event }
            guard let action = self.keyMap.action(for: event) else {
                // Unbound key. A bare-key press (no Command) reaching the end of the
                // responder chain unhandled makes AppKit play the system beep, so
                // swallow it. Command-combos pass through so menu items / system
                // shortcuts still work (and legitimately beep when truly invalid).
                let mods = event.modifierFlags.intersection([.command])
                return mods.isEmpty ? nil : event
            }
            self.perform(action)
            // Swallow the event so it does not propagate (e.g. system beep).
            return nil
        }
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case .scrollDown:
            scrollBy(Self.lineScrollAmount)
        case .scrollUp:
            scrollBy(-Self.lineScrollAmount)
        case .scrollTop:
            scrollToTop()
        case .scrollBottom:
            scrollToBottom()
        case .halfPageDown:
            scrollByPageFraction(Self.halfPageFraction)
        case .halfPageUp:
            scrollByPageFraction(-Self.halfPageFraction)
        case .toggleAlwaysOnTop:
            toggleAlwaysOnTop()
        case .toggleSidebar:
            toggleSidebar()
        case .reload:
            webView.reload()
        case .zoomIn:
            adjustMagnification(by: Self.magnificationStep)
        case .zoomOut:
            adjustMagnification(by: -Self.magnificationStep)
        case .showAddressBar:
            showAddressBar()
        case .navigateBack:
            goBack()
        case .navigateForward:
            goForward()
        case .showKeyboardShortcuts:
            toggleKeyboardShortcuts()
        case .toggleTheme:
            onToggleTheme?()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    // MARK: - Keyboard-shortcuts cheat sheet

    /// Toggle the shortcuts modal injected into the current document. Shows it if
    /// absent, dismisses it if already on screen (so a repeat of the trigger key
    /// closes it, matching the Esc/backdrop dismissals wired inside the overlay JS).
    func toggleKeyboardShortcuts() {
        webView.evaluateJavaScript(KeyboardShortcutsOverlay.isVisibleJS) { [weak self] result, _ in
            guard let self else { return }
            if let visible = result as? Bool, visible {
                self.evaluate(KeyboardShortcutsOverlay.dismissJS)
            } else {
                let js = KeyboardShortcutsOverlay.showJS(rows: self.keyMap.shortcutRows(),
                                                         theme: self.theme,
                                                         magnification: self.webView.magnification)
                self.evaluate(js)
            }
        }
    }

    // MARK: - Scrolling (via JS, scroll target is the window per spec §3 standalone mode)

    private func scrollBy(_ delta: CGFloat) {
        evaluate("window.scrollBy(0, \(delta));")
    }

    private func scrollByPageFraction(_ fraction: CGFloat) {
        evaluate("window.scrollBy(0, window.innerHeight * \(fraction));")
    }

    private func scrollToTop() {
        evaluate("window.scrollTo(0, 0);")
    }

    private func scrollToBottom() {
        evaluate("window.scrollTo(0, document.body.scrollHeight);")
    }

    private func evaluate(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Always-on-top

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
    }

    // MARK: - Zoom (webview magnification)

    private func adjustMagnification(by delta: CGFloat) {
        let target = webView.magnification + delta
        let clamped = min(max(target, Self.minMagnification), Self.maxMagnification)
        // Anchor zoom at the view center for a stable feel.
        let center = NSPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        webView.setMagnification(clamped, centeredAt: center)
        // Remember this zoom so newly opened files (and the next launch) match it.
        Self.persistedMagnification = clamped
    }
}
