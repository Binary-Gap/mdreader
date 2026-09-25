import AppKit

/// Builds the app's NSMenu tree (app menu, File menu, Window menu). Kept separate
/// from `main.swift` so the bootstrap file stays a thin entry point.
enum MainMenuBuilder {
    /// Builds the full NSMenu tree and returns it, ready to assign to
    /// `NSApplication.shared.mainMenu`.
    ///
    /// - Parameters:
    ///   - target: receives the custom File-menu actions (Open…, Open Recent, Close).
    ///   - recentFilesProvider: returns the current recent-files list (most recent
    ///     first); called fresh every time the Open Recent submenu opens.
    ///   - openRecentAction: selector invoked with the chosen `NSMenuItem` (its
    ///     `representedObject` carries the file path) when a recent entry is picked.
    ///   - toggleAlwaysOnTopAction: selector invoked to toggle always-on-top for the
    ///     current key window.
    ///   - alwaysOnTopStateProvider: returns whether the current key window is
    ///     currently always-on-top, polled right before the Window menu opens so the
    ///     checkmark stays correct even when toggled via the keyboard shortcut.
    ///   - toggleThemeAction: selector invoked to flip the app-wide light/dark theme.
    ///   - themeVariantProvider: returns the active theme variant, polled before the
    ///     View menu opens so the toggle item's title/checkmark stay correct even when
    ///     toggled via the keyboard shortcut.
    static func build(
        target: AnyObject,
        recentFilesProvider: @escaping () -> [String],
        openRecentAction: Selector,
        toggleAlwaysOnTopAction: Selector,
        alwaysOnTopStateProvider: @escaping () -> Bool,
        toggleThemeAction: Selector,
        themeVariantProvider: @escaping () -> ThemeVariant
    ) -> NSMenu {
        let mainMenu = NSMenu(title: "MainMenu")

        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem(
            target: target,
            recentFilesProvider: recentFilesProvider,
            openRecentAction: openRecentAction
        ))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem(
            target: target,
            toggleThemeAction: toggleThemeAction,
            themeVariantProvider: themeVariantProvider
        ))
        mainMenu.addItem(goMenuItem(target: target))
        mainMenu.addItem(windowMenuItem(
            target: target,
            toggleAlwaysOnTopAction: toggleAlwaysOnTopAction,
            alwaysOnTopStateProvider: alwaysOnTopStateProvider
        ))
        mainMenu.addItem(helpMenuItem(target: target))

        return mainMenu
    }

    // MARK: - App menu

    private static func appMenuItem() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: appName)

        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - File menu

    private static func fileMenuItem(
        target: AnyObject,
        recentFilesProvider: @escaping () -> [String],
        openRecentAction: Selector
    ) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: "File")

        let openItem = NSMenuItem(title: "Open…",
                                   action: #selector(AppDelegate.openDocument(_:)),
                                   keyEquivalent: "o")
        openItem.target = target
        menu.addItem(openItem)

        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentDelegate = OpenRecentMenuDelegate(
            target: target,
            action: openRecentAction,
            recentFilesProvider: recentFilesProvider
        )
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = recentDelegate
        // Retain the delegate for the menu's lifetime (NSMenu.delegate is weak).
        objc_setAssociatedObject(recentMenu, &openRecentDelegateKey, recentDelegate, .OBJC_ASSOCIATION_RETAIN)
        openRecentItem.submenu = recentMenu
        menu.addItem(openRecentItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Window",
                                    action: #selector(AppDelegate.closeCurrentWindow(_:)),
                                    keyEquivalent: "w")
        closeItem.target = target
        menu.addItem(closeItem)

        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - Go menu (address bar + history)

    private static func goMenuItem(target: AnyObject) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: "Go")
        // AppKit auto-validates Back/Forward via the target's validateMenuItem(_:).
        menu.autoenablesItems = true

        let backItem = NSMenuItem(title: "Back",
                                   action: #selector(AppDelegate.navigateBackMenuItem(_:)),
                                   keyEquivalent: "[")
        backItem.target = target
        menu.addItem(backItem)

        let forwardItem = NSMenuItem(title: "Forward",
                                      action: #selector(AppDelegate.navigateForwardMenuItem(_:)),
                                      keyEquivalent: "]")
        forwardItem.target = target
        menu.addItem(forwardItem)

        menu.addItem(.separator())

        let locationItem = NSMenuItem(title: "Open Location…",
                                       action: #selector(AppDelegate.showAddressBarMenuItem(_:)),
                                       keyEquivalent: "l")
        locationItem.target = target
        menu.addItem(locationItem)

        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - Edit menu (standard responder-chain actions)

    /// Standard Edit menu. Items target nil so AppKit routes each action up the
    /// responder chain to whatever's focused (the WKWebView for doc text, the
    /// address field when editing). Without this menu nothing translates Cmd+C /
    /// Cmd+A etc. into the `copy:` / `selectAll:` actions, so copy silently fails.
    private static func editMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(title: "Undo",
                                   action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo",
                                   action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(redoItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - View menu (theme)

    private static func viewMenuItem(
        target: AnyObject,
        toggleThemeAction: Selector,
        themeVariantProvider: @escaping () -> ThemeVariant
    ) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: "View")

        // Title/checkmark are refreshed by the delegate right before the menu opens.
        let themeItem = NSMenuItem(title: "Light Theme",
                                    action: toggleThemeAction,
                                    keyEquivalent: "d")
        themeItem.keyEquivalentModifierMask = [.command, .shift]
        themeItem.target = target
        menu.addItem(themeItem)

        let themeDelegate = ThemeMenuDelegate(
            themeItem: themeItem,
            themeVariantProvider: themeVariantProvider
        )
        menu.delegate = themeDelegate
        objc_setAssociatedObject(menu, &themeDelegateKey, themeDelegate, .OBJC_ASSOCIATION_RETAIN)

        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - Help menu

    private static func helpMenuItem(target: AnyObject) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: "Help")

        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts",
                                        action: #selector(AppDelegate.showKeyboardShortcutsMenuItem(_:)),
                                        keyEquivalent: "/")
        shortcutsItem.keyEquivalentModifierMask = .command
        shortcutsItem.target = target
        menu.addItem(shortcutsItem)

        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - Window menu

    private static func windowMenuItem(
        target: AnyObject,
        toggleAlwaysOnTopAction: Selector,
        alwaysOnTopStateProvider: @escaping () -> Bool
    ) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let alwaysOnTopItem = NSMenuItem(title: "Always on Top",
                                          action: toggleAlwaysOnTopAction,
                                          keyEquivalent: "")
        alwaysOnTopItem.target = target
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())

        let windowMenuDelegate = AlwaysOnTopMenuDelegate(
            alwaysOnTopItem: alwaysOnTopItem,
            alwaysOnTopStateProvider: alwaysOnTopStateProvider
        )
        menu.delegate = windowMenuDelegate
        objc_setAssociatedObject(menu, &alwaysOnTopDelegateKey, windowMenuDelegate, .OBJC_ASSOCIATION_RETAIN)

        menuItem.submenu = menu
        // Marks this submenu as the standard window-list menu; AppKit appends the
        // per-window list automatically below what's already here.
        NSApp.windowsMenu = menu
        return menuItem
    }
}

