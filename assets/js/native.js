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
  wireAppState();
  wireHaptics();
  hideSplash();
}

// The one signal the web can't fake (#518). In an iOS WKWebView `navigator.vibrate` does not
// exist at all, so a long press, a swipe-reply and an edge-swipe back all landed with no feedback
// whatsoever — 450ms of holding a message and nothing until the menu appears. Exposed as a global
// the way the rest of the client's shared helpers are (`__edReact`, `__edMs`), so a colocated hook
// can tap it without importing anything; a no-op off-device, which is why the call sites need no
// guard of their own.
function wireHaptics() {
  const haptics = cap.Plugins?.Haptics;
  if (!haptics) return;
  // ImpactStyle is a plugin enum; the strings are its values, so the plugin can be called without
  // importing the enum into a shell that has no bundler.
  window.__edTap = (style = "light") => {
    try {
      haptics.impact({ style: style === "medium" ? "MEDIUM" : "LIGHT" });
    } catch (_e) {
      // A missing plugin must never break the gesture it decorates.
    }
  };
}

// The cold start is otherwise a flat colour for the whole of DNS + TLS + GET + assets + connect
// (#518). The splash comes down when the app has actually painted — not on a timer, and not on
// DOMContentLoaded, which fires before LiveView has mounted anything.
function hideSplash() {
  const splash = cap.Plugins?.SplashScreen;
  if (!splash?.hide) return;
  const done = () => {
    try {
      splash.hide({ fadeOutDuration: 200 });
    } catch (_e) {}
  };
  // `.ed-root` is the app shell; on the login page it is the form's own container. Either way,
  // once it is on screen there is something to look at. The timeout is the backstop: a page that
  // never renders must not leave the splash up (`launchAutoHide` covers the process-level case).
  if (document.querySelector(".ed-root, .ed-auth")) return done();
  const mo = new MutationObserver(() => {
    if (document.querySelector(".ed-root, .ed-auth")) {
      mo.disconnect();
      done();
    }
  });
  mo.observe(document.documentElement, { childList: true, subtree: true });
  setTimeout(() => {
    mo.disconnect();
    done();
  }, 4000);
}

