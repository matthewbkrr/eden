// Failed-send (●!) for thread replies (#142 PR-2). Threads are flat and stream in
// via {:thread_reply}, so — like rooms — there's NO happy-path optimistic node and
// NO clock/✓/✓✓; only a "not delivered" ●! on failure. A focused, self-contained
// hook (colocated hooks can't share .SendQueue's helpers): mint a client_id, send
// over the socket, and on a nack / timeout / offline-grace materialize a faded
// failed row in #thread-pending with the same Resend/Delete(/Resend N) menu. The
// .ScrollBottom riser (data-pending-id="thread-pending") removes the failed node
// when its real reply streams in (e.g. an offline send that lands on reconnect).
export default {
  mounted() {
    this.threadRoot = this.el.dataset.threadRoot
    this.queue = []
    this.connected = true
    this.sendTimers = new Map()
    this.input = this.el.querySelector('input[name="reply[body]"]')
    // Edit (#164): the server pre-fills (start) / clears (cancel|save) the reply input
    // directly — a targeted event (NOT the main composer's set_composer_body) so the two
    // composers never cross-fill.
    this.handleEvent("set_thread_composer_body", ({ body }) => {
      if (!this.input) return
      this.input.value = body
      this.input.dispatchEvent(new Event("input", { bubbles: true }))
      if (body) {
        this.input.focus()
        try { this.input.setSelectionRange(body.length, body.length) } catch (_e) {}
      }
    })
    this.pending = document.getElementById("thread-pending")
    this.onOffline = () => { for (const i of this.queue) this.armWatchdog(i.clientId, i.body) }
    window.addEventListener("offline", this.onOffline)
    this.el.addEventListener("submit", (e) => this.onSubmit(e))
    // Capture picked File objects (phase F trim): the thread album/file send is fed one at a
    // time through the main composer's sequential feeder, which needs the real Files. Keyed
    // "name:size:lastModified" to match the tray items' data-key, so a per-item removal (the
    // ✕) and a multi-pick tray both resolve correctly at submit. Delegated + capture so it
    // survives the input's re-renders.
    // Mirror the main composer's stashes (#348): edenFiles feeds the sequential upload, and
    // edenVideoUrls backs the lightbox's crash-safe .ImgPreview/.VideoPreview object URLs — so
    // the SAME compose overlay renders here. Keyed name:size:lastModified (matches tileFileKey).
    this.el.edenFiles = new Map()
    this.el.edenVideoUrls = new Map()
    this.onPick = (e) => {
      const input = e.target
      if (!(input instanceof HTMLInputElement) || input.type !== "file") return
      for (const f of input.files || []) {
        const key = `${f.name}:${f.size}:${f.lastModified}`
        if (!this.el.edenFiles.has(key)) this.el.edenFiles.set(key, f)
        if (/^(video|image)\//.test(f.type || "") && !this.el.edenVideoUrls.has(key)) {
          this.el.edenVideoUrls.set(key, URL.createObjectURL(f))
        }
      }
    }
    // Both events, capture: file inputs fire `change`, but LiveView's own capture listener
    // consumes + clears the input during staging, so grab the Files on the `input` tick too
    // (mirrors the main composer's edenFiles capture).
    this.el.addEventListener("input", this.onPick, true)
    this.el.addEventListener("change", this.onPick, true)
  },
  disconnected() { this.connected = false },
  reconnected() {
    this.connected = true
    for (const i of this.queue) i.sent = false
    this.flush()
  },
  updated() {
    // A different thread opened in the same room (open_thread on another root):
    // the room id is unchanged, so key the reset on the thread ROOT — otherwise
    // thread A's ●! / in-flight nodes bleed into thread B's panel (#thread-pending is
    // phx-update="ignore", so the server never clears it).
    if (this.el.dataset.threadRoot !== this.threadRoot) {
      this.threadRoot = this.el.dataset.threadRoot
      this.queue = []
      this.el.edenFiles.clear()
      for (const url of this.el.edenVideoUrls.values()) URL.revokeObjectURL(url)
      this.el.edenVideoUrls.clear()
      this.sendTimers.forEach((t) => clearTimeout(t))
      this.sendTimers.clear()
      this.closeMenu()
      this.showForThread()
    }
  },
  // Don't WIPE #thread-pending on a thread switch (#380/R066): an attachment send to the
  // thread we're leaving is still uploading (fed by the main .SendQueue), and its optimistic
  // rings live here. Hide the other threads' nodes and show this thread's — every node is
  // tagged data-thread-root — so an in-flight send survives the switch and its progress
  // restores on return, instead of the pane being blanked. Real replies still remove their
  // node via the .ScrollBottom riser (data-pending-id="thread-pending") when they stream in.
  showForThread() {
    if (!this.pending) return
    for (const node of this.pending.children) {
      node.style.display = node.dataset.threadRoot === this.threadRoot ? "" : "none"
    }
  },
  destroyed() {
    window.removeEventListener("offline", this.onOffline)
    this.el.removeEventListener("input", this.onPick, true)
    this.el.removeEventListener("change", this.onPick, true)
    for (const url of this.el.edenVideoUrls.values()) URL.revokeObjectURL(url)
    this.el.edenVideoUrls.clear()
    this.sendTimers.forEach((t) => clearTimeout(t))
    this.sendTimers.clear()
    this.closeMenu()
  },
  onSubmit(e) {
    // A quote-reply / edit / forward bar (.ed-reply-bar) rides the server path (it needs the
    // reply_to_id / edit target / forward drop) — leave it. A staged album/file tray WITHOUT
    // a bar routes through the main composer's sequential feeder (phase F trim): one item at
    // a time (no batch stall), each landing as a thread reply progressively.
    if (this.el.querySelector(".ed-reply-bar")) return
    // Attachments open the SAME compose lightbox as the main composer (#348): hand the overlay
    // to the owner's shared send flow (threadComposeSend), targeting THIS thread. The overlay's
    // own caption + send button drive it; only take over when the feeder is up + the root valid.
    const overlay = this.el.querySelector("[data-upload-preview]")
    if (overlay) {
      const owner = window.__edSendQueue
      const root = Number(this.threadRoot)
      if (owner && Number.isInteger(root) && root > 0) {
        e.preventDefault()
        e.stopPropagation()
        owner.threadComposeSend(overlay, root, this.el.edenFiles)
      }
      // Overlay present → never the plain-text path (whether we took over or not).
      return
    }
    e.preventDefault()
    e.stopPropagation()
    const body = (this.input.value || "").trim()
    if (!body) return
    this.input.value = ""
    const clientId = this.uuid()
    this.queue.push({ clientId, body, sent: false })
    this.flush()
  },
  uuid() {
    if (crypto.randomUUID) return crypto.randomUUID()
    const b = crypto.getRandomValues(new Uint8Array(16))
    b[6] = (b[6] & 0x0f) | 0x40
    b[8] = (b[8] & 0x3f) | 0x80
    const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("")
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
  },
  flush() {
    for (const item of this.queue) {
      if (item.sent) continue
      this.armWatchdog(item.clientId, item.body)
      if (!this.connected) continue
      item.sent = true
      this.pushEvent("send_reply", { reply: { body: item.body, client_id: item.clientId } }, (reply) => {
        this.clearWatchdog(item.clientId)
        this.queue = this.queue.filter((q) => q.clientId !== item.clientId)
        if (reply && reply.nack) this.markFailed(item.clientId, item.body)
      })
    }
  },
  armWatchdog(clientId, body) {
    this.clearWatchdog(clientId)
    const ms = navigator.onLine ? 20000 : 3000
    const timer = setTimeout(() => {
      this.sendTimers.delete(clientId)
      if (this.queue.some((q) => q.clientId === clientId)) this.markFailed(clientId, body)
    }, ms)
    this.sendTimers.set(clientId, timer)
  },
  clearWatchdog(clientId) {
    const t = this.sendTimers.get(clientId)
    if (t) { clearTimeout(t); this.sendTimers.delete(clientId) }
  },
  markFailed(clientId, body) {
    if (!this.pending) return
    let node = this.pending.querySelector(`[data-client-id="${clientId}"]`)
    if (!node) {
      node = document.createElement("div")
      node.className = "ed-flat ed-msg-failed"
      node.dataset.clientId = clientId
      node.innerHTML =
        '<div class="ed-flat__gutter"></div>' +
        '<div class="ed-flat__main"><div class="break-words ed-flat__body"></div></div>'
      node.querySelector(".ed-flat__body").textContent = body
      this.pending.appendChild(node)
    }
    node.dataset.body = body
    // Tag with the owning thread root (#380/R066) so updated()'s hide/show keeps it in its
    // own thread and out of another's, mirroring the media nodes' data-thread-root.
    node.dataset.threadRoot = this.threadRoot
    node.querySelectorAll(".ed-msg-failed__bang").forEach((b) => b.remove())
    const bang = document.createElement("button")
    bang.type = "button"
    bang.className = "ed-msg-failed__bang"
    bang.setAttribute("aria-label", this.el.dataset.failed || "Not delivered")
    bang.innerHTML = window.edIcon("hero-exclamation-circle-micro", "size-3.5")
    bang.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.openMenu(node)
    })
    node.appendChild(bang)
  },
  failedNodes() {
    return [...this.pending.querySelectorAll(".ed-msg-failed")]
  },
  resendNode(node) {
    const clientId = node.dataset.clientId
    const body = node.dataset.body || ""
    node.remove()
    if (!body) return
    this.queue.push({ clientId, body, sent: false })
  },
  openMenu(node) {
    this.closeMenu()
    const d = this.el.dataset
    const failed = this.failedNodes()
    const menu = document.createElement("div")
    menu.className = "ed-menu ed-fail-menu"
    menu.setAttribute("role", "menu")
    const item = (label, onClick, danger) => {
      const b = document.createElement("button")
      b.type = "button"
      b.className = "ed-menu__item" + (danger ? " ed-menu__item--danger" : "")
      b.setAttribute("role", "menuitem")
      b.textContent = label
      b.addEventListener("click", () => { this.closeMenu(); onClick() })
      menu.appendChild(b)
    }
    item(d.resend || "Resend", () => { this.resendNode(node); this.flush() })
    if (failed.length > 1) {
      const label = (d.resendMany || "Resend {count} messages").replace("{count}", failed.length)
      item(label, () => { failed.forEach((n) => this.resendNode(n)); this.flush() })
    }
    item(d.delete || "Delete", () => node.remove(), true)
    document.body.appendChild(menu)
    const r = (node.querySelector(".ed-msg-failed__bang") || node).getBoundingClientRect()
    const mw = menu.offsetWidth, mh = menu.offsetHeight
    const left = Math.max(8, Math.min(r.right - mw, window.innerWidth - mw - 8))
    const fitsBelow = r.bottom + 4 + mh <= window.innerHeight - 8
    menu.style.left = left + "px"
    menu.style.top = (fitsBelow ? r.bottom + 4 : Math.max(8, r.top - mh - 4)) + "px"
    menu.style.transformOrigin = fitsBelow ? "top right" : "bottom right"
    this.failMenu = menu
    this.onMenuDoc = (e) => { if (!menu.contains(e.target)) this.closeMenu() }
    this.onMenuKey = (e) => { if (e.key === "Escape") this.closeMenu() }
    menu.querySelector("[role=menuitem]")?.focus({ preventScroll: true })
    setTimeout(() => {
      document.addEventListener("click", this.onMenuDoc)
      document.addEventListener("keydown", this.onMenuKey)
      document.addEventListener("scroll", this.onMenuDoc, { capture: true, passive: true })
    }, 0)
  },
  closeMenu() {
    if (!this.failMenu) return
    this.failMenu.remove()
    this.failMenu = null
    document.removeEventListener("click", this.onMenuDoc)
    document.removeEventListener("keydown", this.onMenuKey)
    document.removeEventListener("scroll", this.onMenuDoc, { capture: true })
  },
}
