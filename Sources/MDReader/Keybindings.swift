import AppKit

// Keyboard binding model for MDReader. Nerd/vim-style defaults ported from the
// Hammerspoon md_viewer keydown handler (j/k scroll, Ctrl+d/u half-page, g/G
// top/bottom) plus native additions (toggle always-on-top, reload, zoom, quit).
// User overrides load from ~/.config/mdreader/keybindings.json.

/// A single key action the window controller can drive.
enum KeyAction: String, Codable {
    case scrollDown
    case scrollUp
    case scrollTop
    case scrollBottom
    case halfPageDown
    case halfPageUp
    case toggleAlwaysOnTop
    case toggleSidebar
    case reload
    case quit
    case zoomIn
    case zoomOut
    case showAddressBar
    case navigateBack
    case navigateForward
    case showKeyboardShortcuts
    case toggleTheme

    /// Human-readable action name shown in the keyboard-shortcuts cheat sheet.
    var displayName: String {
        switch self {
        case .scrollDown: return "Scroll down"
        case .scrollUp: return "Scroll up"
        case .scrollTop: return "Jump to top"
        case .scrollBottom: return "Jump to bottom"
        case .halfPageDown: return "Half page down"
        case .halfPageUp: return "Half page up"
        case .toggleAlwaysOnTop: return "Toggle always on top"
        case .toggleSidebar: return "Toggle sidebar"
        case .reload: return "Reload"
        case .quit: return "Quit"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .showAddressBar: return "Open location"
        case .navigateBack: return "Back"
        case .navigateForward: return "Forward"
        case .showKeyboardShortcuts: return "Show keyboard shortcuts"
        case .toggleTheme: return "Toggle light/dark theme"
        }
    }

    /// Stable display order for the cheat sheet, grouped by concern (scrolling,
    /// zoom, navigation, window). Actions not listed fall to the end.
    static let displayOrder: [KeyAction] = [
        .scrollDown, .scrollUp, .halfPageDown, .halfPageUp, .scrollTop, .scrollBottom,
        .zoomIn, .zoomOut,
        .showAddressBar, .navigateBack, .navigateForward, .reload,
        .toggleSidebar, .toggleAlwaysOnTop, .toggleTheme, .showKeyboardShortcuts, .quit,
    ]
}

/// Maps a key (plus modifier flags) to an action.
struct KeyBinding {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let action: KeyAction
}

/// Ordered collection of bindings with default (nerd/vim) set and JSON override loading.
struct KeyMap {
    let bindings: [KeyBinding]

    /// Built-in nerd/vim bindings. Order matters: more specific (modifier-bearing)
    /// bindings come first so they win over a bare-key binding on the same key.
    static let defaults = KeyMap(bindings: [
        // Half-page scroll (Ctrl+d / Ctrl+u), matches md_viewer's 0.8-page jump.
        KeyBinding(key: "d", modifiers: .control, action: .halfPageDown),
        KeyBinding(key: "u", modifiers: .control, action: .halfPageUp),
        // Bottom of document: Shift+g / G.
        KeyBinding(key: "g", modifiers: .shift, action: .scrollBottom),
        KeyBinding(key: "G", modifiers: [], action: .scrollBottom),
        // Line scroll.
        KeyBinding(key: "j", modifiers: [], action: .scrollDown),
        KeyBinding(key: "k", modifiers: [], action: .scrollUp),
        // Top of document.
        KeyBinding(key: "g", modifiers: [], action: .scrollTop),
        // Native window controls.
        KeyBinding(key: "t", modifiers: [], action: .toggleAlwaysOnTop),
        KeyBinding(key: "r", modifiers: [], action: .reload),
        // Sidebar toggle: backslash (vim-family convention) and Cmd+1 (macOS sidebar convention).
        KeyBinding(key: "\\", modifiers: [], action: .toggleSidebar),
        KeyBinding(key: "1", modifiers: .command, action: .toggleSidebar),
        // Zoom: accept both bare and shifted forms of +/-/= for keyboard-layout robustness.
        KeyBinding(key: "+", modifiers: [], action: .zoomIn),
        KeyBinding(key: "=", modifiers: [], action: .zoomIn),
        KeyBinding(key: "-", modifiers: [], action: .zoomOut),
        // Address bar: Cmd+L reveals + focuses it (browser convention).
        KeyBinding(key: "l", modifiers: .command, action: .showAddressBar),
        // History navigation: Cmd+[ back, Cmd+] forward.
        KeyBinding(key: "[", modifiers: .command, action: .navigateBack),
        KeyBinding(key: "]", modifiers: .command, action: .navigateForward),
        // Keyboard-shortcuts cheat sheet: Cmd+/ (macOS help convention) and bare ?.
        KeyBinding(key: "/", modifiers: .command, action: .showKeyboardShortcuts),
        KeyBinding(key: "?", modifiers: [], action: .showKeyboardShortcuts),
        // Light/dark theme toggle: Cmd+Shift+D.
        KeyBinding(key: "d", modifiers: [.command, .shift], action: .toggleTheme),
    ])

