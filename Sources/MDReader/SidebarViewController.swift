import AppKit

/// Native sidebar listing recently-opened markdown files. Plain click asks the
/// delegate to open the file in the current window; Cmd-click asks for a new
/// window, matching standard macOS link-opening conventions. A trailing-edge
/// grab handle lets the user drag to resize the list width.
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectPath path: String, openInNewWindow: Bool)
}

final class SidebarViewController: NSViewController {
    /// Default open width; also the initial value persisted to UserDefaults.
    static let defaultWidth: CGFloat = 220
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 420

    /// Right margin reserved so row content clears the overlay vertical scroller.
    private static let scrollerRightMargin: CGFloat = 14

    weak var delegate: SidebarViewControllerDelegate?

    /// Target/action for the header's sidebar-toggle (hamburger) button. The
    /// owning window controller wires these so the button collapses the sidebar.
    weak var headerToggleTarget: AnyObject? {
        didSet { headerToggleButton.target = headerToggleTarget }
    }
    var headerToggleAction: Selector? {
        didSet { headerToggleButton.action = headerToggleAction }
    }
    private let headerToggleButton = NSButton()

    /// The file currently shown in the owning window; its row is highlighted.
    var currentPath: String? {
        didSet { tableView.reloadData() }
    }

    private let theme: Theme
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var paths: [String] = []

    private static let columnID = NSUserInterfaceItemIdentifier("recent-file")
    private static let cellID = NSUserInterfaceItemIdentifier("recent-file-cell")

    init(theme: Theme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.sidebarBackground.nsColor.cgColor

        let title = NSTextField(labelWithString: "RECENT FILES")
        title.setAccessibilityIdentifier("sidebar-recent-files-header")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = theme.sidebarTitleText.nsColor
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        // Sidebar-toggle (hamburger) on the right of the header, always visible
        // while the sidebar is open. Wired by the window controller to collapse it.
        headerToggleButton.bezelStyle = .regularSquare
        headerToggleButton.isBordered = false
        headerToggleButton.imagePosition = .imageOnly
        headerToggleButton.contentTintColor = theme.sidebarItemText.nsColor
        headerToggleButton.toolTip = "Toggle recent files (\\)"
        headerToggleButton.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle recent files") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            headerToggleButton.image = image.withSymbolConfiguration(config)
        }
        container.addSubview(headerToggleButton)

        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        column.minWidth = 40
        column.maxWidth = .greatestFiniteMagnitude
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = PillScroller(theme: theme)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Hairline separator on the trailing edge for visual definition.
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = theme.sidebarSeparator.nsColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            headerToggleButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            headerToggleButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            headerToggleButton.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])

        self.view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Stretch the single column to fill the visible width so filenames get
        // the full row width instead of being truncated to a default column size.
        // Leave a small right margin so the row's trailing content (the remove
        // button) clears the overlay scroller track and isn't clipped.
        if let column = tableView.tableColumns.first {
            column.width = max(0, scrollView.contentView.bounds.width - Self.scrollerRightMargin)
        }
    }

    /// Re-reads recent files from disk and refreshes the list.
    func reload() {
        paths = RecentFiles.list()
        tableView.reloadData()
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < paths.count else { return }
        let openInNewWindow = NSEvent.modifierFlags.contains(.command)
        delegate?.sidebar(self, didSelectPath: paths[row], openInNewWindow: openInNewWindow)
    }

    /// Removes a path from history and animates the row out of the list.
    fileprivate func removePath(_ path: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        RecentFiles.remove(path)
        paths.remove(at: index)
        tableView.removeRows(at: IndexSet(integer: index), withAnimation: .slideUp)
    }
}

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        paths.count
    }
}

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HoverHighlightRowView()
        rowView.highlightColor = theme.hoverItemOverlay.nsColor
        rowView.trailingInset = Self.scrollerRightMargin
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = paths[row]
        let cell: RecentFileCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? RecentFileCellView {
            cell = reused
        } else {
            cell = RecentFileCellView(theme: theme)
            cell.identifier = Self.cellID
        }
        cell.configure(
            path: path,
            isCurrent: path == currentPath,
            onRemove: { [weak self] in self?.removePath(path) }
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        30
    }
}

