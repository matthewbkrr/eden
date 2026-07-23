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

  // Tap routing is attached UNCONDITIONALLY and FIRST: on a cold start (app
  // launched by tapping the notification) the plugin replays the launch
  // notification to this listener, and it must exist before load completes.
  push.addListener("pushNotificationActionPerformed", (ev) => {
    const data = ev?.notification?.data || {};
    if (!data.conversation_id) return;
    const path = data.channel_id
      ? `/channels/${data.channel_id}/r/${data.conversation_id}`
      : `/app/c/${data.conversation_id}`;
    window.location.assign(path);
  });

  // Register only on an authed page — #notifier rides every authed
  // live_session (#272). Asking for notification permission on the login
  // screen would be noise; after login the full-page redirect re-runs this.
  if (!document.getElementById("notifier")) return;

  push.addListener("registration", ({ value }) => {
    const kind = cap.getPlatform() === "ios" ? "apns" : "fcm";
    const csrf = document
      .querySelector("meta[name='csrf-token']")
      ?.getAttribute("content");
    fetch("/devices", {
      method: "POST",
      headers: { "content-type": "application/json", "x-csrf-token": csrf },
      body: JSON.stringify({ kind, token: value }),
    }).catch(() => {});
  });

  // No Firebase config / no APNs entitlement yet → registration fails on that
  // platform; push is simply unavailable there, never an error surface.
  push.addListener("registrationError", () => {});

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
