# Rendering architecture: WebKit vs pure Swift

MDReader renders markdown by emitting an HTML string (`MarkdownRenderer`) styled
with the `Theme` CSS tokens and displaying it in a `WKWebView`
(`MainWindowController`). This note records why WebKit is used and what a
pure-Swift rendering path would cost, so the tradeoff is settled and doesn't get
re-litigated each session.

## Parse vs render are separate problems

- Parsing markdown is already trivially pure-Swift. Apple ships `swift-markdown`
  (CommonMark/GFM, built on cmark-gfm), and Foundation's
  `AttributedString(markdown:)` handles inline markdown natively (macOS 12+). No
  browser needed for the parse step.
- Rendering the parse tree into a view is where WebKit earns its place. The
  current app sidesteps native layout entirely by handing styled HTML to a web
  engine.

## Pure-Swift render paths (if WebKit is ever dropped)

- NSTextView + NSAttributedString: walk the `swift-markdown` tree, map `Theme`
  tokens to text attributes (fonts, colors, paragraph styles), drop into an
  `NSTextView`. Most idiomatic AppKit path; `Theme`'s prose tokens map cleanly.
- SwiftUI: `Text` renders `AttributedString` markdown directly, or use
  `swift-markdown-ui` (renders the full tree to themed SwiftUI views).
- Down and similar AppKit libraries bridge HTML→NSAttributedString (or use
  WebKit under the hood), so they don't actually remove the web dependency.

## What WebKit does for free (the cost of leaving)

TextKit/NSAttributedString has no answer for several things the reader relies on:

- GFM tables: TextKit has no table layout. Tables become a manual
  NSGridView/custom-layout problem.
- Code blocks: syntax highlighting, horizontal scroll, the `pre` styling.
- Images, nested blockquotes, task lists, wrapping inside fenced blocks.
- Text selection across mixed content, link handling, find-on-page.
- The theme's CSS-driven typographic flourishes are all CSS and would need
  per-feature reimplementation as attributed-string attributes or custom drawing:
  the `* * *` scene-break (`hr::before`), the hanging `h2::before` amber tick,
  small-caps table headers, old-style numerals (`onum`). Pseudo-elements and
  small-caps get especially fiddly in TextKit.

## Verdict

Possible but not a free swap. Worth considering only with a concrete driver
(WebKit memory/startup overhead, removing the JS surface, dependency reduction).
For that, NSTextView + NSAttributedString is the right path for prose, but table
layout and code-block rendering get rebuilt from scratch and the CSS flourishes
get reimplemented. For a reader whose selling point is "reads like a book" with
tables and styled code, WebKit is doing real work. Default to keeping it absent a
specific reason to move.
