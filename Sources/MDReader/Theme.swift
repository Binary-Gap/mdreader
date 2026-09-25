import AppKit
import Foundation

// MARK: - ColorToken

/// A color expressed either as a hex string ("#23262b") or as a base color with
/// an alpha overlay ({ "base": "white", "opacity": 0.06 }), so faint white
/// borders/overlays round-trip cleanly through JSON.
struct ColorToken: Codable, Equatable {
    /// CSS-ready string (e.g. "#23262b" or "rgba(255,255,255,0.06)").
    let css: String

    init(css: String) {
        self.css = css
    }

    init(hex: String) {
        self.css = hex
    }

    /// White (or black) at a given alpha, emitted as rgba.
    init(white: CGFloat, opacity: CGFloat) {
        let channel = Int((white * 255).rounded())
        self.css = "rgba(\(channel),\(channel),\(channel),\(Self.trim(opacity)))"
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case base, opacity }

    init(from decoder: Decoder) throws {
        // Accept a bare string ("#23262b" / "rgba(...)") ...
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            self.css = raw
            return
        }
        // ... or an object form { base: "white"|"black"|"#hex", opacity: 0.06 }.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = try container.decode(String.self, forKey: .base)
        let opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        switch base.lowercased() {
        case "white": self = ColorToken(white: 1.0, opacity: CGFloat(opacity))
        case "black": self = ColorToken(white: 0.0, opacity: CGFloat(opacity))
        default:
            // Hex base with opacity -> rgba via NSColor resolution.
            if let color = ColorToken.nsColor(fromHex: base) {
                let r = Int((color.redComponent * 255).rounded())
                let g = Int((color.greenComponent * 255).rounded())
                let b = Int((color.blueComponent * 255).rounded())
                self.css = "rgba(\(r),\(g),\(b),\(Self.trim(CGFloat(opacity))))"
            } else {
                self.css = base
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(css)
    }

    private static func trim(_ value: CGFloat) -> String {
        // Compact alpha (0.06 not 0.060000) for tidy CSS.
        var string = String(format: "%.3f", Double(value))
        while string.hasSuffix("0") { string.removeLast() }
        if string.hasSuffix(".") { string.removeLast() }
        return string
    }

    // MARK: NSColor accessor

    /// Resolve this token to an NSColor (hex or rgba). Returns clear if unparseable.
    var nsColor: NSColor {
        let value = css.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#"), let color = ColorToken.nsColor(fromHex: value) {
            return color
        }
        if value.hasPrefix("rgba"), let color = ColorToken.nsColor(fromRGBA: value) {
            return color
        }
        return ColorToken.nsColor(fromHex: value) ?? .clear
    }

