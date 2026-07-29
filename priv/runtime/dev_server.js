const currentUrl = new URL("./current", import.meta.url);
const consoleUrl = new URL("./console", import.meta.url);
const originalConsole = installConsoleForwarding();
const statusView = ensureStatusView();
const errorView = ensureErrorView();
let activeGeneration;
let attemptedGeneration;
let reportedError;
let loading = false;
let reloading = false;

function serializeConsoleValue(value) {
  if (value instanceof Error) {
    return value.stack || `${value.name}: ${value.message}`;
  }
  if (typeof value === "string") return value;

  try {
    const encoded = JSON.stringify(value);
    if (encoded !== undefined) return encoded;
  } catch (_error) {
    // Fall through to String for circular and otherwise non-JSON values.
  }

  try {
    return String(value);
  } catch (_error) {
    return "[unserializable]";
  }
}

function forwardConsole(level, source, args) {
  let body;
  try {
    body = JSON.stringify({
      level,
      source,
      args: args.map(serializeConsoleValue)
    });
  } catch (_error) {
    return;
  }

  if (typeof navigator.sendBeacon === "function") {
    try {
      if (navigator.sendBeacon(consoleUrl, body)) return;
    } catch (_error) {
      // Fall back to fetch.
    }
  }

  try {
    fetch(consoleUrl, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body,
      keepalive: true
    }).catch(() => {});
  } catch (_error) {
    // Browser logging must remain usable when transport setup fails.
  }
}

function installConsoleForwarding() {
  const originals = {};

  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const method = console[level];
    if (typeof method !== "function") continue;

    originals[level] = method.bind(console);
    console[level] = (...args) => {
      const result = originals[level](...args);
      forwardConsole(level, "console", args);
      return result;
    };
  }

  window.addEventListener("error", (event) => {
    forwardConsole("error", "error", [event.error || event.message]);
  });
  window.addEventListener("unhandledrejection", (event) => {
    forwardConsole("error", "unhandledrejection", [event.reason]);
  });

  return originals;
}

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

function report(error, key, {forward = true} = {}) {
  const message = error instanceof Error ? error.message : String(error);
  const identity = key ?? message;
  if (reportedError === identity) return;
  reportedError = identity;
  if (forward) {
    console.error("[rekindle]", error);
  } else if (originalConsole.error) {
    originalConsole.error("[rekindle]", error);
  }
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
      report(new Error(failure.error), `build:${failure.error}`, {forward: false});
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
