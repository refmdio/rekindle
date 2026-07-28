const currentUrl = new URL("./current", import.meta.url);
const statusView = ensureStatusView();
const errorView = ensureErrorView();
let activeGeneration;
let attemptedGeneration;
let reportedError;
let loading = false;
let reloading = false;

function ensureStatusView() {
  const existing = document.getElementById("rekindle-status");
  if (existing) return existing;

  const view = document.createElement("div");
  view.id = "rekindle-status";
  view.setAttribute("role", "status");
  view.setAttribute("aria-live", "polite");
  view.textContent = "Building Rust UI\u2026";
  Object.assign(view.style, {
    boxSizing: "border-box",
    padding: "1rem",
    fontFamily: "system-ui, sans-serif"
  });
  document.body.appendChild(view);
  return view;
}

function ensureErrorView() {
  const existing = document.getElementById("rekindle-error");
  if (existing) return existing;

  const view = document.createElement("pre");
  view.id = "rekindle-error";
  view.hidden = true;
  view.setAttribute("role", "alert");
  Object.assign(view.style, {
    boxSizing: "border-box",
    margin: "0",
    padding: "1rem",
    whiteSpace: "pre-wrap"
  });
  document.body.appendChild(view);
  return view;
}

function report(error, key) {
  const message = error instanceof Error ? error.message : String(error);
  const identity = key ?? message;
  if (reportedError === identity) return;
  reportedError = identity;
  console.error("[rekindle]", error);
  statusView.hidden = true;
  errorView.textContent = message;
  errorView.hidden = false;
  window.dispatchEvent(new CustomEvent("rekindle:error", {detail: {message}}));
}

function clearError() {
  reportedError = undefined;
  errorView.hidden = true;
}

async function graphicsReady() {
  /* __REKINDLE_GRAPHICS_CHECK__ */
}

async function update() {
  if (loading || reloading) return;
  loading = true;
  let candidateGeneration;

  try {
    const response = await fetch(currentUrl, {cache: "no-store"});
    if (response.status === 409) {
      const failure = await response.json();
      report(new Error(failure.error), `build:${failure.error}`);
      return;
    }
    if (!response.ok) return;
    const current = await response.json();
    candidateGeneration = current.generation;

    if (activeGeneration && activeGeneration !== current.generation) {
      reloading = true;
      window.dispatchEvent(new CustomEvent("rekindle:before-reload", {
        detail: {from: activeGeneration, to: current.generation}
      }));
      window.location.reload();
      return;
    }

    if (!activeGeneration) {
      if (attemptedGeneration === current.generation) return;
      attemptedGeneration = current.generation;
      statusView.textContent = "Starting Rust UI\u2026";
      statusView.hidden = false;
      await graphicsReady();
      const module = await import(current.entry);
      if (typeof module.default !== "function") {
        throw new Error("The Web entry does not export a wasm-bindgen initializer.");
      }
      await module.default();
      activeGeneration = current.generation;
      window.dispatchEvent(new CustomEvent("rekindle:ready", {
        detail: {generation: activeGeneration}
      }));
    }
    statusView.hidden = true;
    clearError();
  } catch (error) {
    const key = candidateGeneration
      ? `startup:${candidateGeneration}:${String(error)}`
      : `runtime:${String(error)}`;
    report(error, key);
  } finally {
    loading = false;
  }
}

update();
window.setInterval(update, 250);
