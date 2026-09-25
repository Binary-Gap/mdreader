import Foundation

/// Builds the JavaScript that injects/toggles the keyboard-shortcuts cheat sheet
/// as a themed modal over the current document. The modal lives inside the
/// WKWebView (not a separate NSWindow) so it renders on top of whatever is shown
/// and inherits the reading-lamp look via colors resolved from the `Theme`.
///
/// Colors are inlined (not CSS custom properties) so the modal looks identical on
/// raw web pages, which don't carry the themed `:root` variables.
enum KeyboardShortcutsOverlay {

    /// Container/element ids, kept in one place so the toggle/dismiss logic and the
    /// injected markup agree.
    private static let rootID = "mdreader-shortcuts-overlay"

    /// JS expression that returns true while the overlay is on screen. Used by the
    /// toggle to decide between showing and dismissing.
    static var isVisibleJS: String {
        "(function(){var e=document.getElementById('\(rootID)');return !!e;})()"
    }

    /// JS that removes the overlay if present (no-op otherwise).
    static var dismissJS: String {
        """
        (function(){var e=document.getElementById('\(rootID)');if(e){e.remove();}})();
        """
    }

    /// JS that builds and shows the overlay for the given rows. Dismisses on
    /// backdrop click, the close (×) button, or Escape. Guards against double-insert.
    ///
    /// `magnification` is the current WKWebView zoom; the overlay counter-scales by
    /// its inverse so the modal renders at a constant, full size regardless of how
    /// the underlying markdown view is zoomed.
    static func showJS(rows: [KeyMap.ShortcutRow], theme: Theme, magnification: CGFloat) -> String {
        let zoom = magnification > 0 ? magnification : 1
        let inverseScale = 1 / zoom
        // Grow the fixed layer by the zoom factor so, after the inverse scale, it
        // still exactly covers the visible viewport.
        let coverPercent = zoom * 100
        let backdrop = "rgba(0,0,0,0.55)"
        let panelBg = theme.sidebarBackground.css
        let border = theme.borderFaint.css
        let title = theme.emphasis.css
        let label = theme.foreground.css
        let keyText = theme.accentPrimary.css
        let keyBg = theme.accentPrimarySoft.css
        let keyBorder = theme.chromeFieldBorder.css
        let muted = theme.muted.css
        let font = theme.bodyFont
        let monoFont = theme.monoFont

        let rowsHTML = rows.map { row in
            let combos = row.keyCombos
                .map { "<kbd class=\"mdr-key\">\(escape($0))</kbd>" }
                .joined(separator: "<span class=\"mdr-or\">or</span>")
            return """
            <div class="mdr-row"><span class="mdr-label">\(escape(row.label))</span><span class="mdr-keys">\(combos)</span></div>
            """
        }.joined()

        let css = """
        #\(rootID){position:fixed;top:0;left:0;width:\(coverPercent)vw;height:\(coverPercent)vh;transform:scale(\(inverseScale));transform-origin:top left;z-index:2147483647;display:flex;align-items:center;justify-content:center;background:\(backdrop);backdrop-filter:blur(2px);-webkit-backdrop-filter:blur(2px);animation:mdrFade .12s ease;font-family:\(font);}
        @keyframes mdrFade{from{opacity:0}to{opacity:1}}
        #\(rootID) .mdr-panel{width:min(440px,86vw);max-height:82vh;overflow-y:auto;background:\(panelBg);border:1px solid \(border);border-radius:14px;box-shadow:0 24px 70px rgba(0,0,0,0.55);padding:22px 24px 20px;animation:mdrPop .14s cubic-bezier(.2,.9,.3,1.2);}
        @keyframes mdrPop{from{transform:translateY(8px) scale(.98);opacity:0}to{transform:none;opacity:1}}
        #\(rootID) .mdr-head{display:flex;align-items:baseline;justify-content:space-between;margin:0 0 14px;}
        #\(rootID) .mdr-title{color:\(title);font-size:15px;font-weight:650;letter-spacing:-.01em;}
        #\(rootID) .mdr-close{appearance:none;background:transparent;border:none;cursor:pointer;color:\(muted);font-size:18px;line-height:1;padding:2px 4px;border-radius:6px;transition:color .12s ease,background .12s ease;}
        #\(rootID) .mdr-close:hover{color:\(title);background:\(keyBg);}
        #\(rootID) .mdr-row{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:7px 0;border-bottom:1px solid \(border);}
        #\(rootID) .mdr-row:last-child{border-bottom:none;}
        #\(rootID) .mdr-label{color:\(label);font-size:13.5px;}
        #\(rootID) .mdr-keys{display:flex;align-items:center;gap:6px;flex-shrink:0;}
        #\(rootID) .mdr-or{color:\(muted);font-size:11px;}
        #\(rootID) .mdr-key{font-family:\(monoFont);font-size:12px;color:\(keyText);background:\(keyBg);border:1px solid \(keyBorder);border-radius:6px;padding:2px 7px;min-width:18px;text-align:center;line-height:1.5;}
        """

        return """
        (function(){
          if (document.getElementById('\(rootID)')) return;
          var style = document.getElementById('\(rootID)-style');
          if (!style) {
            style = document.createElement('style');
            style.id = '\(rootID)-style';
            style.textContent = `\(escapeTemplate(css))`;
            document.documentElement.appendChild(style);
          }
          var root = document.createElement('div');
          root.id = '\(rootID)';
          root.innerHTML = `
            <div class="mdr-panel" role="dialog" aria-label="Keyboard shortcuts">
              <div class="mdr-head">
                <span class="mdr-title">Keyboard Shortcuts</span>
                <button class="mdr-close" type="button" aria-label="Close">×</button>
              </div>
              \(escapeTemplate(rowsHTML))
            </div>`;
          function dismiss(){ root.remove(); document.removeEventListener('keydown', onKey, true); }
          function onKey(e){ if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); dismiss(); } }
          root.addEventListener('click', function(e){ if (e.target === root) dismiss(); });
          var closeBtn = root.querySelector('.mdr-close');
          if (closeBtn) closeBtn.addEventListener('click', dismiss);
          document.addEventListener('keydown', onKey, true);
          document.body.appendChild(root);
        })();
        """
    }

    /// Escape a plain-text fragment for safe insertion into an HTML string.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escape a string embedded inside a JS backtick template literal.
    private static func escapeTemplate(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
}
