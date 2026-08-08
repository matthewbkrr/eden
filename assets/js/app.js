// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/eden"
// The app's own hooks, extracted from the LiveViews (#510).
import {edenHooks} from "./hooks"
// Not colocated (#511): the signed-out bundle needs these two, and the generated colocated index
// hands back all 42 hooks at once, so importing from it would have pulled the whole chat client
// onto the login page.
import {FlashAutoHide, PasswordReveal} from "./shared_hooks"
// The app's own confirm/notice, in place of the system ones (#518).
import {installConfirm} from "./dialogs"
import topbar from "../vendor/topbar"
// Durable send queue (TG-attachments, phase E): the colocated SendQueue hook reaches it via this
// global so an in-flight upload survives a page reload (persisted to IndexedDB, resumed on mount).
import {SendStore} from "./send_store"
window.__edenSendStore = SendStore
// Message-list cache (instant navigation, phase 2): the colocated InstantNav hook reaches it via
// this global to paint a re-opened chat from cache instantly + snapshot each shown thread.
import {MsgCache} from "./msg_cache"
window.__edMsgCache = MsgCache
// Privacy: cached snapshots are a plaintext copy of someone's threads at rest. Any SIGNED-OUT
// page (login, invite, reset — marked by the absence of the #notifier host that every authed
// page renders, #272) means the previous session ended — however it ended: the logout link,
// "log out everywhere", expiry, or an admin revoke. Wipe here, deterministically, instead of
// relying on a logout click racing the page unload. A logged-in tab elsewhere just reopens the
// (now empty) store on its next snapshot — the cache is an accelerator, losing it is harmless.
if (!document.getElementById("notifier")) {
  MsgCache.clearAll()
  try { localStorage.removeItem("ed:cacheUser") } catch (_e) { /* private mode */ }
}
// Capacitor shells only (#417) — a complete no-op in browsers.
import {initNativeShell} from "./native"
initNativeShell()
import {initInstantPages} from "./instant_pages"
initInstantPages()

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// #289: notification-chime presets, synthesized via Web Audio (no audio assets).
// Shared by the Notifier hook (plays the user's chosen preset on a new message)
// and the Settings preview button. `key` is validated server-side against the
// same closed set (Chat.notify_sound_names); unknown falls back to the default.
window.edSound = {
  // One enveloped note: soft attack + exponential decay so it's a chime, not a beep.
  _note(ctx, {freq, at = 0, dur = 0.3, type = "sine", peak = 0.11}) {
    const t = ctx.currentTime + at
    const g = ctx.createGain()
    g.connect(ctx.destination)
    g.gain.setValueAtTime(0.0001, t)
    g.gain.exponentialRampToValueAtTime(peak, t + 0.012)
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur)
    const o = ctx.createOscillator()
    o.type = type
    o.frequency.setValueAtTime(freq, t)
    o.connect(g)
    o.start(t)
    o.stop(t + dur + 0.02)
  },
  _presets: {
    chime: [{freq: 660, dur: 0.34}, {freq: 880, at: 0.09, dur: 0.28}],
    ping: [{freq: 1046, dur: 0.25, peak: 0.1}],
    pop: [{freq: 420, dur: 0.14, type: "triangle", peak: 0.13}],
    glass: [{freq: 880, dur: 0.18}, {freq: 1318, at: 0.06, dur: 0.18}, {freq: 1760, at: 0.12, dur: 0.22}],
    block: [
      {freq: 300, dur: 0.1, type: "triangle", peak: 0.16},
      {freq: 200, at: 0.05, dur: 0.12, type: "triangle", peak: 0.12},
    ],
  },
  play(ctx, key) {
    if (!ctx) return
    for (const n of this._presets[key] || this._presets.chime) this._note(ctx, n)
  },
}

// Capped backoff: retry fast at first, then settle at 5s. Keeps recovery quick
// on a flaky RU↔overseas link without hammering the server during a long outage.
const backoff = (tries) => [250, 500, 1000, 2000, 5000][tries - 1] || 5000

// Before the socket: the interceptor takes clicks in the capture phase, and a `data-confirm` tap
// landing during connect must not reach LiveView's system dialog either.
installConfirm()

