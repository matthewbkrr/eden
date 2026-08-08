import type { CapacitorConfig } from '@capacitor/cli';

// The app does NOT bundle the frontend: the WebView loads the live LiveView server
// (epic #415). CAP_SERVER picks which one at `cap sync` time (see README.md):
//   prod (default) -> https://chat.ihi.ru
//   ios-dev        -> http://localhost:4001  (iOS Simulator reaches host loopback directly)
//   android-dev    -> http://10.0.2.2:4001   (Android Emulator's alias for host loopback)
// Cleartext is dev-only; prod stays strictly HTTPS.
const SERVERS: Record<string, { url: string; cleartext: boolean }> = {
  prod: { url: 'https://chat.ihi.ru', cleartext: false },
  'ios-dev': { url: 'http://localhost:4001', cleartext: true },
  'android-dev': { url: 'http://10.0.2.2:4001', cleartext: true },
};

const profile = process.env.CAP_SERVER ?? 'prod';
const server = SERVERS[profile];
if (!server) {
  throw new Error(
    `Unknown CAP_SERVER "${profile}" — expected one of: ${Object.keys(SERVERS).join(', ')}`,
  );
}

const config: CapacitorConfig = {
  appId: 'ru.ihi.chat',
  appName: 'ihichat',
  // Required by the CLI even though the WebView loads server.url; holds only the
  // offline fallback page.
  webDir: 'www',
  server: {
    url: server.url,
    cleartext: server.cleartext,
    // The page to show when the WebView cannot reach the server at all (#518). It has been
    // written since the shell was built (mobile/www/index.html) and was simply never wired: a
    // dropped network gave a blank WebView.
    errorPath: 'index.html',
  },
  // First-paint seam (#439): the WKWebView shows this color between the launch screen and
  // the page's own CSS — the default white read as a flash after the splash. --ed-bg (light).
  backgroundColor: '#fdfdfe',
  ios: {
    // The native scrollView never needs to scroll (h-screen layout) — but WebKit used it
    // to "reveal" the focused input, bouncing the whole page down/up on keyboard focus
    // (#439: "шапка съезжает и возвращается"). Off = no native pans, ever.
    scrollEnabled: false,
  },
  plugins: {
    Keyboard: {
      // Shrink the WKWebView frame when the keyboard opens (#417): the page
      // re-lays out (h-screen tracks the shrunken viewport), so the chat header
      // stays put and the composer rides above the keyboard — instead of
      // WebKit panning the whole page up under the status bar.
      // v2 (#439): 'none' — the WebView frame never changes; the page lifts the composer
      // itself via a CSS transition on the Capacitor keyboardWillShow/Hide events, matching
      // the keyboard's own glide (the instant frame resize read as a harsh jump).
      resize: 'none',
      // The strip behind the keyboard takes its colour from the DOM rather than the SYSTEM theme
      // (#518): the app's theme lives in `data-theme` and can differ from the OS one, which showed
      // as a light strip under a dark app. The plugin reads <body>'s background — which is why
      // app.css now sets it on body as well as .ed-root; without that it would read `transparent`
      // and fall back to black.
      autoBackdropColor: 'dom',
    },
    SplashScreen: {
      // The cold start is otherwise a plain background colour for the whole of DNS + TLS + GET +
      // assets + LiveView connect (#518). Hidden by the client as soon as the app has painted —
      // `launchAutoHide` stays true as the backstop, so a page that never loads cannot leave the
      // splash up for good.
      launchAutoHide: true,
      launchFadeOutDuration: 200,
      backgroundColor: '#fdfdfe',
      showSpinner: false,
    },
    PushNotifications: {
      // No OS banner while the app is FOREGROUND (#419): the in-app Web
      // adapter already chimes/banners there, so an OS banner would double up.
      // Server-side push-vs-active-session suppression (ADR-0001) is the full
      // fix later; this hides the symptom on the device meanwhile.
      presentationOptions: [],
    },
  },
};

export default config;
