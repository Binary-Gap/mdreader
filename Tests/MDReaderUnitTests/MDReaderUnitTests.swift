import XCTest
@testable import MDReader

/// Unit coverage for the pure helpers behind navigation + rendering: GitHub URL
/// canonicalization, YAML frontmatter stripping, and the mermaid-fence rewrite
/// path. These are logic-only (no UI, no network), so they run fast and
/// deterministically alongside the black-box XCUITest suite.
final class MDReaderUnitTests: XCTestCase {

    // MARK: - GitHub raw URL canonicalization

    /// A github.com `/edit/` web-editor URL rewrites to raw.githubusercontent.com,
    /// so pasting the edit URL fetches the file bytes instead of the GitHub app page.
    func testEditURLRewritesToRaw() {
        let input = URL(string: "https://github.com/mermaid-js/mermaid/edit/develop/packages/mermaid/src/docs/syntax/requirementDiagram.md")!
        let result = MainWindowController.canonicalGitHubRawURL(input)
        XCTAssertEqual(result?.absoluteString,
                       "https://raw.githubusercontent.com/mermaid-js/mermaid/develop/packages/mermaid/src/docs/syntax/requirementDiagram.md")
    }

    /// A github.com `/blob/` file-viewer URL rewrites to the same raw host.
    func testBlobURLRewritesToRaw() {
        let input = URL(string: "https://github.com/owner/repo/blob/main/docs/README.md")!
        let result = MainWindowController.canonicalGitHubRawURL(input)
        XCTAssertEqual(result?.absoluteString,
                       "https://raw.githubusercontent.com/owner/repo/main/docs/README.md")
    }

    /// A github.com `/raw/` URL (the tail already matches the raw host layout, e.g.
    /// `refs/heads/master/…`) rewrites to raw.githubusercontent.com verbatim.
    func testRawURLRewritesToRaw() {
        let input = URL(string: "https://github.com/markedjs/marked/raw/refs/heads/master/README.md")!
        let result = MainWindowController.canonicalGitHubRawURL(input)
        XCTAssertEqual(result?.absoluteString,
                       "https://raw.githubusercontent.com/markedjs/marked/refs/heads/master/README.md")
    }

    /// URLs already on raw.githubusercontent.com, non-github hosts, and github.com
    /// URLs that aren't blob/edit file views return nil (caller keeps the original).
    func testNonRewritableURLsReturnNil() {
        let untouched = [
            "https://raw.githubusercontent.com/owner/repo/main/z.md",
            "https://example.com/foo.md",
            "https://github.com/owner/repo",                 // repo root, no blob/edit
            "https://github.com/owner/repo/tree/main/docs",  // tree view, not a file
        ]
        for str in untouched {
            let result = MainWindowController.canonicalGitHubRawURL(URL(string: str)!)
            XCTAssertNil(result, "Expected nil for non-rewritable URL: \(str)")
        }
    }

    // MARK: - Raw-markdown source classification (pre-commit redirect)

    /// A github.com blob/edit/raw URL resolves to its raw.githubusercontent.com
    /// bytes URL (so a plain-page load of it gets re-fetched + themed), NEVER the
    /// original github.com app URL (which serves HTML, not markdown).
    func testRawMarkdownSourceCanonicalizesGitHubURLs() {
        let cases = [
            "https://github.com/markedjs/marked/blob/master/README.md",
            "https://github.com/markedjs/marked/raw/refs/heads/master/README.md",
            "https://github.com/owner/repo/edit/main/docs/README.md",
        ]
        for str in cases {
            let result = MainWindowController.rawMarkdownSource(for: URL(string: str)!)
            XCTAssertEqual(result?.host, "raw.githubusercontent.com",
                           "Expected raw host for \(str), got \(result?.absoluteString ?? "nil")")
        }
    }

    /// A raw.githubusercontent.com (or other-host) .md URL is its own byte source.
    func testRawMarkdownSourcePassesThroughRawHosts() {
        let input = URL(string: "https://raw.githubusercontent.com/owner/repo/main/README.md")!
        XCTAssertEqual(MainWindowController.rawMarkdownSource(for: input)?.absoluteString,
                       input.absoluteString)
    }

    /// Non-markdown pages, and github.com pages that aren't blob/edit/raw file views,
    /// are NOT treated as raw markdown (return nil, so they load as normal web pages).
    func testRawMarkdownSourceReturnsNilForNonMarkdown() {
        let notMarkdown = [
            "https://github.com/markedjs/marked",              // repo root (app page)
            "https://github.com/markedjs/marked/tree/master",  // tree view (app page)
            "https://example.com/page.html",                   // plain web page
            "https://marked.js.org/",                          // no .md extension
        ]
        for str in notMarkdown {
            XCTAssertNil(MainWindowController.rawMarkdownSource(for: URL(string: str)!),
                         "Expected nil (non-markdown) for \(str)")
        }
    }

    // MARK: - YAML frontmatter stripping

    /// A leading `---`-delimited frontmatter block is removed so it is not rendered
    /// as a stray heading + horizontal rule; the document body survives intact.
    func testStripsLeadingFrontmatter() {
        let source = "---\ntitle: Hello\ntags: [a, b]\n---\n\n# Body\n\ntext"
        let stripped = MarkdownRenderer.strippingFrontmatter(source)
        XCTAssertEqual(stripped, "# Body\n\ntext")
    }

