import AppKit
import WebKit

/// An invisible view spanning the titlebar region that initiates window drags.
final class DragStripView: NSView {
    // WKWebView handles mouse events out-of-process, so the implicit
    // mouseDownCanMoveWindow drag never propagates to the window. Start the
    // drag explicitly instead.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Hosts a WKWebView rendering a single markdown file, with vim-style key bindings.
final class MainWindowController: NSWindowController {

    // Default window size from spec-features §4 (DEFAULT_W x DEFAULT_H).
    static let defaultWidth: CGFloat = 700
    static let defaultHeight: CGFloat = 900

    // Scroll amounts (spec-features §3): j/k = 60px, Ctrl+d/u = 0.8 page.
    static let lineScrollAmount: CGFloat = 60
    static let halfPageFraction: CGFloat = 0.8

    // Magnification bounds for zoom.
    static let minMagnification: CGFloat = 0.5
    static let maxMagnification: CGFloat = 3.0
    static let magnificationStep: CGFloat = 0.1

    // Height of the custom drag strip across the titlebar area.
    static let dragStripHeight: CGFloat = 28

    // Floating nav pill geometry (top-left of the content area).
    static let navPillInset: CGFloat = 10
    // When the address bar is hidden, the floating pill only appears while the
    // pointer is within this distance of its top-left resting spot.
    static let navPillRevealRadius: CGFloat = 110

    // Vertical space at the top reserved for the system traffic-light buttons;
    // chrome (the pill / the address bar) sits below this band so it never
    // overlaps them.
    static let titlebarBandHeight: CGFloat = 30

    // UserDefaults key for the persisted (user-resized) open sidebar width.
    static let sidebarWidthDefaultsKey = "MDReaderSidebarWidth"

    // UserDefaults key for the last-used zoom level, shared across all windows so a
    // newly opened file inherits the zoom you last set (and it survives relaunch).
    static let magnificationDefaultsKey = "MDReaderMagnification"