/// One recent-file row: a filename label plus a remove (×) button that fades in
/// on hover. The whole cell tracks hover so the button only shows for the row
/// the pointer is over.
private final class RecentFileCellView: NSView {
    private static let removeButtonSize: CGFloat = 18

    private let theme: Theme
    private let label = NSTextField(labelWithString: "")
    /// Square layer-backed view that paints the circular background; the button
    /// itself is transparent and overlaid for click handling, so the circle's
    /// geometry is fixed by constraints rather than NSButton's cell sizing.
    private let removeBackground = NSView()
    private let removeButton = NSButton()
    private var onRemove: (() -> Void)?

    /// Label runs to the item's trailing edge when the remove button is hidden,
    /// and is pulled in to clear the button while it's shown; swapped on hover so
    /// the filename uses the full width until the X actually appears.
    private var labelTrailingFull: NSLayoutConstraint!
    private var labelTrailingClearButton: NSLayoutConstraint!

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true

        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        removeBackground.wantsLayer = true
        removeBackground.layer?.cornerRadius = Self.removeButtonSize / 2
        removeBackground.layer?.masksToBounds = true
        removeBackground.layer?.backgroundColor = theme.hoverItemOverlay.nsColor.cgColor
        removeBackground.alphaValue = 0
        removeBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeBackground)

        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        removeButton.contentTintColor = theme.foreground.nsColor
        if let xImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from recent files") {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            removeButton.image = xImage.withSymbolConfiguration(config)
        }
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.toolTip = "Remove from recent files"
        removeButton.alphaValue = 0
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            removeBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            removeBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeBackground.widthAnchor.constraint(equalToConstant: Self.removeButtonSize),
            removeBackground.heightAnchor.constraint(equalToConstant: Self.removeButtonSize),

            removeButton.centerXAnchor.constraint(equalTo: removeBackground.centerXAnchor),
            removeButton.centerYAnchor.constraint(equalTo: removeBackground.centerYAnchor),
            removeButton.widthAnchor.constraint(equalTo: removeBackground.widthAnchor),
            removeButton.heightAnchor.constraint(equalTo: removeBackground.heightAnchor),
        ])

        labelTrailingFull = label.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -10
        )
        labelTrailingClearButton = label.trailingAnchor.constraint(
            lessThanOrEqualTo: removeBackground.leadingAnchor, constant: -4
        )
        labelTrailingFull.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(path: String, isCurrent: Bool, onRemove: @escaping () -> Void) {
        label.stringValue = (path as NSString).lastPathComponent
        label.textColor = isCurrent ? theme.accentPrimary.nsColor : theme.sidebarItemText.nsColor
        toolTip = path
        // Stable per-file identifier so UI tests can target a specific recent row.
        setAccessibilityIdentifier("sidebar-row-\((path as NSString).lastPathComponent)")
        self.onRemove = onRemove
        // Cells are reused across rows; re-evaluate hover for the row this cell
        // now represents so a scroll (which reuses cells without firing exit)
        // can't leave the X stuck on the wrong rows.
        syncHoverToPointer()
    }

    @objc private func removeClicked() {
        onRemove?()
    }

    // MARK: - Hover tracking (reveals the remove button)

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        // Tracking rects recompute on scroll; the pointer may now be over a
        // different row without any enter/exit firing. Re-derive hover from the
        // real pointer position so the X can't stick on scrolled-past rows.
        syncHoverToPointer()
    }

    override func mouseEntered(with event: NSEvent) { setRemoveButtonVisible(true) }
    override func mouseExited(with event: NSEvent) { setRemoveButtonVisible(false) }

    /// Recompute hover purely from the current pointer position. Used after cell
    /// reuse/scroll, where enter/exit events don't fire because the pointer never
    /// moved relative to the screen.
    private func syncHoverToPointer() {
        guard let window else {
            setRemoveButtonVisible(false, animated: false)
            return
        }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = convert(pointInWindow, from: nil)
        setRemoveButtonVisible(bounds.contains(pointInView), animated: false)
    }

    private func setRemoveButtonVisible(_ visible: Bool, animated: Bool = true) {
        // Give the filename its full width until the button is actually shown.
        labelTrailingFull.isActive = !visible
        labelTrailingClearButton.isActive = visible
        let apply = {
            self.removeBackground.animator().alphaValue = visible ? 1 : 0
            self.removeButton.animator().alphaValue = visible ? 1 : 0
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                apply()
                self.layoutSubtreeIfNeeded()
            }
        } else {
            removeBackground.alphaValue = visible ? 1 : 0
            removeButton.alphaValue = visible ? 1 : 0
        }
    }
}