    /// A `...` closing fence is accepted as an alternative to `---`.
    func testStripsFrontmatterWithDotClose() {
        let source = "---\ntitle: X\n...\nbody"
        XCTAssertEqual(MarkdownRenderer.strippingFrontmatter(source), "body")
    }

    /// A document that merely opens with a horizontal rule (no closing fence) is
    /// left untouched, so real content starting with `---` is never eaten.
    func testLeavesHorizontalRuleDocumentIntact() {
        let source = "---\n\nJust a rule above, no frontmatter here.\n"
        XCTAssertEqual(MarkdownRenderer.strippingFrontmatter(source), source)
    }

    /// A document with no leading fence at all is returned verbatim.
    func testLeavesPlainDocumentIntact() {
        let source = "# Title\n\nNo frontmatter.\n"
        XCTAssertEqual(MarkdownRenderer.strippingFrontmatter(source), source)
    }

    // MARK: - Mermaid fence detection in the rendered document

    /// The generated document rewrites any `language-mermaid*` fence (including the
    /// mermaid docs' `mermaid-example` convention) into a `pre.mermaid` holder and
    /// injects the mermaid runtime. Asserts on the emitted HTML/JS, not on render.
    func testMermaidExampleFenceIsWiredForRendering() {
        let html = MarkdownRenderer(theme: .dark)
            .html(forMarkdown: "```mermaid-example\npie\n  \"A\": 10\n```\n")
        // The DOM-rewrite selector must match the -example fence class.
        XCTAssertTrue(html.contains(#"code[class*="language-mermaid"]"#),
                      "Rewrite selector should match any language-mermaid* fence")
        // The mermaid runtime block is only emitted when a mermaid fence is present.
        XCTAssertTrue(html.contains("mdreader-mermaid-"),
                      "Per-block mermaid render loop should be injected for a mermaid fence")
    }

    /// A document with no mermaid fence does not pull in the 3.4MB mermaid runtime.
    func testNoMermaidRuntimeWithoutFence() {
        let html = MarkdownRenderer(theme: .dark)
            .html(forMarkdown: "# Plain\n\nNo diagrams here.\n")
        XCTAssertFalse(html.contains("mdreader-mermaid-"),
                       "Mermaid render loop should be absent when no fence is present")
    }

    // MARK: - Zoom persistence

    /// The shared zoom preference round-trips through UserDefaults and clamps to the
    /// allowed magnification range, so a newly opened file inherits a sane zoom.
    func testPersistedMagnificationRoundTripsAndClamps() {
        let key = MainWindowController.magnificationDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // Unset -> defaults to 1.0.
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(MainWindowController.persistedMagnification, 1.0, accuracy: 0.0001)

        // A normal value round-trips.
        MainWindowController.persistedMagnification = 1.5
        XCTAssertEqual(MainWindowController.persistedMagnification, 1.5, accuracy: 0.0001)

        // Out-of-range values are clamped on write.
        MainWindowController.persistedMagnification = 99
        XCTAssertEqual(MainWindowController.persistedMagnification,
                       MainWindowController.maxMagnification, accuracy: 0.0001)
        MainWindowController.persistedMagnification = 0.01
        XCTAssertEqual(MainWindowController.persistedMagnification,
                       MainWindowController.minMagnification, accuracy: 0.0001)
    }

    // MARK: - Theme variant persistence + loading

    /// The selected theme variant round-trips through UserDefaults, and a missing or
    /// unknown stored value falls back to `.dark` (the safe default).
    func testThemeVariantPersistsAndDefaultsToDark() {
        let key = "MDReaderThemeVariant"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // Unset -> defaults to dark.
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(ThemeVariant.current, .dark)

        // Round-trips.
        ThemeVariant.current = .light
        XCTAssertEqual(ThemeVariant.current, .light)

        // Unknown stored value -> dark.
        UserDefaults.standard.set("chartreuse", forKey: key)
        XCTAssertEqual(ThemeVariant.current, .dark)
    }

    /// `toggled` flips between the two variants.
    func testThemeVariantToggle() {
        XCTAssertEqual(ThemeVariant.dark.toggled, .light)
        XCTAssertEqual(ThemeVariant.light.toggled, .dark)
    }

    /// Loading each variant yields the expected palette: the bundled JSON decodes
    /// into a full theme whose background matches the hardcoded Swift fallback, so
    /// the JSON and the safe default stay in lockstep. (Assumes no user theme.json
    /// override of `background` is present in the test environment.)
    func testLoadVariantMatchesHardcodedBackground() {
        XCTAssertEqual(Theme.load(variant: .dark).background, Theme.dark.background)
        XCTAssertEqual(Theme.load(variant: .light).background, Theme.light.background)
    }

    /// The two hardcoded fallback themes are visibly distinct (dark vs light
    /// background), so a variant switch actually changes the rendered surface.
    func testHardcodedThemesDiffer() {
        XCTAssertNotEqual(Theme.dark.background, Theme.light.background)
        XCTAssertNotEqual(Theme.dark.foreground, Theme.light.foreground)
    }
}
