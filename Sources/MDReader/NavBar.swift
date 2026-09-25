import AppKit

/// Classifies an app-controlled document and builds its `mdreader://` URL. Web pages
/// are real http(s) URLs and are not represented here.
enum NavDocument {
    /// The recent-files empty state (no file open).
    case empty
    /// A local markdown file on disk, addressed by absolute path.
    case file(String)
    /// Remote markdown fetched over http(s) by the scheme handler; carries the
    /// source URL (the handler fetches and themes it).
    case remoteMarkdown(url: String)

    var mdreaderURL: URL? {
        switch self {
        case .empty:
            return URL(string: "\(MDReaderSchemeHandler.scheme)://empty")
        case .file(let path):
            var c = URLComponents()
            c.scheme = MDReaderSchemeHandler.scheme
            c.host = "file"
            c.queryItems = [URLQueryItem(name: "path", value: path)]
            return c.url
        case .remoteMarkdown(let url):
            var c = URLComponents()
            c.scheme = MDReaderSchemeHandler.scheme
            c.host = "remote-md"
            c.queryItems = [URLQueryItem(name: "url", value: url)]
            return c.url
        }
    }
}

/// User intents surfaced by the navigation controls (both the floating pill and
/// the address bar), reported up to the window controller.
protocol NavControlsDelegate: AnyObject {
    func navControlsDidToggleSidebar()
    func navControlsDidGoBack()
    func navControlsDidGoForward()
}

/// Delegate the address bar reports its own field intents to.
protocol NavBarDelegate: NavControlsDelegate {
    /// The user submitted the address field with this raw string.
    func navBar(_ navBar: NavBarView, didSubmitAddress address: String)
    /// The user asked to dismiss the bar (Esc).
    func navBarDidRequestDismiss(_ navBar: NavBarView)
}

// MARK: - NavCluster

/// A rounded "pill" of chrome buttons — hamburger (sidebar toggle), back, forward —
/// drawn on an opaque rounded background so it reads over any web page rather than
/// blending in. Used both as a floating overlay (top-left, revealed on proximity)
/// and embedded at the leading edge of the address bar.
final class NavCluster: NSView {

    static let height: CGFloat = 30
    /// Fixed width of one icon button inside the pill.
    private static let buttonWidth: CGFloat = 28

    weak var delegate: NavControlsDelegate?

    private let hamburgerButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let stack: NSStackView
    private let theme: Theme

    /// When false, the hamburger is dropped from the pill (the sidebar is open, so
    /// its own header hosts the toggle instead).
    var showsHamburger: Bool = true {
        didSet {
            guard oldValue != showsHamburger else { return }
            hamburgerButton.isHidden = !showsHamburger
        }
    }

    init(theme: Theme) {
        self.theme = theme
        self.stack = NSStackView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.backgroundColor = theme.chromePillBackground.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = theme.borderFaint.nsColor.cgColor

        Self.styleButton(hamburgerButton, symbol: "sidebar.left", tooltip: "Toggle recent files (\\)", theme: theme)
        Self.styleButton(backButton, symbol: "chevron.left", tooltip: "Back (⌘[)", theme: theme)
        Self.styleButton(forwardButton, symbol: "chevron.right", tooltip: "Forward (⌘])", theme: theme)
        backButton.setAccessibilityIdentifier("nav-back-button")
        forwardButton.setAccessibilityIdentifier("nav-forward-button")
        hamburgerButton.target = self
        hamburgerButton.action = #selector(hamburgerClicked)
        backButton.target = self
        backButton.action = #selector(backClicked)
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hamburgerButton)
        stack.addArrangedSubview(backButton)
        stack.addArrangedSubview(forwardButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func styleButton(_ button: NSButton, symbol: String, tooltip: String, theme: Theme) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = theme.chromeIcon.nsColor
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            button.image = image.withSymbolConfiguration(config)
        }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: buttonWidth),
            button.heightAnchor.constraint(equalToConstant: Self.height - 4),
        ])
    }

    @objc private func hamburgerClicked() { delegate?.navControlsDidToggleSidebar() }
    @objc private func backClicked() { delegate?.navControlsDidGoBack() }
    @objc private func forwardClicked() { delegate?.navControlsDidGoForward() }

    /// Enable/disable the back/forward buttons to reflect history position.
    func updateNavButtons(canGoBack: Bool, canGoForward: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        backButton.alphaValue = canGoBack ? 1 : 0.35
        forwardButton.alphaValue = canGoForward ? 1 : 0.35
    }
}

// MARK: - Address field

/// `NSTextFieldCell` that insets the text (and its field editor) so a borderless,
/// self-drawn capsule field has real internal horizontal padding instead of text
/// crammed against the rounded edge.
private final class InsetFieldCell: NSTextFieldCell {
    var inset = NSSize(width: 16, height: 0)

