import Foundation

// Renders a markdown file to a full themed HTML document for display in a WKWebView.
// GitHub-flavored markdown is parsed in-page by the bundled marked.js, with code
// blocks syntax-highlighted by the bundled highlight.js. Mermaid fenced blocks are
// handed to the bundled mermaid runtime. The raw markdown is injected as text into a
// script tag and converted on load, so tables, task lists, strikethrough, autolinks,
// and per-language code coloring all match GitHub's rendering. The themed shell +
// scroll/keyboard JS are ported from spec-features.
final class MarkdownRenderer {
    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
    }

    // Reads the .md file at `path`, converts it to HTML, and wraps it in a themed document.
    // Returns an error document (never throws) if the file cannot be read.
    func html(forMarkdownAt path: String) -> String {
        let markdown: String
        do {
            markdown = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            let escaped = Self.escapeHTML(error.localizedDescription)
            return document(body: "<p>Could not read file: \(escaped)</p>")
        }
        return html(forMarkdown: markdown)
    }

    // Wraps an in-memory markdown string in the themed document (used for remote raw
    // markdown fetched over http(s), which never touches disk).
    func html(forMarkdown markdown: String) -> String {
        return document(markdownSource: markdown)
    }

    // Renders the themed empty-state document shown when the app launches with no
    // file: a centered "no file open" message plus a list of recent files (name
    // prominent, full path dimmer beneath). Each row links via the custom
    // `mdreader-recent:` scheme so MainWindowController's navigation delegate can
    // intercept the click instead of the webview navigating to a bare file:// path.
    func emptyStateHTML(recentPaths: [String]) -> String {
        let rows = recentPaths.map { path -> String in
            let name = Self.escapeHTML((path as NSString).lastPathComponent)
            let shortened = Self.escapeHTML((path as NSString).abbreviatingWithTildeInPath)
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return """
            <a class="empty-state-row" href="mdreader-recent:\(encoded)">
              <div class="empty-state-name">\(name)</div>
              <div class="empty-state-path">\(shortened)</div>
            </a>
            """
        }.joined(separator: "\n")

        let listOrMessage = recentPaths.isEmpty
            ? "<p class=\"empty-state-message\">No recent files.</p>"
            : "<div class=\"empty-state-list\">\n\(rows)\n</div>"

        let body = """
        <div class="empty-state">
          <h1 class="empty-state-title">No File Open</h1>
          \(listOrMessage)
        </div>
        """
        return document(body: body)
    }

    // MARK: - Bundled JS runtimes

    /// Reads a bundled JS resource once. Nil if missing.
    private static func bundledScript(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return source
    }

    /// marked.js — GitHub-flavored markdown parser. Read once from the app bundle.
    private static let markedScript: String? = bundledScript("marked.min")

    /// highlight.js — code syntax highlighter (bundles ~40 common languages). Read once.
    private static let highlightScript: String? = bundledScript("highlight.min")

    /// mermaid runtime, read once from the app bundle. Nil if missing.
    private static let mermaidScript: String? = bundledScript("mermaid.min")

    /// The mermaid runtime + a themed init, appended after markdown renders so it can
    /// find any `pre.mermaid` blocks the parser produced. mermaid is 3.4MB, so it is
    /// only emitted when the source actually contains a mermaid fenced block.
    private func mermaidBlock(markdownSource: String) -> String {
        guard markdownSource.contains("```mermaid"), let script = Self.mermaidScript else {
            return ""
        }
        return """
        <style>\(theme.mermaidStyleRules())</style>
        <script>\(script)</script>
        <script>
        (function () {
          var m = (typeof mermaid !== 'undefined') ? mermaid
                : (typeof __esbuild_esm_mermaid_nm !== 'undefined' ? __esbuild_esm_mermaid_nm.mermaid : null);
          if (!m) { return; }
          m.initialize(\(theme.mermaidConfigJSON()));
          // Render each diagram independently so a single block mermaid can't parse
          // (invalid example, unsupported/plugin-only type) fails only itself instead
          // of aborting the whole run and leaving every later diagram blank.
          var blocks = Array.prototype.slice.call(document.querySelectorAll('pre.mermaid'));
          blocks.forEach(function (node, i) {
            var source = node.textContent;
            m.render('mdreader-mermaid-' + i, source).then(function (out) {
              node.innerHTML = out.svg;
              if (out.bindFunctions) { out.bindFunctions(node); }
            }).catch(function (err) {
              // Leave the original source visible, tagged as un-rendered, and drop any
              // stray error node mermaid appended to <body> so one bad block is inert.
              node.classList.add('mermaid-error');
              var orphan = document.getElementById('dmermaid-mermaid-' + i)
                        || document.getElementById('mdreader-mermaid-' + i);
              if (orphan && orphan.parentNode === document.body) { orphan.remove(); }
            });
          });
        })();
        </script>
        """
    }

    // MARK: - Document shell

    /// Themed shell for pre-rendered HTML (empty state, error messages). No markdown
    /// parsing runtime is loaded.
    private func document(body: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(theme.css())
        </style>
        </head>
        <body>
        <div id="content" class="content">
        \(body)
        </div>
        \(Self.behaviorScript)
        </body>
        </html>
        """
    }

    /// Themed shell that parses `markdownSource` in-page with marked.js and highlights
    /// code with highlight.js. The raw markdown is injected as the text content of a
    /// script tag (so it is never HTML-parsed); the closing-tag sequence is the only
    /// thing that must be neutralized. mermaid fenced blocks are rewritten to
    /// `pre.mermaid` before highlighting so the mermaid runtime can render them.
    private func document(markdownSource rawSource: String) -> String {
        // Strip a leading YAML frontmatter block (metadata delimited by --- fences at
        // the very top) so it is not rendered as a stray heading + horizontal rule.
        let markdownSource = Self.strippingFrontmatter(rawSource)
        // A literal "</script>" inside the source would terminate the data island
        // early; split the tag so the browser keeps it as text.
        let safeSource = markdownSource.replacingOccurrences(of: "</script>", with: "<\\/script>")
        let marked = Self.markedScript ?? ""
        let highlight = Self.highlightScript ?? ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(theme.css())
        </style>
        <style>
        \(theme.highlightCSS())
        </style>
        </head>
        <body>
        <div id="content" class="content markdown-body"></div>
        <script type="text/markdown" id="markdown-source">\(safeSource)</script>
        <script>\(marked)</script>
        <script>\(highlight)</script>
        <script>
        (function () {
          var src = document.getElementById('markdown-source').textContent;
          marked.setOptions({ gfm: true, breaks: false });
          var content = document.getElementById('content');
          content.innerHTML = marked.parse(src);
          // Rewrite mermaid code blocks into <pre class="mermaid"> for the runtime,
          // before highlighting so hljs never touches diagram source. Matches any
          // language-mermaid* fence (mermaid, mermaid-example, mermaid-nocode) so the
          // mermaid docs' -example fences render too.
          content.querySelectorAll('pre > code[class*="language-mermaid"]').forEach(function (code) {
            var holder = document.createElement('pre');
            holder.className = 'mermaid';
            holder.textContent = code.textContent;
            code.parentElement.replaceWith(holder);
          });
          // Syntax-highlight each remaining fenced code block. hljs reads the
          // language-<lang> class marked emits, falling back to auto-detection.
          content.querySelectorAll('pre code').forEach(function (code) {
            try { hljs.highlightElement(code); } catch (e) {}
          });
        })();
        </script>
        \(Self.behaviorScript)
        \(mermaidBlock(markdownSource: markdownSource))
        </body>
        </html>
        """
    }

    // Vim-style scroll/keyboard handling ported from template.html (§3 spec-features).
    // The native key monitor in MainWindowController drives most actions, but this keeps
    // in-page handling working if the webview has focus.
    private static let behaviorScript = """
    <script>
    (function () {
      var SCROLL_STEP = 60;
      function pageAmount() { return window.innerHeight * 0.8; }
      document.addEventListener('keydown', function (e) {
        if (e.metaKey || e.altKey) { return; }
        switch (e.key) {
          case 'j': window.scrollBy(0, SCROLL_STEP); break;
          case 'k': window.scrollBy(0, -SCROLL_STEP); break;
          case 'd':
            if (e.ctrlKey) { e.preventDefault(); window.scrollBy(0, pageAmount()); }
            break;
          case 'u':
            if (e.ctrlKey) { e.preventDefault(); window.scrollBy(0, -pageAmount()); }
            break;
          case 'g': window.scrollTo(0, 0); break;
          case 'G': window.scrollTo(0, document.body.scrollHeight); break;
        }
      });
      // Open http(s) links in the default browser rather than navigating in-place.
      document.addEventListener('click', function (e) {
        var a = e.target.closest && e.target.closest('a');
        if (a && /^https?:/i.test(a.getAttribute('href') || '')) {
          // WKWebView navigation policy in the host opens external; nothing extra needed here.
        }
      });
    })();
    </script>
    """

    // MARK: - Escaping

    // Removes a leading YAML frontmatter block: a `---` fence on the very first line,
    // its content, and a closing `---` or `...` fence line. Returns the source unchanged
    // if it does not open with a fence or the closing fence is never found (so a document
    // that merely starts with a horizontal rule is left intact).
    static func strippingFrontmatter(_ source: String) -> String {
        // Normalize CRLF so the fence check works regardless of line endings.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") || normalized == "---" else { return source }

        let lines = normalized.components(separatedBy: "\n")
        // lines[0] is the opening "---"; scan for the closing fence after it.
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                let body = lines[(index + 1)...].joined(separator: "\n")
                // Drop leading blank lines left behind by the stripped block.
                return String(body.drop(while: { $0 == "\n" }))
            }
        }
        // No closing fence: not real frontmatter, leave the source as-is.
        return source
    }

    static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(ch)
            }
        }
        return result
    }
}