    /// JSON entry shape: { "key": "j", "modifiers": ["control","shift"], "action": "scrollDown" }.
    private struct BindingJSON: Codable {
        let key: String
        let modifiers: [String]?
        let action: String
    }

    /// Load user keybindings from ~/.config/mdreader/keybindings.json.
    /// Falls back to `.defaults` if the file is absent, unreadable, or invalid.
    static func load() -> KeyMap {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/mdreader/keybindings.json")
        guard let data = FileManager.default.contents(atPath: path) else {
            return .defaults
        }
        do {
            let entries = try JSONDecoder().decode([BindingJSON].self, from: data)
            let parsed: [KeyBinding] = entries.compactMap { entry in
                guard let action = KeyAction(rawValue: entry.action) else {
                    // NOTE: unknown action names are skipped rather than failing the whole file.
                    return nil
                }
                let mods = parseModifiers(entry.modifiers ?? [])
                return KeyBinding(key: entry.key, modifiers: mods, action: action)
            }
            return parsed.isEmpty ? .defaults : KeyMap(bindings: parsed)
        } catch {
            // NOTE: malformed JSON falls back to defaults instead of crashing.
            return .defaults
        }
    }

    /// Resolve modifier name strings into NSEvent.ModifierFlags.
    private static func parseModifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "control", "ctrl": flags.insert(.control)
            case "command", "cmd": flags.insert(.command)
            case "option", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "function", "fn": flags.insert(.function)
            default: break
            }
        }
        return flags
    }

    // Modifier flags we compare against; ignores caps lock, numeric pad, etc.
    private static let comparedModifiers: NSEvent.ModifierFlags =
        [.control, .command, .option, .shift, .function]

    /// A single cheat-sheet row: one or more key combos that trigger `action`,
    /// each already formatted for display (e.g. "⌘L", "⌃D").
    struct ShortcutRow {
        let keyCombos: [String]
        let label: String
    }

    /// Build the cheat-sheet rows from the active bindings, grouped by action and
    /// ordered by `KeyAction.displayOrder`. Each action collapses its bound keys
    /// into a de-duplicated list of formatted combos (so `+`/`=` for zoom show once).
    func shortcutRows() -> [ShortcutRow] {
        var combosByAction: [KeyAction: [String]] = [:]
        for binding in bindings {
            let combo = KeyMap.format(key: binding.key, modifiers: binding.modifiers)
            var existing = combosByAction[binding.action] ?? []
            if !existing.contains(combo) { existing.append(combo) }
            combosByAction[binding.action] = existing
        }
        var rows: [ShortcutRow] = []
        var seen = Set<KeyAction>()
        for action in KeyAction.displayOrder {
            guard let combos = combosByAction[action], !combos.isEmpty else { continue }
            rows.append(ShortcutRow(keyCombos: combos, label: action.displayName))
            seen.insert(action)
        }
        // Any bound action not in displayOrder gets appended so nothing is hidden.
        for (action, combos) in combosByAction where !seen.contains(action) {
            rows.append(ShortcutRow(keyCombos: combos, label: action.displayName))
        }
        return rows
    }

    /// Format a key + modifier flags as a compact glyph string (⌃⌥⇧⌘ + key),
    /// matching how macOS renders shortcuts.
    private static func format(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        let label: String
        switch key {
        case "\\": label = "\\"
        default: label = key.count == 1 ? key.uppercased() : key
        }
        return glyphs + label
    }

    /// Return the action bound to a key event, or nil if no binding matches.
    func action(for event: NSEvent) -> KeyAction? {
        guard let typed = event.charactersIgnoringModifiers, !typed.isEmpty else {
            return nil
        }
        let eventMods = event.modifierFlags.intersection(KeyMap.comparedModifiers)
        for binding in bindings {
            let bindingMods = binding.modifiers.intersection(KeyMap.comparedModifiers)
            // Case-insensitive key compare; shift in the binding is matched via modifiers,
            // so normalize the typed character to lowercase for the key check.
            guard binding.key.lowercased() == typed.lowercased() else { continue }
            guard bindingMods == eventMods else { continue }
            return binding.action
        }
        return nil
    }
}
