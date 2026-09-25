// Renders mermaid diagrams in VS Code's markdown preview the way MDReader does: the
// parser emits a fenced `language-mermaid` code block, this rewrites it to
// `pre.mermaid` and hands it to MDReader's own bundled mermaid runtime, themed by the
// config that mdreader-mermaid-config.js carries.
//
// The 3.4MB runtime is fetched only once a document actually contains a diagram, so
// previewing ordinary markdown pays nothing for it.
(function () {
  "use strict";

  var selfScript = document.currentScript;
  var runtimePromise = null;
  var nextDiagramId = 0;

  /** Sibling file of this script, as a webview resource URL. */
  function siblingURL(fileName) {
    return selfScript.src.replace(/[^/]+$/, fileName);
  }

  /** MDReader exposes mermaid as an esbuild namespace global rather than `mermaid`. */
  function mermaidRuntime() {
    if (typeof mermaid !== "undefined") return mermaid;
    if (typeof __esbuild_esm_mermaid_nm !== "undefined") return __esbuild_esm_mermaid_nm.mermaid;
    return null;
  }

  function loadRuntime() {
    if (runtimePromise) return runtimePromise;
    runtimePromise = new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      // The preview's CSP only admits scripts carrying its nonce, which this script has.
      script.nonce = selfScript.nonce;
      script.src = siblingURL("mermaid.min.js");
      script.onload = function () {
        var runtime = mermaidRuntime();
        runtime ? resolve(runtime) : reject(new Error("mermaid runtime global missing"));
      };
      script.onerror = function () {
        reject(new Error("failed to load mermaid runtime"));
      };
      document.head.appendChild(script);
    });
    return runtimePromise;
  }

  /** The config matching whichever color theme VS Code applied to the preview body. */
  function themeConfig() {
    var configs = window.mdreaderMermaidConfig || {};
    var isLight = document.body.classList.contains("vscode-light")
      || document.body.classList.contains("vscode-high-contrast-light");
    return (isLight ? configs.light : configs.dark) || configs.dark || {};
  }

  /** Turns every mermaid fence into a `pre.mermaid` holder; returns the new holders. */
  function collectDiagrams() {
    var holders = [];
    document.querySelectorAll('pre > code[class*="language-mermaid"]').forEach(function (code) {
      var pre = code.parentElement;
      var holder = document.createElement("pre");
      holder.className = "mermaid";
      holder.textContent = code.textContent;
      // Keep the scroll-sync line mapping the preview put on the original block.
      if (pre.hasAttribute("data-line")) holder.setAttribute("data-line", pre.getAttribute("data-line"));
      if (pre.classList.contains("code-line")) holder.classList.add("code-line");
      pre.replaceWith(holder);
      holders.push(holder);
    });
    return holders;
  }

  function render(runtime, holder) {
    var id = "mdreader-mermaid-" + nextDiagramId++;
    var source = holder.textContent;
    runtime.render(id, source).then(function (out) {
      // A later content update may have replaced this node while mermaid was working.
      if (!holder.isConnected) return;
      holder.innerHTML = out.svg;
      if (out.bindFunctions) out.bindFunctions(holder);
    }).catch(function () {
      // Leave the source visible, tagged as un-rendered, and drop the stray error node
      // mermaid appends to <body>, so one bad diagram stays inert instead of spreading.
      holder.classList.add("mermaid-error");
      var orphan = document.getElementById("d" + id) || document.getElementById(id);
      if (orphan && orphan.parentNode === document.body) orphan.remove();
    });
  }

  function renderDiagrams() {
    var holders = collectDiagrams();
    if (!holders.length) return;
    loadRuntime().then(function (runtime) {
      runtime.initialize(themeConfig());
      holders.forEach(function (holder) {
        render(runtime, holder);
      });
    }).catch(function () {
      // Runtime unavailable: the fences stay readable as code blocks.
      holders.forEach(function (holder) {
        holder.classList.add("mermaid-error");
      });
    });
  }

  renderDiagrams();
  // The preview swaps body content in place on every edit without reloading scripts.
  window.addEventListener("vscode.markdown.updateContent", renderDiagrams);
})();