    static func nsColor(fromHex hex: String) -> NSColor? {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        let r = CGFloat((value & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((value & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(value & 0x0000FF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    static func nsColor(fromRGBA rgba: String) -> NSColor? {
        // Parse rgba(r,g,b,a) — integer channels, fractional alpha.
        guard let open = rgba.firstIndex(of: "("),
              let close = rgba.firstIndex(of: ")") else { return nil }
        let inner = rgba[rgba.index(after: open)..<close]
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 4,
              let r = Double(parts[0]),
              let g = Double(parts[1]),
              let b = Double(parts[2]),
              let a = Double(parts[3]) else { return nil }
        return NSColor(srgbRed: CGFloat(r) / 255.0,
                       green: CGFloat(g) / 255.0,
                       blue: CGFloat(b) / 255.0,
                       alpha: CGFloat(a))
    }
}

// MARK: - ThemeVariant

/// The user-selectable theme identity. Persisted across launches in UserDefaults
/// under `MDReaderThemeVariant`; defaults to `.dark`.
enum ThemeVariant: String {
    case dark
    case light

    private static let defaultsKey = "MDReaderThemeVariant"

    /// The currently selected variant, read from / written to UserDefaults.
    /// An unknown or missing stored value falls back to `.dark`.
    static var current: ThemeVariant {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return ThemeVariant(rawValue: raw) ?? .dark
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// The opposite variant, used by the dark<->light toggle.
    var toggled: ThemeVariant { self == .dark ? .light : .dark }

    /// Name of the bundled full-theme JSON resource for this variant.
    var bundledResourceName: String {
        switch self {
        case .dark: return "theme-dark"
        case .light: return "theme-light"
        }
    }

    /// The hardcoded Swift fallback theme for this variant (used if the bundled
    /// JSON is missing or invalid, so the app always has a safe default).
    var fallbackTheme: Theme {
        switch self {
        case .dark: return .dark
        case .light: return .light
        }
    }
}

// MARK: - Theme

/// Named color/typography tokens for the markdown WebView, ported from the
/// Hammerspoon md_viewer dark theme (spec-features §2). Supports a partial user
/// override loaded from ~/.config/mdreader/theme.json.
struct Theme: Codable, Equatable {
    // Surfaces
    var background: ColorToken
    var sidebarBackground: ColorToken
    var codeBlockBackground: ColorToken
    var inlineCodeBackground: ColorToken

    // Text
    var foreground: ColorToken
    var heading3: ColorToken
    var heading4: ColorToken
    var emphasis: ColorToken
    var muted: ColorToken
    var emptyState: ColorToken

    // Accents
    var accentPrimary: ColorToken
    var accentPrimaryHover: ColorToken
    var accentPrimarySoft: ColorToken
    var accentSecondary: ColorToken

    // Syntax highlighting (code tokens). Kept as a small set of muted, warm-family
    // hues so highlighted code separates by role (keyword / type / function /
    // number) like an editor scheme, without vibrating against the reading-lamp
    // background. Strings map to `accentSecondary` (sage) and comments to `muted`.
    var syntaxKeyword: ColorToken
    var syntaxType: ColorToken
    var syntaxFunction: ColorToken
    var syntaxNumber: ColorToken

    // Sidebar text
    var sidebarItemText: ColorToken
    var sidebarTitleText: ColorToken
    var sidebarSeparator: ColorToken

    // Navigation chrome (address bar + floating button pill)
    var chromeBarBackground: ColorToken
    var chromePillBackground: ColorToken
    var chromeIcon: ColorToken
    var chromeFieldBackground: ColorToken
    var chromeFieldText: ColorToken
    var chromeFieldPlaceholder: ColorToken
    var chromeFieldBorder: ColorToken
    var chromeFieldFocusBorder: ColorToken
    /// Background of selected text in the address field (a warm amber wash rather
    /// than system blue, so selected text stays legible on the dark field).
    var chromeFieldSelection: ColorToken

    // Borders & overlays
    var borderFaint: ColorToken
    var borderTableCell: ColorToken
    var borderTableHeader: ColorToken
    var hoverRowOverlay: ColorToken
    var hoverItemOverlay: ColorToken

    // Scrollbar (resting thumb is faint; warms toward the accent on hover/drag)
    var scrollbarThumb: ColorToken
    var scrollbarThumbHover: ColorToken

    // Typography
    var bodyFont: String
    var monoFont: String
    var baseFontSize: CGFloat
    var codeFontSize: CGFloat
    var lineHeight: CGFloat
    var contentPaddingVertical: CGFloat
    var contentPaddingHorizontal: CGFloat
    var maxContentWidth: CGFloat

    // MARK: Default (ported dark theme)

    /// The built-in "reading lamp" theme: a warm dark palette tuned for long-form
    /// reading. Ink-on-slate rather than a code editor — the background is a warm
    /// near-black (not cold blue-grey), text is a soft paper-white that never
    /// reaches pure #fff, and accents are a muted lamplight amber + sage that sit
    /// quietly against the dark instead of vibrating. Body sets in Apple's New York
    /// reading serif at a true book measure.
    static let dark = Theme(
        background: ColorToken(hex: "#1c1a17"),
        sidebarBackground: ColorToken(hex: "#171512"),
        codeBlockBackground: ColorToken(hex: "#15130f"),
        inlineCodeBackground: ColorToken(css: "rgba(232,213,168,0.07)"),
        foreground: ColorToken(hex: "#e7ddcb"),
        heading3: ColorToken(hex: "#ead9b8"),
        heading4: ColorToken(hex: "#cbbfa6"),
        emphasis: ColorToken(hex: "#f3ead6"),
        muted: ColorToken(hex: "#9c9484"),
        emptyState: ColorToken(hex: "#5a5448"),
        accentPrimary: ColorToken(hex: "#d8a657"),
        accentPrimaryHover: ColorToken(hex: "#e8bd76"),
        accentPrimarySoft: ColorToken(css: "rgba(216,166,87,0.12)"),
        accentSecondary: ColorToken(hex: "#a8b88f"),
        syntaxKeyword: ColorToken(hex: "#e08aa4"),
        syntaxType: ColorToken(hex: "#7fb8a6"),
        syntaxFunction: ColorToken(hex: "#8fb8dc"),
        syntaxNumber: ColorToken(hex: "#d8a657"),
        sidebarItemText: ColorToken(hex: "#9c9484"),
        sidebarTitleText: ColorToken(hex: "#6f685b"),
        sidebarSeparator: ColorToken(css: "rgba(232,213,168,0.06)"),
        chromeBarBackground: ColorToken(hex: "#171512"),
        chromePillBackground: ColorToken(css: "rgba(28,26,23,0.92)"),
        chromeIcon: ColorToken(hex: "#cbbfa6"),
        chromeFieldBackground: ColorToken(hex: "#232019"),
        chromeFieldText: ColorToken(hex: "#e7ddcb"),
        chromeFieldPlaceholder: ColorToken(css: "rgba(231,221,203,0.35)"),
        chromeFieldBorder: ColorToken(css: "rgba(232,213,168,0.10)"),
        chromeFieldFocusBorder: ColorToken(css: "rgba(216,166,87,0.55)"),
        chromeFieldSelection: ColorToken(css: "rgba(216,166,87,0.35)"),
        borderFaint: ColorToken(css: "rgba(232,213,168,0.08)"),
        borderTableCell: ColorToken(css: "rgba(232,213,168,0.10)"),
        borderTableHeader: ColorToken(css: "rgba(232,213,168,0.22)"),
        hoverRowOverlay: ColorToken(css: "rgba(232,213,168,0.04)"),
        hoverItemOverlay: ColorToken(css: "rgba(232,213,168,0.05)"),
        scrollbarThumb: ColorToken(css: "rgba(232,213,168,0.10)"),
        scrollbarThumbHover: ColorToken(css: "rgba(216,166,87,0.40)"),
        bodyFont: "\"New York\", \"Iowan Old Style\", Charter, \"Palatino Linotype\", Georgia, serif",
        monoFont: "\"SF Mono\", \"JetBrains Mono\", Menlo, monospace",
        baseFontSize: 18,
        codeFontSize: 14.5,
        lineHeight: 1.75,
        contentPaddingVertical: 56,
        contentPaddingHorizontal: 40,
        maxContentWidth: 680
    )

    /// The built-in light theme: the "reading lamp" palette flipped to warm paper.
    /// A cream/paper background with warm dark-brown ink, the same amber accent
    /// family darkened so it holds contrast on a light ground, and a sage secondary.
    /// Borders/overlays/scrollbar are dark-on-light. Typography matches `.dark`.
    /// Kept as a hardcoded Swift literal so the light variant has a safe fallback
    /// if `theme-light.json` fails to load, mirroring `.dark`.
    static let light = Theme(
        background: ColorToken(hex: "#faf6ee"),
        sidebarBackground: ColorToken(hex: "#f2ece0"),
        codeBlockBackground: ColorToken(hex: "#f3ede1"),
        inlineCodeBackground: ColorToken(css: "rgba(120,85,20,0.08)"),
        foreground: ColorToken(hex: "#3a3427"),
        heading3: ColorToken(hex: "#5c4a25"),
        heading4: ColorToken(hex: "#6b5b3d"),
        emphasis: ColorToken(hex: "#241f16"),
        muted: ColorToken(hex: "#867c68"),
        emptyState: ColorToken(hex: "#b3a892"),
        accentPrimary: ColorToken(hex: "#9a6b16"),
        accentPrimaryHover: ColorToken(hex: "#7d560f"),
        accentPrimarySoft: ColorToken(css: "rgba(154,107,22,0.12)"),
        accentSecondary: ColorToken(hex: "#5f7444"),
        syntaxKeyword: ColorToken(hex: "#a5375f"),
        syntaxType: ColorToken(hex: "#2f7d68"),
        syntaxFunction: ColorToken(hex: "#345d8a"),
        syntaxNumber: ColorToken(hex: "#9a6b16"),
        sidebarItemText: ColorToken(hex: "#6f6552"),
        sidebarTitleText: ColorToken(hex: "#a79c86"),
        sidebarSeparator: ColorToken(css: "rgba(58,52,39,0.10)"),
        chromeBarBackground: ColorToken(hex: "#f2ece0"),
        chromePillBackground: ColorToken(css: "rgba(250,246,238,0.92)"),
        chromeIcon: ColorToken(hex: "#6b5b3d"),
        chromeFieldBackground: ColorToken(hex: "#fffdf8"),
        chromeFieldText: ColorToken(hex: "#3a3427"),
        chromeFieldPlaceholder: ColorToken(css: "rgba(58,52,39,0.40)"),
        chromeFieldBorder: ColorToken(css: "rgba(58,52,39,0.15)"),
        chromeFieldFocusBorder: ColorToken(css: "rgba(154,107,22,0.55)"),
        chromeFieldSelection: ColorToken(css: "rgba(154,107,22,0.28)"),
        borderFaint: ColorToken(css: "rgba(58,52,39,0.12)"),
        borderTableCell: ColorToken(css: "rgba(58,52,39,0.14)"),
        borderTableHeader: ColorToken(css: "rgba(58,52,39,0.30)"),
        hoverRowOverlay: ColorToken(css: "rgba(58,52,39,0.04)"),
        hoverItemOverlay: ColorToken(css: "rgba(58,52,39,0.05)"),
        scrollbarThumb: ColorToken(css: "rgba(58,52,39,0.18)"),
        scrollbarThumbHover: ColorToken(css: "rgba(154,107,22,0.50)"),
        bodyFont: "\"New York\", \"Iowan Old Style\", Charter, \"Palatino Linotype\", Georgia, serif",
        monoFont: "\"SF Mono\", \"JetBrains Mono\", Menlo, monospace",
        baseFontSize: 18,
        codeFontSize: 14.5,
        lineHeight: 1.75,
        contentPaddingVertical: 56,
        contentPaddingHorizontal: 40,
        maxContentWidth: 680
    )

    // MARK: Loading custom theme

    /// Path to the optional user theme override.
    static var overrideURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/mdreader/theme.json")
    }

    /// Load the theme for the currently selected variant. Convenience for callers
    /// that don't track the variant themselves.
    static func load() -> Theme {
        load(variant: ThemeVariant.current)
    }

    /// Load the full theme for `variant`, then merge the partial user override
    /// (`~/.config/mdreader/theme.json`) on top.
    ///
    /// The base comes from the bundled full-theme JSON (`theme-dark.json` /
    /// `theme-light.json`); if that resource is missing or invalid we fall back to
    /// the hardcoded Swift literal for the variant (`.dark` / `.light`) and log —
    /// so a broken/absent bundle can never crash and dark always has a safe default.
    static func load(variant: ThemeVariant) -> Theme {
        let base = bundledTheme(for: variant)
        return applyUserOverride(to: base)
    }

    /// Decode the bundled full-theme JSON for `variant`, falling back to the
    /// hardcoded literal on any failure (logs, never crashes).
    private static func bundledTheme(for variant: ThemeVariant) -> Theme {
        guard let url = Bundle.main.url(forResource: variant.bundledResourceName, withExtension: "json") else {
            NSLog("MDReader: bundled theme \(variant.bundledResourceName).json not found; using hardcoded \(variant.rawValue) theme.")
            return variant.fallbackTheme
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Theme.self, from: data)
        } catch {
            NSLog("MDReader: invalid bundled theme \(variant.bundledResourceName).json (\(error)); using hardcoded \(variant.rawValue) theme.")
            return variant.fallbackTheme
        }
    }

    /// Merge the optional partial user override (`theme.json`) over `base`.
    /// Falls back to `base` unchanged if the file is absent or invalid.
    private static func applyUserOverride(to base: Theme) -> Theme {
        guard let data = try? Data(contentsOf: overrideURL) else {
            return base
        }
        do {
            let override = try JSONDecoder().decode(ThemeOverride.self, from: data)
            return override.apply(to: base)
        } catch {
            // NOTE: invalid override -> fall back rather than crash.
            NSLog("MDReader: invalid theme.json (\(error)); ignoring user override.")
            return base
        }
    }

    // MARK: CSS emission

    /// Emit `:root` CSS custom properties consumed by the rendered HTML document,
    /// followed by the shared element rules.
    func css() -> String {
        [":root {", cssVariableDeclarations(), "}", Self.styleRulesCSS].joined(separator: "\n")
    }

    /// The `--token: value;` declaration lines on their own, with no wrapping
    /// selector, so a caller can scope them to whatever selector it needs (the
    /// VS Code extension scopes them to `body.vscode-dark` / `body.vscode-light`).
    func cssVariableDeclarations() -> String {
        var lines: [String] = []
        func add(_ name: String, _ value: String) {
            lines.append("  --\(name): \(value);")
        }
        add("background", background.css)
        add("sidebar-background", sidebarBackground.css)
        add("code-block-background", codeBlockBackground.css)
        add("inline-code-background", inlineCodeBackground.css)
        add("foreground", foreground.css)
        add("heading3", heading3.css)
        add("heading4", heading4.css)
        add("emphasis", emphasis.css)
        add("muted", muted.css)
        add("empty-state", emptyState.css)
        add("accent-primary", accentPrimary.css)
        add("accent-primary-hover", accentPrimaryHover.css)
        add("accent-primary-soft", accentPrimarySoft.css)
        add("accent-secondary", accentSecondary.css)
        add("sidebar-item-text", sidebarItemText.css)
        add("sidebar-title-text", sidebarTitleText.css)
        add("sidebar-separator", sidebarSeparator.css)
        add("border-faint", borderFaint.css)
        add("border-table-cell", borderTableCell.css)
        add("border-table-header", borderTableHeader.css)
        add("hover-row-overlay", hoverRowOverlay.css)
        add("hover-item-overlay", hoverItemOverlay.css)
        add("scrollbar-thumb", scrollbarThumb.css)
        add("scrollbar-thumb-hover", scrollbarThumbHover.css)
        add("body-font", bodyFont)
        add("mono-font", monoFont)
        add("base-font-size", "\(fmt(baseFontSize))px")
        add("code-font-size", "\(fmt(codeFontSize))px")
        add("line-height", fmt(lineHeight))
        add("content-padding", "\(fmt(contentPaddingVertical))px \(fmt(contentPaddingHorizontal))px")
        add("max-content-width", "\(fmt(maxContentWidth))px")
        return lines.joined(separator: "\n")
    }

    /// Element/layout rules shared by every variant; every color in them resolves
    /// through the variables emitted by `cssVariableDeclarations()`.
    static var styleRulesCSS: String { styleRules }

    /// Standalone `::-webkit-scrollbar` rules with colors resolved inline (no CSS
    /// custom properties). Injected into raw web pages so their scrollbar matches
    /// the reading-lamp overlay used in the themed markdown view, without pulling
    /// in the rest of the theme's `:root` variables. Web pages usually sit on a
    /// white background where the dark-tuned resting thumb vanishes, so the resting
    /// and hover thumb are a stronger amber than the markdown-view tokens.
    func scrollbarCSS() -> String {
        """
        ::-webkit-scrollbar { width: 12px; height: 12px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb {
          background: rgba(216,166,87,0.55);
          border-radius: 99px;
          border: 3px solid transparent;
          background-clip: padding-box;
        }
        ::-webkit-scrollbar-thumb:hover { background: rgba(216,166,87,0.75); background-clip: padding-box; }
        ::-webkit-scrollbar-thumb:active { background: \(accentPrimary.css); background-clip: padding-box; }
        ::-webkit-scrollbar-corner, ::-webkit-resizer { background: transparent; }
        """
    }

    /// highlight.js color scheme mapped onto the warm reading-lamp palette. marked.js
    /// emits `hljs`-classed spans (token type -> class); these rules paint each token
    /// family with a token from this theme. Modeled on Xcode's default scheme so code
    /// separates by role — keyword, type, function/method, number, string, comment —
    /// each its own hue, but every hue is a muted, warm-family tone so highlighted
    /// code reads as typeset alongside the prose rather than a saturated editor theme.
    func highlightCSS() -> String {
        let keyword = syntaxKeyword.css        // keywords, storage, control flow (rose)
        let type = syntaxType.css              // types, built-ins, classes (teal-sage)
        let function = syntaxFunction.css      // function/method names + calls (warm blue)
        let number = syntaxNumber.css          // numbers, literals, booleans (amber)
        let string = accentSecondary.css       // strings, regexp, char literals (sage)
        let property = heading4.css            // properties, attributes, symbols (warm ink)
        let comment = muted.css                // comments, quotes, deletions
        return """
        .hljs { color: var(--foreground); background: transparent; }
        .hljs-comment, .hljs-quote, .hljs-deletion { color: \(comment); font-style: italic; }
        .hljs-doctag { color: \(comment); font-style: italic; }
        .hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-meta-keyword {
          color: \(keyword);
        }
        .hljs-type, .hljs-built_in, .hljs-class .hljs-title, .hljs-title.class_,
        .hljs-title.class_.inherited__, .hljs-selector-tag {
          color: \(type);
        }
        .hljs-title, .hljs-title.function_, .hljs-function .hljs-title,
        .hljs-name, .hljs-section {
          color: \(function);
        }
        .hljs-string, .hljs-regexp, .hljs-addition, .hljs-meta-string, .hljs-char.escape_ {
          color: \(string);
        }
        .hljs-number, .hljs-symbol, .hljs-bullet, .hljs-link {
          color: \(number);
        }
        .hljs-attr, .hljs-attribute, .hljs-property, .hljs-variable,
        .hljs-template-variable, .hljs-params, .hljs-selector-id, .hljs-selector-class {
          color: \(property);
        }
        .hljs-tag { color: \(function); }
        .hljs-meta { color: \(comment); }
        .hljs-emphasis { font-style: italic; }
        .hljs-strong { font-weight: 600; }
        """
    }

    /// A mermaid `initialize()` config object (JSON) wired to the theme palette, so
    /// rendered diagrams sit on the same warm background as the rest of the document.
    /// `themeVariables` entries are built diagram-family by diagram-family below, each
    /// mapping mermaid's "base" theme keys onto the matching theme token via `q(...)`.
    func mermaidConfigJSON() -> String {
        var variables = MermaidThemeVariables()
        variables.addCore(self)
        variables.addFlowchart(self)
        variables.addSequence(self)
        variables.addClass(self)
        variables.addState(self)
        variables.addPie(self)
        variables.addER(self)
        variables.addGantt(self)
        variables.addGitGraph(self)
        let themeVariables = variables.entries.joined(separator: ",")
        return """
        {"startOnLoad":false,"securityLevel":"strict","suppressErrorRendering":true,"theme":"base","themeVariables":{\(themeVariables)}}
        """
    }

    /// CSS injected after mermaid renders, forcing per-diagram-type colors onto the warm
    /// palette where `themeVariables` alone don't reach. Mermaid scopes its own rules to
    /// the diagram id with high specificity, so these target the emitted classes with
    /// `!important` to win.
    func mermaidStyleRules() -> String {
        var rules: [String] = []
        rules.append(contentsOf: gitGraphStyleRules())
        rules.append(contentsOf: sequenceStyleRules())
        rules.append(contentsOf: classStyleRules())
        rules.append(contentsOf: stateStyleRules())
        return rules.joined(separator: "\n")
    }

    private func gitGraphStyleRules() -> [String] {
        // Branch colors cycle through this ordered palette (git0 = first branch).
        let palette = [accentPrimary, accentSecondary, heading3, accentPrimaryHover,
                       emphasis, muted, accentPrimary, accentSecondary]
        var rules: [String] = []
        for (i, color) in palette.enumerated() {
            // Branch baseline and the colored connecting curves for branch index i.
            rules.append(".mermaid .branch\(i){stroke:\(color.css) !important;}")
            rules.append(".mermaid .arrow\(i){stroke:\(color.css) !important;}")
            // Commit dots on branch index i.
            rules.append(".mermaid .commit\(i){stroke:\(color.css) !important;fill:\(color.css) !important;}")
            // Branch label pill background (mermaid: rect.branchLabelBkg.labelN).
            rules.append(".mermaid .branchLabelBkg.label\(i),.mermaid rect.label\(i){fill:\(color.css) !important;}")
        }
        // Branch label text + commit labels readable on the warm background.
        rules.append(".mermaid .branch-label{fill:\(background.css) !important;}")
        rules.append(".mermaid .commit-label{fill:\(foreground.css) !important;}")
        rules.append(".mermaid .commit-label-bkg{fill:\(codeBlockBackground.css) !important;}")
        return rules
    }

    /// Sequence diagrams draw actor boxes/lifelines/activations with their own classes
    /// that `themeVariables` only partially reach.
    private func sequenceStyleRules() -> [String] {
        [
            ".mermaid .actor{fill:\(accentPrimarySoft.css) !important;stroke:\(accentPrimary.css) !important;}",
            ".mermaid .actor-line{stroke:\(borderTableHeader.css) !important;}",
            ".mermaid text.actor{fill:\(foreground.css) !important;}",
            ".mermaid .messageLine0,.mermaid .messageLine1{stroke:\(accentSecondary.css) !important;}",
            ".mermaid .messageText{fill:\(foreground.css) !important;}",
            ".mermaid .note{fill:\(codeBlockBackground.css) !important;stroke:\(borderFaint.css) !important;}",
            ".mermaid .noteText,.mermaid .noteText tspan{fill:\(muted.css) !important;}",
            ".mermaid .activation0,.mermaid .activation1,.mermaid .activation2{fill:\(accentPrimarySoft.css) !important;stroke:\(accentPrimary.css) !important;}",
        ]
    }

    /// Class diagrams render relation lines/arrowheads with their own `.relation` class
    /// that doesn't reliably pick up `lineColor`.
    private func classStyleRules() -> [String] {
        [
            ".mermaid .relation{stroke:\(accentSecondary.css) !important;}",
            ".mermaid .classGroup rect{fill:\(accentPrimarySoft.css) !important;stroke:\(accentPrimary.css) !important;}",
            ".mermaid .classGroup text{fill:\(foreground.css) !important;}",
            ".mermaid .classGroup .title{fill:\(heading3.css) !important;}",
        ]
    }

    /// State diagrams nest composite states in their own `.statediagram-cluster` group,
    /// which the base theme's `clusterBkg`/`clusterBorder` don't always cover.
    private func stateStyleRules() -> [String] {
        [
            ".mermaid .statediagram-cluster rect{fill:\(codeBlockBackground.css) !important;stroke:\(borderFaint.css) !important;}",
            ".mermaid .statediagram-state rect.basic{fill:\(accentPrimarySoft.css) !important;stroke:\(accentPrimary.css) !important;}",
            ".mermaid .state-note rect{fill:\(codeBlockBackground.css) !important;stroke:\(borderFaint.css) !important;}",
            ".mermaid .state-note text{fill:\(muted.css) !important;}",
        ]
    }

    // Style rules that consume the :root custom properties above. Ported from the
    // Hammerspoon md_viewer template (spec-features §2), with hardcoded colors
    // swapped for the theme tokens.
    private static let styleRules = """
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { height: 100%; }

    /* Scrollbar: a thin, unobtrusive overlay tinted to the palette rather than the
       chunky default system bar. The track is invisible (the page background shows
       through); the thumb is a faint warm rule that warms to the amber accent on
       hover, matching the reading-lamp chrome. */
    ::-webkit-scrollbar { width: 12px; height: 12px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb {
      background: var(--scrollbar-thumb);
      border-radius: 99px;
      border: 3px solid transparent;
      background-clip: padding-box;
    }
    ::-webkit-scrollbar-thumb:hover { background: var(--scrollbar-thumb-hover); background-clip: padding-box; }
    ::-webkit-scrollbar-thumb:active { background: var(--accent-primary); background-clip: padding-box; }
    ::-webkit-scrollbar-corner, ::-webkit-resizer { background: transparent; }

    body {
      font-family: var(--body-font);
      font-size: var(--base-font-size);
      background: var(--background);
      color: var(--foreground);
      line-height: var(--line-height);
      -webkit-user-select: text;
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
      font-kerning: normal;
      -webkit-font-feature-settings: "kern", "liga", "onum", "pnum";
      font-feature-settings: "kern", "liga", "onum", "pnum";
    }
    .content {
      padding: var(--content-padding);
      max-width: var(--max-content-width);
      margin: 0 auto;
    }

    /* Headings: a quieter display register. Tight tracking, no shouting; h1 wears
       optical small-caps so the title reads as a frontispiece, not a banner. */
    h1, h2, h3, h4, h5, h6 {
      font-weight: 600;
      line-height: 1.25;
      letter-spacing: -0.01em;
      color: var(--emphasis);
    }
    h1 {
      font-size: 2em;
      font-weight: 650;
      letter-spacing: 0.01em;
      margin: 0 0 0.6em;
      padding-bottom: 0.4em;
      border-bottom: 1px solid var(--border-faint);
    }
    /* h2 carries the page's single accent: a hanging amber tick in the margin,
       so sections are findable without a heavy rule across the measure. */
    h2 {
      position: relative;
      font-size: 1.5em;
      margin: 1.7em 0 0.5em;
      color: var(--foreground);
    }
    h2::before {
      content: "";
      position: absolute;
      left: -0.85em;
      top: 0.18em;
      bottom: 0.18em;
      width: 3px;
      border-radius: 2px;
      background: var(--accent-primary);
    }
    h3 { font-size: 1.22em; margin: 1.4em 0 0.4em; color: var(--heading3); }
    h4 { font-size: 1.04em; margin: 1.2em 0 0.3em; color: var(--heading4); letter-spacing: 0; }
    h5, h6 { font-size: 0.92em; margin: 1em 0 0.3em; color: var(--muted); }

    p { margin: 0 0 0.95em; }
    /* Reading rhythm: a clear gap between paragraphs reads cleaner on screen than
       first-line indents, but consecutive prose paragraphs get a hair of indent to
       keep the measure feeling typeset rather than spaced out. */
    p + p { margin-top: -0.15em; }

    ul, ol { margin: 0.5em 0 1em 1.3em; }
    li { margin: 0.25em 0; padding-left: 0.2em; }
    li::marker { color: var(--muted); }
    ul ul, ol ol, ul ol, ol ul { margin-top: 0.25em; margin-bottom: 0.25em; }

    code {
      font-family: var(--mono-font);
      font-size: var(--code-font-size);
      background: var(--inline-code-background);
      padding: 0.1em 0.4em;
      border-radius: 4px;
      color: var(--accent-primary);
      font-feature-settings: normal;
    }
    pre {
      background: var(--code-block-background);
      border: 1px solid var(--border-faint);
      border-radius: 10px;
      padding: 16px 18px;
      margin: 1.2em 0;
      overflow-x: auto;
      line-height: 1.55;
    }
    pre code { background: none; padding: 0; color: var(--foreground); }

    hr {
      border: none;
      margin: 2.4em 0;
      text-align: center;
    }
    /* A printer's-mark divider rather than a flat line — three spaced ornaments,
       the way a book breaks a scene. */
    hr::before {
      content: "* * *";
      color: var(--muted);
      letter-spacing: 0.8em;
      font-size: 0.9em;
    }

    strong { color: var(--emphasis); font-weight: 650; }
    em { font-style: italic; color: var(--emphasis); }
    del, s { color: var(--muted); text-decoration: line-through; }

    /* GFM task lists: unindented, checkbox aligned with the text baseline. */
    ul li.task-list-item, ul.contains-task-list li { list-style: none; }
    ul:has(> li.task-list-item), ul.contains-task-list { margin-left: 0.2em; }
    li.task-list-item > input[type="checkbox"],
    li > input[type="checkbox"].task-list-item-checkbox {
      margin: 0 0.5em 0 0;
      accent-color: var(--accent-primary);
      vertical-align: middle;
    }
    a {
      color: var(--accent-primary);
      text-decoration: none;
      border-bottom: 1px solid var(--accent-primary-soft);
      transition: border-color 0.12s ease, color 0.12s ease;
    }
    a:hover { color: var(--accent-primary-hover); border-bottom-color: var(--accent-primary-hover); }

    table { width: 100%; border-collapse: collapse; margin: 1.2em 0; font-size: 0.95em; }
    th, td { text-align: left; padding: 0.5em 0.9em; border-bottom: 1px solid var(--border-table-cell); }
    /* Table headers in small-caps, not all-caps: indexed, not shouted. */
    th {
      color: var(--muted);
      font-weight: 600;
      font-size: 0.82em;
      font-variant: small-caps;
      letter-spacing: 0.04em;
      border-bottom: 1px solid var(--border-table-header);
    }
    tr:hover { background: var(--hover-row-overlay); }

    /* Blockquote as a margin aside: a faint amber rule, italic, slightly inset. */
    blockquote {
      border-left: 2px solid var(--accent-primary-soft);
      padding: 0.1em 0 0.1em 1.1em;
      margin: 1.2em 0;
      color: var(--muted);
      font-style: italic;
    }
    blockquote p { margin-bottom: 0.4em; }

    img { max-width: 100%; height: auto; border-radius: 8px; margin: 1.2em 0; }

    /* Empty-state view (no file open at launch): a centered heading over a list
       of recent files, name prominent and path dimmer beneath, matching the
       sidebar's recent-files convention. */
    .empty-state {
      max-width: var(--max-content-width);
      margin: 0 auto;
      padding: var(--content-padding);
    }
    .empty-state-title {
      color: var(--empty-state);
      font-size: 1.3em;
      font-weight: 600;
      letter-spacing: -0.01em;
      margin: 0 0 1.2em;
    }
    .empty-state-message { color: var(--muted); }
    .empty-state-list { display: flex; flex-direction: column; }
    .empty-state-row {
      display: block;
      padding: 0.7em 0.2em;
      border: none;
      border-bottom: 1px solid var(--border-faint);
      border-radius: 6px;
      text-decoration: none;
      transition: background 0.12s ease;
    }
    .empty-state-row:hover { background: var(--hover-row-overlay); }
    .empty-state-row:last-child { border-bottom: none; }
    .empty-state-name {
      color: var(--emphasis);
      font-size: 1em;
      font-weight: 600;
    }
    .empty-state-path {
      color: var(--muted);
      font-size: 0.82em;
      margin-top: 0.15em;
    }
    """

    private func fmt(_ value: CGFloat) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", Double(value))
    }
}

// MARK: - MermaidThemeVariables

/// Accumulates `themeVariables` entries for `mermaid.initialize()`, grouped by diagram
/// family so each `Theme` color token maps onto the matching mermaid "base" theme key.
struct MermaidThemeVariables {
    private(set) var entries: [String] = []

    /// Quotes a color token's CSS value for embedding in the JSON blob.
    private func q(_ token: ColorToken) -> String { jsonString(token.css) }

    /// JSON-escapes and quotes an arbitrary string value (e.g. a font stack containing
    /// embedded double quotes), so the emitted blob stays valid JSON.
    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private mutating func set(_ key: String, _ value: String) {
        entries.append("\"\(key)\": \(value)")
    }

    private mutating func set(_ key: String, _ token: ColorToken) {
        set(key, q(token))
    }

    /// Variables shared by every diagram type: background, base node/line/text colors, font.
    mutating func addCore(_ theme: Theme) {
        set("background", theme.background)
        set("primaryColor", theme.accentPrimarySoft)
        set("primaryBorderColor", theme.accentPrimary)
        set("primaryTextColor", theme.foreground)
        set("secondaryColor", theme.codeBlockBackground)
        set("secondaryBorderColor", theme.borderFaint)
        set("secondaryTextColor", theme.foreground)
        set("tertiaryColor", theme.codeBlockBackground)
        set("tertiaryBorderColor", theme.borderFaint)
        set("tertiaryTextColor", theme.muted)
        set("lineColor", theme.accentSecondary)
        set("textColor", theme.foreground)
        set("mainBkg", theme.accentPrimarySoft)
        set("nodeBorder", theme.accentPrimary)
        set("nodeTextColor", theme.foreground)
        set("titleColor", theme.heading3)
        set("errorBkgColor", theme.codeBlockBackground)
        set("errorTextColor", theme.foreground)
        set("fontFamily", jsonString(theme.bodyFont))
    }

    /// Flowchart: node fills/borders default to `mainBkg`/`nodeBorder` above; this covers
    /// edge labels and subgraph clusters, which flowchart renders with separate keys.
    mutating func addFlowchart(_ theme: Theme) {
        set("edgeLabelBackground", theme.codeBlockBackground)
        set("clusterBkg", theme.codeBlockBackground)
        set("clusterBorder", theme.borderFaint)
        set("defaultLinkColor", theme.accentSecondary)
    }

    /// Sequence diagram: actor boxes, lifelines, activation bars, notes, labels.
    mutating func addSequence(_ theme: Theme) {
        set("actorBkg", theme.accentPrimarySoft)
        set("actorBorder", theme.accentPrimary)
        set("actorTextColor", theme.foreground)
        set("actorLineColor", theme.borderTableHeader)
        set("signalColor", theme.accentSecondary)
        set("signalTextColor", theme.foreground)
        set("labelBoxBkgColor", theme.codeBlockBackground)
        set("labelBoxBorderColor", theme.borderFaint)
        set("labelTextColor", theme.foreground)
        set("loopTextColor", theme.muted)
        set("noteBkgColor", theme.codeBlockBackground)
        set("noteBorderColor", theme.borderFaint)
        set("noteTextColor", theme.muted)
        set("activationBkgColor", theme.accentPrimarySoft)
        set("activationBorderColor", theme.accentPrimary)
        set("sequenceNumberColor", theme.background)
    }

    /// Class diagram: class boxes, member text, relation lines.
    mutating func addClass(_ theme: Theme) {
        set("classText", theme.foreground)
        set("classBkg", theme.accentPrimarySoft)
        set("classBorder", theme.accentPrimary)
    }

    /// State diagram: state boxes, composite clusters, transition labels.
    mutating func addState(_ theme: Theme) {
        set("labelColor", theme.foreground)
        set("stateLabelColor", theme.foreground)
        set("stateBkg", theme.accentPrimarySoft)
        set("transitionColor", theme.accentSecondary)
        set("transitionLabelColor", theme.muted)
        set("specialStateColor", theme.accentPrimary)
        set("compositeBackground", theme.codeBlockBackground)
        set("compositeTitleBackground", theme.codeBlockBackground)
        set("compositeBorder", theme.borderFaint)
    }

    /// Pie chart: slice colors cycle through pie1-pie12; title/section/legend text.
    mutating func addPie(_ theme: Theme) {
        let palette = [theme.accentPrimary, theme.accentSecondary, theme.heading3,
                       theme.accentPrimaryHover, theme.emphasis, theme.muted]
        for (i, color) in palette.enumerated() {
            set("pie\(i + 1)", color)
        }
        set("pieOpacity", "\"0.85\"")
        set("pieOuterStrokeColor", theme.borderFaint)
        set("pieTitleTextColor", theme.heading3)
        set("pieSectionTextColor", theme.background)
        set("pieLegendTextColor", theme.foreground)
        set("pieStrokeColor", theme.codeBlockBackground)
    }

    /// Entity relationship diagram: entity boxes, attribute rows, relation lines/labels.
    mutating func addER(_ theme: Theme) {
        set("erEntityBackground", theme.accentPrimarySoft)
        set("erEntityBorder", theme.accentPrimary)
        set("erAttributeBackgroundColorEven", theme.codeBlockBackground)
        set("erAttributeBackgroundColorOdd", theme.background)
        set("erLineColor", theme.accentSecondary)
        set("erLineLabelBackground", theme.codeBlockBackground)
        set("erLineLabelColor", theme.foreground)
    }

    /// Gantt chart: section rows, grid, task bars by status (active/done/crit).
    mutating func addGantt(_ theme: Theme) {
        set("sectionBkgColor", theme.codeBlockBackground)
        set("altSectionBkgColor", theme.background)
        set("gridColor", theme.borderFaint)
        set("todayLineColor", theme.accentPrimaryHover)
        set("taskBkgColor", theme.accentPrimarySoft)
        set("taskBorderColor", theme.accentPrimary)
        set("taskTextColor", theme.foreground)
        set("taskTextOutsideColor", theme.foreground)
        // Mermaid forces active/active+crit task text to this color with `!important`
        // regardless of whether the label sits inside the bar (light fill) or overflows
        // outside it (dark page background) for short bars, so no single value contrasts
        // well in both places; a mid-tone reads on both rather than vanishing on either.
        set("taskTextDarkColor", theme.muted)
        set("activeTaskBkgColor", theme.accentPrimary)
        set("activeTaskBorderColor", theme.accentPrimaryHover)
        // Mermaid forces done-task text to taskTextDarkColor (no light variant exists for
        // it), so the done fill must be a mid-tone light enough for dark text to read,
        // unlike most other "faint" surfaces in this theme.
        set("doneTaskBkgColor", theme.muted)
        set("doneTaskBorderColor", theme.muted)
        set("critBkgColor", theme.accentSecondary)
        set("critBorderColor", theme.heading3)
    }

    /// gitGraph: branch colors cycle through git0-3; labels readable on the warm background.
    mutating func addGitGraph(_ theme: Theme) {
        set("git0", theme.accentPrimary)
        set("git1", theme.accentSecondary)
        set("git2", theme.heading3)
        set("git3", theme.accentPrimaryHover)
        set("gitBranchLabel0", theme.background)
        set("gitBranchLabel1", theme.background)
        set("commitLabelColor", theme.foreground)
        set("commitLabelBackground", theme.codeBlockBackground)
    }
}

// MARK: - ThemeOverride

/// All-optional mirror of `Theme` for partial user overrides. Any field the user
/// specifies wins; unspecified fields fall back to the base theme.
private struct ThemeOverride: Codable {
    var background: ColorToken?
    var sidebarBackground: ColorToken?
    var codeBlockBackground: ColorToken?
    var inlineCodeBackground: ColorToken?
    var foreground: ColorToken?
    var heading3: ColorToken?
    var heading4: ColorToken?
    var emphasis: ColorToken?
    var muted: ColorToken?
    var emptyState: ColorToken?
    var accentPrimary: ColorToken?
    var accentPrimaryHover: ColorToken?
    var accentPrimarySoft: ColorToken?
    var accentSecondary: ColorToken?
    var syntaxKeyword: ColorToken?
    var syntaxType: ColorToken?
    var syntaxFunction: ColorToken?
    var syntaxNumber: ColorToken?
    var sidebarItemText: ColorToken?
    var sidebarTitleText: ColorToken?
    var sidebarSeparator: ColorToken?
    var chromeBarBackground: ColorToken?
    var chromePillBackground: ColorToken?
    var chromeIcon: ColorToken?
    var chromeFieldBackground: ColorToken?
    var chromeFieldText: ColorToken?
    var chromeFieldPlaceholder: ColorToken?
    var chromeFieldBorder: ColorToken?
    var chromeFieldFocusBorder: ColorToken?
    var chromeFieldSelection: ColorToken?
    var borderFaint: ColorToken?
    var borderTableCell: ColorToken?
    var borderTableHeader: ColorToken?
    var hoverRowOverlay: ColorToken?
    var hoverItemOverlay: ColorToken?
    var scrollbarThumb: ColorToken?
    var scrollbarThumbHover: ColorToken?
    var bodyFont: String?
    var monoFont: String?
    var baseFontSize: CGFloat?
    var codeFontSize: CGFloat?
    var lineHeight: CGFloat?
    var contentPaddingVertical: CGFloat?
    var contentPaddingHorizontal: CGFloat?
    var maxContentWidth: CGFloat?

    func apply(to base: Theme) -> Theme {
        var theme = base
        if let v = background { theme.background = v }
        if let v = sidebarBackground { theme.sidebarBackground = v }
        if let v = codeBlockBackground { theme.codeBlockBackground = v }
        if let v = inlineCodeBackground { theme.inlineCodeBackground = v }
        if let v = foreground { theme.foreground = v }
        if let v = heading3 { theme.heading3 = v }
        if let v = heading4 { theme.heading4 = v }
        if let v = emphasis { theme.emphasis = v }
        if let v = muted { theme.muted = v }
        if let v = emptyState { theme.emptyState = v }
        if let v = accentPrimary { theme.accentPrimary = v }
        if let v = accentPrimaryHover { theme.accentPrimaryHover = v }
        if let v = accentPrimarySoft { theme.accentPrimarySoft = v }
        if let v = accentSecondary { theme.accentSecondary = v }
        if let v = syntaxKeyword { theme.syntaxKeyword = v }
        if let v = syntaxType { theme.syntaxType = v }
        if let v = syntaxFunction { theme.syntaxFunction = v }
        if let v = syntaxNumber { theme.syntaxNumber = v }
        if let v = sidebarItemText { theme.sidebarItemText = v }
        if let v = sidebarTitleText { theme.sidebarTitleText = v }
        if let v = sidebarSeparator { theme.sidebarSeparator = v }
        if let v = chromeBarBackground { theme.chromeBarBackground = v }
        if let v = chromePillBackground { theme.chromePillBackground = v }
        if let v = chromeIcon { theme.chromeIcon = v }
        if let v = chromeFieldBackground { theme.chromeFieldBackground = v }
        if let v = chromeFieldText { theme.chromeFieldText = v }
        if let v = chromeFieldPlaceholder { theme.chromeFieldPlaceholder = v }
        if let v = chromeFieldBorder { theme.chromeFieldBorder = v }
        if let v = chromeFieldFocusBorder { theme.chromeFieldFocusBorder = v }
        if let v = chromeFieldSelection { theme.chromeFieldSelection = v }
        if let v = borderFaint { theme.borderFaint = v }
        if let v = borderTableCell { theme.borderTableCell = v }
        if let v = borderTableHeader { theme.borderTableHeader = v }
        if let v = hoverRowOverlay { theme.hoverRowOverlay = v }
        if let v = hoverItemOverlay { theme.hoverItemOverlay = v }
        if let v = scrollbarThumb { theme.scrollbarThumb = v }
        if let v = scrollbarThumbHover { theme.scrollbarThumbHover = v }
        if let v = bodyFont { theme.bodyFont = v }
        if let v = monoFont { theme.monoFont = v }
        if let v = baseFontSize { theme.baseFontSize = v }
        if let v = codeFontSize { theme.codeFontSize = v }
        if let v = lineHeight { theme.lineHeight = v }
        if let v = contentPaddingVertical { theme.contentPaddingVertical = v }
        if let v = contentPaddingHorizontal { theme.contentPaddingHorizontal = v }
        if let v = maxContentWidth { theme.maxContentWidth = v }
        return theme
    }
}