const liveSocket = new LiveSocket("/live", Socket, {
  // Fall back to long-polling if the WebSocket can't establish quickly (the WS
  // upgrade is the fragile part across the border / restrictive networks).
  longPollFallbackMs: 2500,
  // Detect a dead socket sooner so reconnection starts faster.
  heartbeatIntervalMs: 15000,
  reconnectAfterMs: backoff,
  rejoinAfterMs: backoff,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...edenHooks, FlashAutoHide, PasswordReveal},
})

// Record where a profile trigger (avatar / name / member row) was clicked, so
// the server-rendered profile popover — which mounts a round-trip later — can
// anchor itself there. Capture phase, before the phx-click reaches LiveView.
window.__edAnchor = null
document.addEventListener(
  "click",
  (e) => {
    const trigger = e.target.closest && e.target.closest("[data-profile-trigger]")
    if (trigger) {
      const r = trigger.getBoundingClientRect()
      window.__edAnchor = {left: r.left, right: r.right, top: r.top, bottom: r.bottom}
    }
  },
  true
)

// Show progress bar on live navigation and form submits (cobalt --ed-primary, not the topbar default sky-blue)
const __edPrimary = getComputedStyle(document.documentElement).getPropertyValue("--ed-primary").trim() || "#3b6fd6"
topbar.config({barColors: {0: __edPrimary}, shadowColor: "rgba(0, 0, 0, .3)"})
// 120, not 300 (#512): at ~160 ms RTT most operations land in 160-250 ms, so at a 300 ms
// threshold the bar never appeared at all — the indicator was dead code on the commonest paths.
window.addEventListener("phx:page-loading-start", _info => topbar.show(120))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// Восстановление связи (#507). Два разных случая, и лечатся они по-разному — на что
// справедливо указало ревью PR #524: сначала я поставил обоим одну и ту же проверку
// `!isConnected()`, хотя сам же в комментарии описал, почему для второго она бесполезна.
//
// 1. Сеть вернулась, сокет ЗАКРЫТ (вышли из метро, сменили Wi-Fi↔LTE). `isConnected()`
//    честно отдаёт false, достаточно позвать connect. Без этого баннер разрыва висит до
//    heartbeat-таймаута: интервал 15 с плюс столько же на обнаружение, то есть до ~30 с
//    молча мёртвого приложения.
window.addEventListener("online", () => {
  if (!liveSocket.isConnected()) liveSocket.socket.connect()
})

// 2. Вернулись из фона, сокет ПОЛУОТКРЫТ. Это главный случай на iOS: WKWebView заморозили,
//    соединение умерло на стороне сети, но `readyState` всё ещё OPEN — значит `isConnected()`
//    отдаёт true, и ни проверка выше, ни собственный форс phoenix.js не срабатывают. Отличить
//    живой сокет от мёртвого дешёвой проверкой нельзя, поэтому здесь снос БЕЗУСЛОВНЫЙ:
//    `teardown` нужен именно чтобы полуоткрытое соединение не мешало новому коннекту.
//    Цена — один re-join после возврата из фона, где он всё равно ожидаем; на здоровый сокет
//    в обычной работе это не влияет, событие приходит только из нативной оболочки (native.js).
window.addEventListener("ed:resume", () => {
  liveSocket.socket.teardown(() => liveSocket.socket.connect())
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Sprite icon markup for the hooks that inject icons into the DOM themselves (#511/#539 review).
// These used to write a span carrying the icon name as a CSS class, which the Tailwind plugin painted with
// a mask-image; the plugin is gone, and such a span now renders as nothing at all. The sprite URL
// has to come from the server because prod digests it — it is on <html data-icons>.
window.edIcon = (name, cls = "") =>
  `<svg class="ed-icon ${cls}" aria-hidden="true" focusable="false">` +
  `<use href="${document.documentElement.dataset.icons}#${name}"></use></svg>`

// #207: absorb file drops anywhere in the window so a file dropped OUTSIDE a .DropZone (the
// sidebar, the rail, the gaps) doesn't make the browser navigate away and open the file. The
// drop zones handle + stopPropagation their own drops, so this only fires for stray drops.
const edIsFileDrag = (e) => e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files")
window.addEventListener("dragover", (e) => { if (edIsFileDrag(e)) e.preventDefault() })
window.addEventListener("drop", (e) => { if (edIsFileDrag(e)) e.preventDefault() })

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

