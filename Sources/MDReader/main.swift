import AppKit

// `--dump-css` prints a slice of the document stylesheet and exits, so the VS Code
// extension can generate its preview theme from this app. Checked before anything
// touches NSApplication, which keeps the dump a pure headless stdout command.
CSSDump.runIfRequested()

// Manual NSApplication bootstrap (no @main / NSApplicationMain), so the delegate
// is assigned before the app starts and CommandLine arguments resolve cleanly.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate

// Regular app: shows in Dock, can become key/active so the WebView gets keystrokes.
application.setActivationPolicy(.regular)

application.mainMenu = MainMenuBuilder.build(
    target: appDelegate,
    recentFilesProvider: { RecentFiles.list() },
    openRecentAction: #selector(AppDelegate.openRecentFile(_:)),
    toggleAlwaysOnTopAction: #selector(AppDelegate.toggleAlwaysOnTopMenuItem(_:)),
    alwaysOnTopStateProvider: { appDelegate.keyWindowController?.isAlwaysOnTop ?? false },
    toggleThemeAction: #selector(AppDelegate.toggleThemeMenuItem(_:)),
    themeVariantProvider: { appDelegate.currentThemeVariant }
)

application.run()
