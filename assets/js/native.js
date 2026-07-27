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
  wirePush();
  wireKeyboard();
  wireFileViewer();
}

// In-app document viewer (#464): WKWebView ignores the download attribute and
// NAVIGATES into the file — a PDF with no chrome and no way back (native gestures
// are off; the LiveView page and its JS die with the navigation). Intercept file-
// card taps and open the document in SFSafariViewController instead (Capacitor
// Browser): renders PDF/office formats, has a Done button and a system share.
// SafariVC has its OWN cookie store, so the URL must be a short-lived signed link
// minted over the WebView's session (GET /files/:id/link).
function wireFileViewer() {
  const browser = cap.Plugins?.Browser;
  if (!browser?.open) return;
  document.addEventListener(
    "click",
    (e) => {
      const a = e.target.closest && e.target.closest('a[download][href^="/files/"]');
      if (!a) return;
      const m = a.getAttribute("href").match(/^\/files\/(\d+)/);
      if (!m) return;
      e.preventDefault();
      e.stopPropagation();
      fetch(`/files/${m[1]}/link`, { headers: { accept: "application/json" } })
        .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
        .then(({ url }) => browser.open({ url: location.origin + url }))
        .catch(() => {});
    },
    true,
  );
}

// Keyboard lift v2 (#439): with Keyboard resize: 'none' the WebView frame never
// changes — the page pads itself above the overlay keyboard instead, and the CSS
// transition on that padding glides the composer up/down alongside the keyboard
// (the native frame resize was an instant jump). iOS only: Android's WebView
// still resizes natively (adjustResize), so the pad would double-compensate.
// The callback writes an idempotent style property, so a stacked registration
// after a reload is harmless (unlike wirePush's POSTs).
function wireKeyboard() {
  if (cap.getPlatform?.() !== "ios") return;
  const kb = cap.Plugins?.Keyboard;
  if (!kb?.addListener) return;
  const setKb = (h) =>
    document.documentElement.style.setProperty("--ed-kb", `${Math.max(0, Math.round(h))}px`);
  const fromEvent = (info) => setKb(info?.keyboardHeight || 0);
  // Will + Did on both edges (#439): a missed Will (interactive dismiss races,
  // resumed WebViews) must not leave the shell padded by a phantom keyboard.
  kb.addListener("keyboardWillShow", fromEvent);
  kb.addListener("keyboardDidShow", fromEvent);
  kb.addListener("keyboardWillHide", () => setKb(0));
  kb.addListener("keyboardDidHide", () => setKb(0));
  // Backgrounding drops the keyboard without always emitting Hide — reset on leave.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") setKb(0);
  });
}

// Android hardware/gesture back: navigate the WebView history like a browser
// back; on the root screen minimize the app (Android convention) instead of
// killing it. Registering a listener replaces Capacitor's default (exit).
// The backButton event never fires on iOS (no back button), and minimizeApp
// is Android-only — the catch keeps a hypothetical rejection silent rather
// than an unhandled-promise log (#423 review).
function wireBackButton() {
  const app = cap.Plugins?.App;
  if (!app?.addListener) return;
  app.addListener("backButton", ({ canGoBack }) => {
    if (canGoBack && window.history.length > 1) {
      window.history.back();
    } else {
      Promise.resolve(app.minimizeApp?.()).catch(() => {});
    }
  });
}

// Native push (#419, ADR-0001): ask, register, hand the device token to the
// backend, and route a notification tap into its chat. The backend half
// (#418: POST /devices + the APNs/FCM adapters) is already live; delivery
// itself turns on when the server gets its push env keys.
function wirePush() {
  const push = cap.Plugins?.PushNotifications;
  if (!push?.addListener) return;

  // Listeners live on the native plugin and SURVIVE WebView reloads, while
  // initNativeShell re-runs on every full page load (login→app, the deep-link
  // assign below, a cold start). Bind them ONCE per app process or they stack:
  // N navigations per tap, N token POSTs (#425 review). The window flag is the
  // per-process latch (same pattern as the overlay nav guard).
  if (!window.__edPushWired) {
    window.__edPushWired = true;

    // Cold start (app launched by tapping a notification): Capacitor retains
    // the launch action and replays it once this listener binds, so a tap that
    // beats the async bind is still delivered, not dropped.
    push.addListener("pushNotificationActionPerformed", (ev) => {
      const data = ev?.notification?.data || {};
      if (!data.conversation_id) return;
      const path = data.channel_id
        ? `/channels/${data.channel_id}/r/${data.conversation_id}`
        : `/app/c/${data.conversation_id}`;
      window.location.assign(path);
    });

    push.addListener("registration", ({ value }) => {
      const kind = cap.getPlatform() === "ios" ? "apns" : "fcm";
      const csrf = document
        .querySelector("meta[name='csrf-token']")
        ?.getAttribute("content");
      // Bail without the CSRF token rather than send the literal "undefined",
      // which the server would reject and silently drop the device (#425).
      if (!csrf) return;
      fetch("/devices", {
        method: "POST",
        headers: { "content-type": "application/json", "x-csrf-token": csrf },
        body: JSON.stringify({ kind, token: value }),
      }).catch(() => {});
    });

    // No Firebase config / no APNs entitlement yet → registration fails on that
    // platform; push is simply unavailable there, never an error surface.
    push.addListener("registrationError", () => {});
  }

  // register() only on an authed page (#notifier rides every authed
  // live_session, #272) — prompting on the login screen would be noise.
  // Idempotent, so re-running on a later authed load is harmless.
  if (!document.getElementById("notifier")) return;

  push
    .checkPermissions()
    .then((s) =>
      s.receive === "prompt" || s.receive === "prompt-with-rationale"
        ? push.requestPermissions()
        : s,
    )
    .then((s) => {
      if (s.receive === "granted") push.register();
    })
    .catch(() => {});
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
