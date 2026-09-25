// Swaps the active markdown tab between source and preview IN PLACE, instead of opening
// the preview as an extra tab beside it. VS Code registers its markdown preview as an
// editor type (`workbench.editorAssociations` can map `*.md` to it), so reopening the
// same URI with that editor type takes over the tab the source was in.
const vscode = require("vscode");

/** The editor type id of VS Code's built-in markdown preview. */
const PREVIEW_EDITOR_ID = "vscode.markdown.preview.editor";

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("mdreader.togglePreviewInPlace", togglePreviewInPlace),
  );
}

/** A markdown preview arrives as a custom-editor or webview tab; both name their type. */
function isPreviewTab(tab) {
  const viewType = tab?.input?.viewType;
  return typeof viewType === "string" && viewType.includes("markdown");
}

async function togglePreviewInPlace() {
  const activeTab = vscode.window.tabGroups.activeTabGroup.activeTab;
  if (isPreviewTab(activeTab)) {
    await showSourceInPlace(activeTab);
    return;
  }

  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "markdown") return;

  const uri = editor.document.uri;
  const viewColumn = editor.viewColumn ?? vscode.ViewColumn.Active;
  await vscode.commands.executeCommand("vscode.openWith", uri, PREVIEW_EDITOR_ID, { viewColumn });
  // A group holds one editor per resource, so the source tab is normally replaced
  // outright; close it explicitly in case this VS Code kept both.
  await closeTabs(sourceTabsFor(uri));
}

/** Back to the text editor, then drop the preview tab it was toggled from. */
async function showSourceInPlace(previewTab) {
  await vscode.commands.executeCommand("markdown.showSource");
  await closeTabs([previewTab]);
}

function sourceTabsFor(uri) {
  const target = uri.toString();
  return vscode.window.tabGroups.all
    .flatMap((group) => group.tabs)
    .filter((tab) => tab.input instanceof vscode.TabInputText && tab.input.uri.toString() === target);
}

async function closeTabs(tabs) {
  const open = tabs.filter((tab) => vscode.window.tabGroups.all.some((g) => g.tabs.includes(tab)));
  if (open.length) await vscode.window.tabGroups.close(open, true);
}

module.exports = { activate };
