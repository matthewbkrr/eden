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
  },
  plugins: {
    Keyboard: {
      // Shrink the WKWebView frame when the keyboard opens (#417): the page
      // re-lays out (h-screen tracks the shrunken viewport), so the chat header
      // stays put and the composer rides above the keyboard — instead of
      // WebKit panning the whole page up under the status bar.
      resize: 'native',
    },
  },
};

export default config;
