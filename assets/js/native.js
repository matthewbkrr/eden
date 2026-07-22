// Native-shell glue for the Capacitor apps (#417, epic #415).
//
// The same web bundle serves browsers and the iOS/Android WebView shells; in a
// browser `window.Capacitor` is absent and this module is a complete no-op. In
// the shells the Capacitor bridge is INJECTED into the page (the app loads the
// live server via server.url), so plugins are reached through the injected
// `window.Capacitor.Plugins.*` globals — never through npm imports, which would
// drag native-only packages into the browser bundle.
const cap = window.Capacitor;

export function initNativeShell() {
  if (!cap?.isNativePlatform?.()) return;

  // Style hook for native-only CSS (overscroll, etc.).
  document.documentElement.classList.add("ed-native");

  wireBackButton();
  wireStatusBar();
}

// Android hardware/gesture back: navigate the WebView history like a browser
// back; on the root screen minimize the app (Android convention) instead of
// killing it. Registering a listener replaces Capacitor's default (exit).
function wireBackButton() {
  const app = cap.Plugins?.App;
  if (!app?.addListener) return;
  app.addListener("backButton", ({ canGoBack }) => {
    if (canGoBack && window.history.length > 1) {
      window.history.back();
    } else {
      app.minimizeApp();
    }
  });
}

// Keep the OS status bar readable on both themes: our dark theme needs light
// glyphs (Style.Dark = dark BACKGROUND style), light theme dark glyphs. The
// theme lives on <html data-theme> (set by the root-layout IIFE; absent =
// follow the system), so watch both the attribute and the system preference.
function wireStatusBar() {
  const bar = cap.Plugins?.StatusBar;
  if (!bar?.setStyle) return;
  const media = window.matchMedia("(prefers-color-scheme: dark)");

  const apply = () => {
    const explicit = document.documentElement.getAttribute("data-theme");
    const dark = explicit ? explicit === "dark" : media.matches;
    bar.setStyle({ style: dark ? "DARK" : "LIGHT" }).catch(() => {});
  };

  apply();
  media.addEventListener("change", apply);
  new MutationObserver(apply).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });
}
