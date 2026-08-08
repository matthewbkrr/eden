// The app's own confirm and notice (#518).
//
// In a WKWebView `window.confirm` is a SYSTEM alert titled with the origin — the loudest tell that
// this is a web page rather than an app. The project already owns a branded dialog (the delete
// sheet in the multi-select flow), but it is server-rendered and bound to that one flow; these two
// are its client-side counterparts, for the nineteen places that reach for the system one:
// seventeen `data-confirm` attributes, LiveView's own confirm path, and a bare `alert` in
// native.js.
//
// Kept out of chat_live.ex on purpose (#510 is about getting 6.5k lines of JS OUT of that file),
// and out of the colocated hooks because this is app-wide: it has to work on /admin and /settings
// too, which mount none of the chat hooks.

const FOCUSABLE = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'

// One dialog at a time; a second request replaces the first rather than stacking scrims.
let open = null

function close(result) {
  if (!open) return
  const { el, resolve, restore } = open
  open = null
  el.remove()
  document.removeEventListener("keydown", onKey, true)
  // Focus goes back where it was, the way a native dialog leaves it.
  if (restore && restore.isConnected) restore.focus()
  resolve(result)
}

function onKey(e) {
  if (!open) return
  if (e.key === "Escape") {
    e.preventDefault()
    e.stopPropagation()
    close(false)
    return
  }
  if (e.key !== "Tab") return
  // A modal keeps the keyboard inside itself — the same trap the server-rendered sheet has.
  const items = [...open.el.querySelectorAll(FOCUSABLE)].filter((n) => n.offsetParent !== null)
  if (!items.length) return
  const first = items[0]
  const last = items[items.length - 1]
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault()
    last.focus()
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault()
    first.focus()
  }
}

/**
 * Ask, in the app's own clothes. Resolves true when confirmed, false on cancel/Escape/scrim.
 * `danger` paints the confirming button as destructive, which is what all seventeen call sites are.
 */
export function edConfirm(text, { confirmLabel, cancelLabel, danger = true } = {}) {
  return new Promise((resolve) => {
    close(false)
    const el = document.createElement("div")
    el.className = "ed-ask"
    el.innerHTML =
      '<div class="ed-ask__scrim" data-cancel></div>' +
      '<div class="ed-ask__card" role="dialog" aria-modal="true" tabindex="-1">' +
      '<p class="ed-ask__text"></p>' +
      '<div class="ed-ask__row">' +
      `<button type="button" class="ed-btn ed-btn--ghost" data-cancel></button>` +
      `<button type="button" class="ed-btn ${danger ? "ed-btn--danger" : "ed-btn--primary"}" data-ok></button>` +
      "</div></div>"
    // textContent, never innerHTML: these strings come from the server's gettext, but a confirm
    // message is exactly the kind of string that later grows an interpolated file name.
    el.querySelector(".ed-ask__text").textContent = text
    el.querySelector("[data-ok]").textContent = confirmLabel || document.documentElement.dataset.lblOk || "OK"
    el.querySelector("button[data-cancel]").textContent =
      cancelLabel || document.documentElement.dataset.lblCancel || "Cancel"

    el.addEventListener("click", (e) => {
      if (e.target.closest("[data-ok]")) close(true)
      else if (e.target.closest("[data-cancel]")) close(false)
    })

    const card = el.querySelector(".ed-ask__card")
    open = { el, resolve, restore: document.activeElement }
    document.body.appendChild(el)
    document.addEventListener("keydown", onKey, true)
    // The dialog itself, not its first button: opening on "OK" invites a stray Enter from the
    // keypress that opened it.
    card.focus()
  })
}

/** A one-way notice, in the app's own toast rather than a system alert. */
export function edNotice(text, ms = 4000) {
  const el = document.createElement("div")
  el.className = "ed-ask-toast"
  el.setAttribute("role", "status")
  el.innerHTML = '<div class="ed-toast ed-toast--error"><span class="ed-toast__bar"></span><span></span></div>'
  el.querySelector("span:last-child").textContent = text
  document.body.appendChild(el)
  setTimeout(() => el.remove(), ms)
}

/**
 * LiveView reads `data-confirm` itself and calls `window.confirm`. There is no option to swap that
 * out, so the click is taken in the capture phase before LiveView sees it, asked in our own
 * dialog, and — if confirmed — replayed with the attribute off for exactly that dispatch.
 */
export function installConfirm() {
  window.__edConfirm = edConfirm
  window.__edNotice = edNotice

  document.addEventListener(
    "click",
    (e) => {
      const el = e.target.closest?.("[data-confirm]")
      if (!el || el.dataset.edAsking === "replay") return
      const text = el.getAttribute("data-confirm")
      if (!text) return
      e.preventDefault()
      e.stopImmediatePropagation()
      edConfirm(text).then((ok) => {
        if (!ok) return
        // Replay: the attribute is put back straight after, so the next click asks again.
        el.dataset.edAsking = "replay"
        el.removeAttribute("data-confirm")
        el.click()
        el.setAttribute("data-confirm", text)
        delete el.dataset.edAsking
      })
    },
    true,
  )
}