    /// The last zoom the user set, clamped to the allowed range. Defaults to 1.0
    /// when unset (UserDefaults.double returns 0 for a missing key).
    static var persistedMagnification: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: magnificationDefaultsKey)
            guard stored > 0 else { return 1.0 }
            return min(max(CGFloat(stored), minMagnification), maxMagnification)
        }
        set {
            let clamped = min(max(newValue, minMagnification), maxMagnification)
            UserDefaults.standard.set(Double(clamped), forKey: magnificationDefaultsKey)
        }
    }

    // Width of the invisible grab strip straddling the sidebar/content border.
    static let sidebarResizeHandleWidth: CGFloat = 12

    /// nil means this window is showing the empty state (no file open), not
    /// pointing at a real file on disk.
    var filePath: String?
    private let renderer: MarkdownRenderer
    let theme: Theme
    let keyMap: KeyMap
    let webView: WKWebView
    let sidebar: SidebarViewController
    let contentContainer: NSView
    // WKWebViewConfiguration keeps only a weak reference to scheme handlers, so
    // the controller must retain it or mdreader:// loads silently fail.
    private let schemeHandler: MDReaderSchemeHandler

    /// Lets the owning AppDelegate open a fresh window (Cmd-click on a sidebar entry).
    var onOpenInNewWindow: ((String) -> Void)?

    /// Lets the owning AppDelegate flip the app-wide light/dark theme and rebuild
    /// windows. Fired by the toggle-theme keybinding.
    var onToggleTheme: (() -> Void)?

    let navBar: NavBarView
    /// Floating rounded chrome pill (hamburger + back/forward) shown over the
    /// top-left of the content while the address bar is hidden.
    let navPill: NavCluster
    /// The nav bar's height; animated between 0 (hidden) and `NavBarView.barHeight`
    /// (visible). The webview top is pinned to the bar's bottom, so shrinking the bar
    /// slides the content up to fill it.
    var navBarHeightConstraint: NSLayoutConstraint?
    var isNavBarVisible = false
    private var webViewURLObservation: NSKeyValueObservation?
    /// The string last synced into the address field, derived from webView.url.
    var lastAddressText = ""
    /// The last file path recorded into recent-files, to dedup re-commits (e.g.
    /// history walks re-loading the same file).
    var lastRecordedPath: String?

    /// Watches the currently displayed file for on-disk changes and triggers a
    /// live reload. Recreated whenever the displayed file changes; nil for the
    /// empty state and remote/web documents.
    var fileWatcher: FileWatcher?
    /// The path currently being watched, to avoid rebuilding the watcher when
    /// chrome re-syncs to the same file (e.g. history walks).
    var watchedPath: String?
    /// Scroll offset (x, y) captured before a live reload, restored once the
    /// reloaded document finishes loading.
    var pendingScrollRestore: (Double, Double)?

    var keyMonitor: Any?
    var isSidebarVisible = false
    var sidebarWidthConstraint: NSLayoutConstraint?
    var navPillProximityTimer: Timer?
    /// The grab strip straddling the sidebar/content border; hidden while the
    /// sidebar is collapsed so no stray resize cursor shows at the window edge.
    var sidebarResizeHandle: SidebarResizeHandleView?
    var isPointerNearNavPill = false {
        didSet {
            guard oldValue != isPointerNearNavPill else { return }
            updateNavPillVisibility()
        }
    }

    /// The open width of the sidebar, persisted across launches and adjusted by
    /// dragging the resize handle. Clamped to the sidebar's min/max.
    var sidebarWidth: CGFloat {
        didSet {
            let clamped = min(max(sidebarWidth, SidebarViewController.minWidth), SidebarViewController.maxWidth)
            if clamped != sidebarWidth {
                sidebarWidth = clamped
                return
            }
            UserDefaults.standard.set(sidebarWidth, forKey: Self.sidebarWidthDefaultsKey)
            if isSidebarVisible {
                // Disable implicit animation so a live drag updates the layout
                // synchronously each frame (no lag, no tween fighting the pointer).
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                sidebarWidthConstraint?.constant = sidebarWidth
                window?.contentView?.layoutSubtreeIfNeeded()
                CATransaction.commit()
            }
        }
    }

    private static func loadSidebarWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: sidebarWidthDefaultsKey)
        guard stored > 0 else { return SidebarViewController.defaultWidth }
        return min(max(CGFloat(stored), SidebarViewController.minWidth), SidebarViewController.maxWidth)
    }

    /// Whether the window floats above other windows.
    var isAlwaysOnTop: Bool = false {
        didSet {
            window?.level = isAlwaysOnTop ? .floating : .normal
        }
    }

    /// Empty-state convenience initializer: opens a window with no file loaded,
    /// showing the recent-files list instead of rendered markdown.
    convenience init() {
        self.init(filePath: nil)
    }

    init(filePath: String?) {
        self.filePath = filePath
        self.sidebarWidth = Self.loadSidebarWidth()

        let theme = Theme.load(variant: ThemeVariant.current)
        self.theme = theme
        let backgroundColor = theme.background.nsColor
        let renderer = MarkdownRenderer(theme: theme)
        self.renderer = renderer
        self.keyMap = KeyMap.load()
        self.sidebar = SidebarViewController(theme: theme)
        self.navBar = NavBarView(theme: theme)
        self.navPill = NavCluster(theme: theme)

        let configuration = WKWebViewConfiguration()
        let schemeHandler = MDReaderSchemeHandler(renderer: renderer)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: MDReaderSchemeHandler.scheme)
        self.schemeHandler = schemeHandler

        // Give raw web pages the same reading-lamp scrollbar as the themed markdown
        // view. Themed pages already carry these rules; the extra style tag there is
        // an identical no-op. Injected at document start so it applies before paint.
        let scrollbarCSS = theme.scrollbarCSS()
        let escapedCSS = scrollbarCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        let scrollbarScript = WKUserScript(
            source: """
            (function() {
              var style = document.createElement('style');
              style.textContent = `\(escapedCSS)`;
              document.documentElement.appendChild(style);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(scrollbarScript)
        let frame = NSRect(
            x: 0, y: 0,
            width: Self.defaultWidth, height: Self.defaultHeight
        )
        self.webView = WKWebView(frame: frame, configuration: configuration)
        self.webView.allowsMagnification = true
        // Inherit the last-used zoom so a newly opened file keeps the size you set.
        // Session restore may override this per-window in apply(windowState:).
        self.webView.magnification = Self.persistedMagnification
        // Don't paint a white background; let the themed container show through
        // any transient gap during async resize / before content paints.
        self.webView.setValue(false, forKey: "drawsBackground")

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: filePath)

        // Transparent titlebar: content extends under the system titlebar,
        // a custom drag strip sits on top of the titlebar region.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // Suppress the native 1px top highlight border. Content provides its
        // own opaque background, so the window won't render see-through.
        window.isOpaque = false
        window.backgroundColor = .clear

        // contentContainer holds the full-bleed webview plus the drag strip on
        // top; it occupies the area to the right of the (optional) sidebar.
        let contentContainer = NSView(frame: frame)
        self.contentContainer = contentContainer
        contentContainer.autoresizingMask = [.width, .height]
        // Themed backing so the WKWebView's async resize lag reveals the theme
        // background color, not the transparent window (which would flash white).
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = backgroundColor.cgColor

        // Webview under Auto Layout so the docked address bar can push its top
        // down (rather than overlaying it). Pinned to the sides and bottom; the
        // top toggles between the content top and the nav bar's bottom.
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(webView)

        let dragStrip = DragStripView(frame: NSRect(
            x: 0,
            y: contentContainer.bounds.height - Self.dragStripHeight,
            width: contentContainer.bounds.width,
            height: Self.dragStripHeight
        ))
        dragStrip.autoresizingMask = [.width, .minYMargin]
        contentContainer.addSubview(dragStrip)

        // Address/navigation bar docked across the top of the content area, below
        // the titlebar band so its controls clear the system traffic-light buttons.
        // Hidden by default; revealed by pushing the webview top down to its bottom.
        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.isHidden = true
        contentContainer.addSubview(navBar)

        // Floating rounded chrome pill (hamburger + back/forward) over the top-left
        // of the content while the address bar is hidden. Revealed on pointer
        // proximity; sits just below the titlebar band.
        navPill.translatesAutoresizingMaskIntoConstraints = false
        navPill.alphaValue = 0
        contentContainer.addSubview(navPill)

        // Webview top pinned to the bar's bottom permanently; animating the bar's
        // height between 0 and barHeight slides the content to match.
        let navBarHeight = navBar.heightAnchor.constraint(equalToConstant: 0)
        self.navBarHeightConstraint = navBarHeight

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            navBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            // Docked flush to the window top so the bar's background reads as one
            // continuous color from the window top through the field. The bar
            // reserves the traffic-light band internally (see NavBarView.topInset).
            navBar.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            navBarHeight,

            navPill.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Self.navPillInset),
            navPill.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Self.titlebarBandHeight),
        ])

        // Outer container lays the sidebar and content side by side via Auto
        // Layout; the sidebar's width constraint is animated to show/hide it.
        let outerContainer = NSView(frame: frame)
        outerContainer.wantsLayer = true
        outerContainer.layer?.backgroundColor = backgroundColor.cgColor

        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // Content first, sidebar last: the sidebar's trailing resize handle
        // straddles the border, so it must sit above the content view to receive
        // the resize cursor/drag when the pointer approaches from the content side.
        outerContainer.addSubview(contentContainer)
        outerContainer.addSubview(sidebar.view)

        let sidebarWidthConstraint = sidebar.view.widthAnchor.constraint(equalToConstant: 0)
        self.sidebarWidthConstraint = sidebarWidthConstraint

        NSLayoutConstraint.activate([
            sidebar.view.leadingAnchor.constraint(equalTo: outerContainer.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: outerContainer.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor),
            sidebarWidthConstraint,

            contentContainer.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: outerContainer.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: outerContainer.trailingAnchor),
        ])

        // Resize grab strip straddling the sidebar/content border, added last so
        // it sits above both siblings and receives the resize cursor/drag from
        // either side. Its trailing edge tracks the sidebar's trailing edge.
        let resizeHandle = SidebarResizeHandleView()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.isHidden = true
        self.sidebarResizeHandle = resizeHandle
        outerContainer.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.topAnchor.constraint(equalTo: outerContainer.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor),
            resizeHandle.trailingAnchor.constraint(
                equalTo: sidebar.view.trailingAnchor,
                constant: Self.sidebarResizeHandleWidth / 2
            ),
            resizeHandle.widthAnchor.constraint(equalToConstant: Self.sidebarResizeHandleWidth),
        ])

        window.contentView = outerContainer
        window.center()

        super.init(window: window)
        // On mouse-down, anchor to the current width; during the drag report an
        // absolute target so the sidebar's trailing edge stays glued to the pointer.
        resizeHandle.dragBeginWidth = { [weak self] in self?.sidebarWidth ?? 0 }
        resizeHandle.onDrag = { [weak self] width in
            guard let self, self.isSidebarVisible else { return }
            self.sidebarWidth = width
        }
        sidebar.delegate = self
        navBar.delegate = self
        navPill.delegate = self
        sidebar.headerToggleTarget = self
        sidebar.headerToggleAction = #selector(hamburgerClicked)

        self.webView.navigationDelegate = self
        // target=_blank / window.open links request a NEW webview via the UI delegate
        // instead of hitting the navigation delegate; we intercept them there and open
        // in-window through the same classifier (see createWebViewWith).
        self.webView.uiDelegate = self
        // github (and other JS-routed sites) navigate via Turbo/pushState, which never
        // hit the navigation delegate; observing `url` keeps chrome (title, nav buttons,
        // address prefill) in sync while browsing a web page.
        webViewURLObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            self?.syncChromeFromURL()
        }
        loadInitial()
        installKeyMonitor()
        startNavPillProximityTimer()
    }

    @objc func hamburgerClicked() {
        toggleSidebar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        navPillProximityTimer?.invalidate()
        fileWatcher = nil
    }

    // MARK: - Session state

    /// Snapshot of this window for session persistence: its file, on-screen
    /// frame, and sidebar state.
    var windowState: WindowState {
        WindowState(
            filePath: filePath,
            frame: window?.frame ?? .zero,
            sidebarVisible: isSidebarVisible,
            magnification: webView.magnification
        )
    }

    /// Restore a persisted window: place the frame and open the sidebar if it
    /// was open. The file itself is supplied via `init(filePath:)`.
    func apply(windowState state: WindowState) {
        if state.frame != .zero {
            window?.setFrame(state.frame, display: false)
        }
        if state.sidebarVisible && !isSidebarVisible {
            toggleSidebar()
        }
        if let magnification = state.magnification {
            let clamped = min(max(magnification, Self.minMagnification), Self.maxMagnification)
            webView.magnification = clamped
        }
    }

    // MARK: - Title

    static func windowTitle(for path: String?) -> String {
        guard let path else { return "MDReader" }
        let filename = (path as NSString).lastPathComponent
        let shortened = (path as NSString).abbreviatingWithTildeInPath
        return "\(filename) - \(shortened)"
    }
}
