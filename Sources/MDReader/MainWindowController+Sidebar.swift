import AppKit

extension MainWindowController {

    // MARK: - Sidebar (recent files)

    func toggleSidebar() {
        isSidebarVisible.toggle()
        if isSidebarVisible {
            sidebar.reload()
        }
        // Sidebar open -> its header hosts the toggle, so drop the bar's hamburger.
        navBar.setShowsHamburger(!isSidebarVisible)
        // Only expose the resize grab strip while the sidebar is visible.
        sidebarResizeHandle?.isHidden = !isSidebarVisible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            sidebarWidthConstraint?.animator().constant = isSidebarVisible ? sidebarWidth : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        updateNavPillVisibility()
    }

    // MARK: - Floating pill reveal-on-proximity

    /// Polls the pointer location (rather than relying on tracking areas, which a
    /// WKWebView swallows the mouse-moved events for) and updates proximity. Cheap
    /// 10Hz tick.
    func startNavPillProximityTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updatePointerProximity()
        }
        RunLoop.main.add(timer, forMode: .common)
        navPillProximityTimer = timer
    }

    private func updatePointerProximity() {
        guard let window else {
            isPointerNearNavPill = false
            return
        }
        // Pill center in screen coordinates.
        let pillInWindow = navPill.convert(navPill.bounds, to: nil)
        let centerInWindow = NSPoint(x: pillInWindow.midX, y: pillInWindow.midY)
        let centerOnScreen = window.convertPoint(toScreen: centerInWindow)
        let pointer = NSEvent.mouseLocation
        let dx = pointer.x - centerOnScreen.x
        let dy = pointer.y - centerOnScreen.y
        isPointerNearNavPill = (dx * dx + dy * dy).squareRoot() <= Self.navPillRevealRadius
    }

    /// The floating pill fades in on pointer proximity, in both address-bar states.
    /// It's suppressed while the address bar is open (the bar's own chrome takes
    /// over) and while the sidebar is open (its header hosts the toggle, and the
    /// pill would sit under the shifted content). The pill drops its own hamburger
    /// while the sidebar is open so it never duplicates the header toggle.
    func updateNavPillVisibility() {
        navPill.showsHamburger = !isSidebarVisible
        let shouldShow = isPointerNearNavPill && !isNavBarVisible
        let targetAlpha: CGFloat = shouldShow ? 1 : 0
        guard navPill.alphaValue != targetAlpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            navPill.animator().alphaValue = targetAlpha
        }
    }
}

extension MainWindowController: SidebarViewControllerDelegate {
    func sidebar(_ sidebar: SidebarViewController, didSelectPath path: String, openInNewWindow: Bool) {
        if openInNewWindow {
            onOpenInNewWindow?(path)
        } else {
            openFile(path)
        }
    }

}
