import Foundation

/// `--dump-css` CLI mode: print a slice of the rendered document's stylesheet to
/// stdout and exit, without ever starting the GUI. It exists so other renderers
/// (the VS Code extension's markdown preview) can reuse this app's exact theme
/// instead of keeping a hand-copied stylesheet that drifts.
///
/// Usage: `MDReader --dump-css <mode> [dark|light]` (variant defaults to `dark`)
///   vars           the `--token: value;` declaration lines only, no wrapping selector
///   rules          the variant-independent element/layout rules (consume those vars)
///   highlight      the highlight.js color rules for the variant
///   mermaid-rules  the post-render mermaid overrides for the variant
///   mermaid-config the mermaid `initialize()` config as JSON
///   full           vars wrapped in `:root`, plus rules, plus highlight (a whole sheet)
///
/// The dumped theme is the fully resolved one, so a user override in
/// `~/.config/mdreader/theme.json` shows up in the dump exactly as it does in the app.
enum CSSDump {
    private enum Mode: String {
        case vars, rules, highlight, full
        case mermaidRules = "mermaid-rules"
        case mermaidConfig = "mermaid-config"

        /// Every mode name, for the usage message.
        static var allNames: String {
            CSSDump.allModes.map(\.rawValue).joined(separator: " | ")
        }
    }

    /// Runs the dump and exits the process when `--dump-css` is present, otherwise
    /// returns so the caller can continue booting the GUI.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let flagIndex = arguments.firstIndex(of: "--dump-css") else { return }

        let positionals = arguments[(flagIndex + 1)...].filter { !$0.hasPrefix("-") }
        guard let modeName = positionals.first, let mode = Mode(rawValue: modeName) else {
            fail("--dump-css needs a mode: \(Mode.allNames)")
        }
        let variantName = positionals.dropFirst().first ?? ThemeVariant.dark.rawValue
        guard let variant = ThemeVariant(rawValue: variantName) else {
            fail("unknown theme variant '\(variantName)': expected dark or light")
        }

        let theme = Theme.load(variant: variant)
        switch mode {
        case .vars:
            print(theme.cssVariableDeclarations())
        case .rules:
            print(Theme.styleRulesCSS)
        case .highlight:
            print(theme.highlightCSS())
        case .mermaidRules:
            print(theme.mermaidStyleRules())
        case .mermaidConfig:
            print(theme.mermaidConfigJSON())
        case .full:
            print(theme.css())
            print(theme.highlightCSS())
        }
        exit(0)
    }

    private static let allModes: [Mode] = [.vars, .rules, .highlight, .mermaidRules, .mermaidConfig, .full]

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("MDReader --dump-css: \(message)\n".utf8))
        exit(2)
    }
}