/// A thin overlay scroller drawn as a rounded pill to match the markdown
/// webview's `::-webkit-scrollbar` styling: transparent track, a faint
/// accent-tinged thumb inset from the edges that warms toward the accent on
/// hover/drag.
private final class PillScroller: NSScroller {
    private let theme: Theme

    /// Inset on each side of the knob slot, mirroring the webview thumb's 3px
    /// transparent border inside a 12px track (leaving a ~6px visible pill).
    private static let knobInset: CGFloat = 3

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent track.
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob).insetBy(dx: Self.knobInset, dy: Self.knobInset)
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        let radius = knobRect.width / 2
        let path = NSBezierPath(roundedRect: knobRect, xRadius: radius, yRadius: radius)
        let color = isDraggingKnob ? theme.accentPrimary.nsColor : theme.scrollbarThumb.nsColor
        color.setFill()
        path.fill()
    }

    private var isDraggingKnob = false

    override func mouseDown(with event: NSEvent) {
        isDraggingKnob = true
        super.mouseDown(with: event)
        isDraggingKnob = false
        needsDisplay = true
    }
}

/// An invisible vertical strip straddling the sidebar's trailing edge that shows
/// a horizontal-resize cursor and, while dragged, reports an absolute target
/// width so the edge stays glued to the pointer.
final class SidebarResizeHandleView: NSView {
    /// Returns the sidebar width at the moment the drag begins.
    var dragBeginWidth: (() -> CGFloat)?
    /// Reports the absolute target width during a drag.
    var onDrag: ((CGFloat) -> Void)?

    /// Width when the drag started, and the pointer's window X at that moment;
    /// the new width is the start width plus how far the pointer has moved.
    private var startWidth: CGFloat = 0
    private var startPointerX: CGFloat = 0

    private var trackingArea: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        // .mouseEnteredAndExited + .mouseMoved so we can pin the cursor ourselves
        // across the whole strip; the overlapping WKWebView sibling wins plain
        // cursor rects / .cursorUpdate on its half, so we set it on every move.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        // Keep the resize cursor pinned for the whole drag; AppKit would
        // otherwise reset it as the pointer leaves the strip.
        NSCursor.resizeLeftRight.set()
        startWidth = dragBeginWidth?() ?? 0
        startPointerX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let deltaX = event.locationInWindow.x - startPointerX
        onDrag?(startWidth + deltaX)
    }
}

/// A table row that paints a faint background on hover, since NSTableView has
/// no built-in non-selection hover state.
private final class HoverHighlightRowView: NSTableRowView {
    var highlightColor: NSColor = .clear

    private lazy var trackingArea = NSTrackingArea(
        rect: .zero,
        options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
        owner: self,
        userInfo: nil
    )

    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(trackingArea) {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// Extra right inset so the pill stops short of the overlay scroller track
    /// instead of running under it and getting clipped.
    var trailingInset: CGFloat = 0

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovering else { return }
        var inset = bounds.insetBy(dx: 4, dy: 1)
        inset.size.width -= trailingInset
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        highlightColor.setFill()
        path.fill()
    }
}