    /// Horizontally inset by `inset.width`, then vertically center the single line
    /// of text within the (tall, capsule) field so it isn't pinned to the top.
    private func apply(_ rect: NSRect) -> NSRect {
        let insetRect = rect.insetBy(dx: inset.width, dy: 0)
        let textHeight = ceil(font?.boundingRectForFont.height ?? insetRect.height)
        guard textHeight < insetRect.height else { return insetRect }
        let dy = (insetRect.height - textHeight) / 2
        return NSRect(x: insetRect.origin.x, y: insetRect.origin.y + dy,
                      width: insetRect.width, height: textHeight)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: apply(rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: apply(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: apply(rect), in: controlView, editor: editor,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: apply(rect), in: controlView, editor: editor,
                     delegate: delegate, start: start, length: length)
    }
}

/// Borderless address field drawn as a flat themed capsule so it shares the warm
/// chrome language of the `NavCluster` pill (no white system bezel). Reports its
/// focus transitions so the border can accent on edit.
private final class AddressField: NSTextField {
    /// Called when the field gains/loses first-responder focus.
    var onFocusChange: ((Bool) -> Void)?
    /// Selected-text attributes (warm wash + legible text) applied to the shared
    /// field editor each time this field starts editing, overriding system blue.
    var selectionAttributes: [NSAttributedString.Key: Any] = [:]

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            (currentEditor() as? NSTextView)?.selectedTextAttributes = selectionAttributes
            onFocusChange?(true)
        }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

// MARK: - NavBarView

/// A slim address/navigation bar docked across the top of the content area: a
/// leading `NavCluster` (hamburger + back/forward) and an address field that
/// accepts local paths or http(s) URLs. Hidden by default; the window controller
/// reveals it, pushing the webview down so the bar and content are both visible.
final class NavBarView: NSView, NSTextFieldDelegate {

    /// Vertical band at the top reserved for the system traffic-light buttons; the
    /// bar docks flush to the window top and keeps its controls below this band.
    static let topInset: CGFloat = 30
    /// Height of the control strip (field + pill) below the reserved band.
    private static let controlStripHeight: CGFloat = 44
    static let barHeight: CGFloat = topInset + controlStripHeight
    /// Field height, matched to the pill so both controls share one cap line.
    private static let fieldHeight: CGFloat = NavCluster.height

    weak var delegate: NavBarDelegate? {
        didSet { cluster.delegate = delegate }
    }

    let cluster: NavCluster
    private let addressField: AddressField
    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        self.cluster = NavCluster(theme: theme)
        self.addressField = AddressField()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = theme.chromeBarBackground.nsColor.cgColor
        // Clip internal controls while the bar collapses to height 0 on hide.
        layer?.masksToBounds = true

        // Bottom hairline separator so the bar reads as a distinct strip.
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = theme.borderFaint.nsColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        cluster.translatesAutoresizingMaskIntoConstraints = false

        // Themed flat capsule field: borderless, self-drawn rounded background with
        // a hairline that accents warm-amber on focus. Matches the pill's language.
        let cell = InsetFieldCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        cell.isScrollable = true
        cell.wraps = false
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byTruncatingHead
        addressField.cell = cell
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.setAccessibilityIdentifier("nav-address-field")
        addressField.delegate = self
        addressField.font = .systemFont(ofSize: 13)
        addressField.isBezeled = false
        addressField.isBordered = false
        addressField.focusRingType = .none
        addressField.textColor = theme.chromeFieldText.nsColor
        addressField.placeholderAttributedString = NSAttributedString(
            string: "Open a file path or URL…",
            attributes: [.foregroundColor: theme.chromeFieldPlaceholder.nsColor,
                         .font: NSFont.systemFont(ofSize: 13)])
        addressField.wantsLayer = true
        addressField.drawsBackground = false
        addressField.layer?.backgroundColor = theme.chromeFieldBackground.nsColor.cgColor
        addressField.layer?.cornerRadius = Self.fieldHeight / 2
        addressField.layer?.borderWidth = 1
        addressField.layer?.borderColor = theme.chromeFieldBorder.nsColor.cgColor
        addressField.selectionAttributes = [
            .backgroundColor: theme.chromeFieldSelection.nsColor,
            .foregroundColor: theme.chromeFieldText.nsColor,
        ]
        addressField.onFocusChange = { [weak self] focused in
            self?.setFieldFocused(focused)
        }

        let stack = NSStackView(views: [cluster, addressField])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // Center the controls in the strip below the reserved traffic-light band.
            stack.centerYAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.topInset + (Self.barHeight - Self.topInset) / 2),

            addressField.heightAnchor.constraint(equalToConstant: Self.fieldHeight),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// Swap the field's hairline to the warm accent while it holds focus.
    private func setFieldFocused(_ focused: Bool) {
        let border = focused ? theme.chromeFieldFocusBorder : theme.chromeFieldBorder
        addressField.layer?.borderColor = border.nsColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Prefill the address field (with the current document's address) and give it
    /// first-responder focus, selecting the whole string for quick replacement.
    func focusAddress(prefill: String) {
        addressField.stringValue = prefill
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    /// Update the field's displayed text without moving focus or selection. Used
    /// to keep a visible bar in sync when the document changes from elsewhere
    /// (e.g. picking a file in the sidebar).
    func setAddressText(_ text: String) {
        addressField.stringValue = text
    }

    /// True while the address field holds the window's editing focus.
    var isAddressFieldEditing: Bool {
        guard let editor = addressField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// Show/hide the bar's own hamburger (dropped while the sidebar is open, since
    /// the sidebar header hosts the toggle then).
    func setShowsHamburger(_ shows: Bool) {
        cluster.showsHamburger = shows
    }

    /// Enable/disable the back/forward buttons to reflect history position.
    func updateNavButtons(canGoBack: Bool, canGoForward: Bool) {
        cluster.updateNavButtons(canGoBack: canGoBack, canGoForward: canGoForward)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let value = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                delegate?.navBar(self, didSubmitAddress: value)
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            delegate?.navBarDidRequestDismiss(self)
            return true
        }
        return false
    }
}
