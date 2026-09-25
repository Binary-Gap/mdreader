# MDReader Markdown Theme (VS Code)

Renders VS Code's **built-in** markdown preview with MDReader's theme: the same warm
reading-lamp palette, typography, highlight.js colors and mermaid styling, following the
editor's light/dark theme automatically.

It contributes styles and a preview script only, so everything the built-in preview does
(scroll sync, `Cmd+K V`, find, editor-cursor tracking) keeps working. Parsing stays
markdown-it, so extremely exotic syntax can still render slightly differently than the
app's marked.js.

## How the theme stays in sync

Colors live in one place: the app's `Sources/MDReader/Resources/theme-{dark,light}.json`.
`MDReader --dump-css <mode> [dark|light]` prints slices of the rendered document's
stylesheet, and `scripts/build-theme-css.ts` composes them into the files this extension
ships:

- `media/mdreader-theme.css` - shared element rules once, then per-variant variables,
  highlight.js colors and mermaid overrides scoped to `body.vscode-dark` /
  `body.vscode-light`.
- `media/mdreader-mermaid-config.js` - both variants' mermaid `initialize()` config.
- `media/mermaid.min.js` - the app's own mermaid runtime (git-ignored, regenerated).

Regenerate after any theme change:

```sh
mise run vscode:css          # from the repo root
```

`media/mdreader-vscode-preview.css` and `media/mdreader-mermaid-preview.js` are
hand-written: they bridge the app's DOM (`.content` wrapper, `pre.mermaid`) onto the
preview's DOM (content in `<body>`, `language-mermaid` fences) and cover preview-only
chrome like scroll-sync markers.

## Toggling the preview in place

`MDReader: Toggle Markdown Preview In Place` (`mdreader.togglePreviewInPlace`) swaps the
active tab between the markdown source and the preview, instead of opening the preview as
a second tab: it reopens the same URI with VS Code's preview editor type
(`vscode.markdown.preview.editor`) in the same editor group, and `markdown.showSource`
takes it back.

The extension binds it to `Cmd+Shift+V` / `Ctrl+Shift+V`; this machine's VS Code
keybindings (`infra/macbook/dotfiles/vscode/keybindings.json`) put it on `Cmd+E`, both
from the source and from the preview.

## Install (local, no marketplace)

```sh
ln -s ~/code/binarygap/mdreader/vscode-extension \
  ~/.vscode/extensions/binarygap.mdreader-markdown-theme
```

Then reload VS Code. Editing the CSS and reopening the preview picks up changes; adding
or removing a contributed file needs a window reload.
