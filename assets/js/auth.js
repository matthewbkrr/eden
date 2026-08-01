// The bundle for pages you reach while SIGNED OUT — login, invite acceptance, password reset and
// the 2FA challenge (#511).
//
// Those pages render a form. They were loading the entire chat client to do it: 79 KB gzip of
// lightbox, upload queue, instant navigation, message cache, emoji picker and 39 other hooks that
// have no host on the page. This entry carries the LiveView runtime, the two hooks such a page
// actually uses, and nothing else.
//
// Keep this file boring. Anything imported here lands on the first screen a person ever sees, so
// a new import needs a reason that survives being read out loud.
import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import topbar from "../vendor/topbar"
import { FlashAutoHide, PasswordReveal } from "./shared_hooks"
import { MsgCache } from "./msg_cache"

// Privacy, and the reason this file imports the cache at all (#272): a cached snapshot is a
// plaintext copy of someone's threads at rest. Being on a signed-out page means the previous
// session ENDED — however it ended: the logout link, "log out everywhere", expiry, an admin
// revoke. Wipe deterministically here rather than relying on a logout click racing the unload.
//
// This used to live in app.js behind "is the #notifier host absent". Now the bundle itself is the
// signal, and it is a stronger one: this file only ever loads on a signed-out page.
MsgCache.clearAll()
try {
  localStorage.removeItem("ed:cacheUser")
} catch (_e) {
  /* private mode */
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { FlashAutoHide, PasswordReveal },
})

window.addEventListener("phx:page-loading-start", (_info) => topbar.show(120))
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide())
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })

liveSocket.connect()
window.liveSocket = liveSocket