// MARK: - Open Recent submenu delegate

/// Rebuilds the Open Recent submenu's items every time it's about to open, so it
/// always reflects the latest recent-files list without polling.
private final class OpenRecentMenuDelegate: NSObject, NSMenuDelegate {
    private weak var target: AnyObject?
    private let action: Selector
    private let recentFilesProvider: () -> [String]

    init(target: AnyObject, action: Selector, recentFilesProvider: @escaping () -> [String]) {
        self.target = target
        self.action = action
        self.recentFilesProvider = recentFilesProvider
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let paths = recentFilesProvider()
        guard !paths.isEmpty else {
            let emptyItem = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }
        for path in paths {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                   action: action,
                                   keyEquivalent: "")
            item.target = target
            item.representedObject = path
            item.toolTip = path
            menu.addItem(item)
        }
    }
}

// MARK: - Always-on-top Window menu delegate

/// Syncs the "Always on Top" item's checked state to the key window right before
/// the Window menu opens, so it stays correct whether toggled via menu or hotkey.
private final class AlwaysOnTopMenuDelegate: NSObject, NSMenuDelegate {
    private let alwaysOnTopItem: NSMenuItem
    private let alwaysOnTopStateProvider: () -> Bool

    init(alwaysOnTopItem: NSMenuItem, alwaysOnTopStateProvider: @escaping () -> Bool) {
        self.alwaysOnTopItem = alwaysOnTopItem
        self.alwaysOnTopStateProvider = alwaysOnTopStateProvider
    }

    func menuWillOpen(_ menu: NSMenu) {
        alwaysOnTopItem.state = alwaysOnTopStateProvider() ? .on : .off
    }
}

// MARK: - Theme View menu delegate

/// Refreshes the theme toggle item right before the View menu opens: the title
/// names the theme it will switch TO (so it reads as an action), and the checkmark
/// shows on when the light theme is currently active. Keeps it correct whether the
/// theme was toggled via menu or the Cmd+Shift+D hotkey.
private final class ThemeMenuDelegate: NSObject, NSMenuDelegate {
    private let themeItem: NSMenuItem
    private let themeVariantProvider: () -> ThemeVariant

    init(themeItem: NSMenuItem, themeVariantProvider: @escaping () -> ThemeVariant) {
        self.themeItem = themeItem
        self.themeVariantProvider = themeVariantProvider
    }

    func menuWillOpen(_ menu: NSMenu) {
        let variant = themeVariantProvider()
        themeItem.title = variant == .dark ? "Light Theme" : "Dark Theme"
        themeItem.state = variant == .light ? .on : .off
    }
}

private var openRecentDelegateKey: UInt8 = 0
private var alwaysOnTopDelegateKey: UInt8 = 0
private var themeDelegateKey: UInt8 = 0