// Broadcast one "the app is going away" beacon (#493). The web layer already listens for
// visibilitychange, which a WKWebView does fire on background — but the native lifecycle is
// the authoritative signal (and the only one on a hard suspend), so mirror it. Consumers
// (the .InstantNav and .ContextMenu hooks) disarm in-flight gesture state on it: a 450ms
// long-press or back-slide timer that survives a suspend and flushes on resume otherwise
// pops a menu, or navigates, with no finger on the screen.
function wireAppState() {
  const app = cap.Plugins?.App;
  if (!app?.addListener) return;
  if (app.__edStateWired) return;
  // Flag first, rolled back on failure — see the note in wirePush (#500 + #501 reviews).
  app.__edStateWired = true;
  try {
    app.addListener("appStateChange", ({ isActive }) => {
      // Обе кромки (#507): suspend разоружает жесты (#493), resume форсирует переподключение.
      // Возврат из фона — это ровно тот случай, когда сокет остаётся ПОЛУОТКРЫТЫМ:
      // readyState всё ещё OPEN, поэтому ни phoenix.js, ни слушатель `online` этого не видят.
      window.dispatchEvent(new Event(isActive ? "ed:resume" : "ed:suspend"));
    });
  } catch (e) {
    app.__edStateWired = false;
    throw e;
  }
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
        // The default action IS the trap, so it stays prevented — but a failed mint
        // (network blip, expired session) must not read as a dead tap (#468 review).
        // The app's own toast, not a system alert titled with the origin (#518). RU-fixed like
        // the push copy (native.js has no gettext).
        .catch(() =>
          (window.__edNotice || alert)("Не удалось открыть файл. Проверьте соединение."),
        );
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
  //
  // Latched per app PROCESS (#493), and scoped to these four alone: they live on the native
  // Keyboard plugin and survive a document reload, while initNativeShell re-runs on every one
  // (with server.url, each LiveView redirect is a full load). The callback is an idempotent
  // style write, so stacking was wasteful rather than wrong, but the set grew without bound.
  // The flag is set AFTER registration (#500 review) so a throwing bridge cannot latch the
  // wiring out permanently — and it must NOT wrap the document listener below, which dies
  // with its document and has to be re-registered on every load.
  if (!kb.__edKbWired) {
    // Flag first, rolled back on failure — see the note in wirePush (#500 + #501 reviews).
    kb.__edKbWired = true;
    try {
      kb.addListener("keyboardWillShow", fromEvent);
      kb.addListener("keyboardDidShow", fromEvent);
      kb.addListener("keyboardWillHide", () => setKb(0));
      kb.addListener("keyboardDidHide", () => setKb(0));
    } catch (e) {
      kb.__edKbWired = false;
      throw e;
    }
  }
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
// Bound ONCE per app process (#481). initNativeShell re-runs on every full document
// load — and with server.url this app is a remote-origin WebView, so every LiveView
// redirect is one — while the listener lives on the native plugin and survives the
// reload. Without a latch they stack, and one press then traverses several entries.
// The team documented exactly this hazard for wirePush (#425 review) and applied a
// latch there; this one was missed. The flag rides the PLUGIN, not `window`: a full
// load replaces the global object, which is precisely the event we need to survive.
function wireBackButton() {
  const app = cap.Plugins?.App;
  if (!app?.addListener) return;
  if (app.__edBackWired) return;
  // Flag first, rolled back on failure — see the note in wirePush (#500 + #501 reviews).
  app.__edBackWired = true;
  try {
    app.addListener("backButton", ({ canGoBack }) => {
      if (canGoBack && window.history.length > 1) {
        window.history.back();
      } else {
        Promise.resolve(app.minimizeApp?.()).catch(() => {});
      }
    });
  } catch (e) {
    app.__edBackWired = false;
    throw e;
  }
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
  // N navigations per tap, N token POSTs (#425 review).
  //
  // The latch rides the PLUGIN, not `window` (#484). #425 called a window flag a
  // "per-process latch", but a full document load replaces the global object — and the
  // tap handler below performs one itself, via location.assign. So the very navigation
  // this latch protects was what reset it: the next load re-registered the listeners on
  // a plugin that had kept the old ones, and from then on every tap fired N handlers and
  // N location.assign calls, while Capacitor could replay a retained launch action into a
  // stale one and land the app in a chat whose notification was tapped much earlier. The
  // plugin object outlives the document, which is exactly the lifetime wanted here.
  //
  // Set AFTER registration (#500 review), so a bridge that throws cannot latch push out
  // for the rest of the process.
  if (!push.__edPushWired) {
    // Set BEFORE registering and rolled back on failure (#501 review). Either order alone is
    // wrong: flag-after lets a throw part-way through leave earlier listeners attached with
    // the flag still clear, so the next load re-adds them and stacks the very duplicates this
    // guards against; flag-before alone would latch push out for the process if the bridge
    // throws (#500 review). Together: no stacking, and a failed attempt can be retried.
    push.__edPushWired = true;
    try {
    // Cold start (app launched by tapping a notification): Capacitor retains
    // the launch action and replays it once this listener binds, so a tap that
    // beats the async bind is still delivered, not dropped.
    push.addListener("pushNotificationActionPerformed", (ev) => {
      const data = ev?.notification?.data || {};
      if (!data.conversation_id) return;
      const path = data.channel_id
        ? `/channels/${data.channel_id}/r/${data.conversation_id}`
        : `/app/c/${data.conversation_id}`;
      // Every authed route lives in one live_session, so with the socket up this is a patch
      // (~200ms) instead of a full document load (~1.5s, #518). `location.assign` stays as the
      // fallback: a cold start taps before the socket exists, which is exactly when a full load
      // is the only thing that works.
      const live = window.liveSocket;
      if (live && live.isConnected() && typeof live.historyRedirect === "function") {
        try {
          // `"push"` is not decoration: LiveView does `history[linkState + "State"](...)`, so a
          // null there is a TypeError thrown asynchronously inside the redirect — past this
          // try/catch, with the navigation already half-started (#574 review).
          live.historyRedirect({}, path, "push", null, null);
          return;
        } catch (_e) {
          // fall through to the full load
        }
      }
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
    } catch (e) {
      push.__edPushWired = false;
      throw e;
    }
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

  // The photo viewer is a near-black scrim in EITHER theme, and its chrome runs under the notch
  // (#518): on a light theme the status bar kept dark glyphs and became invisible on black. While
  // it is open the bar follows the viewer, not the theme; closing hands the theme its bar back.
  window.addEventListener("ed:lightbox", (e) => {
    if (e.detail?.open) bar.setStyle({ style: "DARK" }).catch(() => {});
    else apply();
  });
}
