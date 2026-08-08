// The shared full-emoji grid popover (#72). One instance for the page; a
// message menu's "more" chevron fires `ed:open-reaction-grid` with the
// message id + anchor, we position over it and (on pick) push "react" for
// that message. Closes on outside-click / Esc / any scroll outside the
// grid (its own scroll is contained by CSS overscroll-behavior).
export default {
  mounted() {
    this.onOpen = (e) => this.open(e.detail.id, e.detail.x, e.detail.y, e.detail.mine)
    window.addEventListener("ed:open-reaction-grid", this.onOpen)
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-emoji]")
      if (!btn) return
      window.__edReact?.(this.msgId, btn.dataset.emoji)
      this.pushEvent("react", { id: this.msgId, emoji: btn.dataset.emoji })
      this.close()
    })
    // Close on any interaction outside the grid: a left-click, OR a
    // right-click (which opens a fresh context menu — the two popovers are
    // mutually exclusive), OR a scroll. Without the contextmenu case the
    // grid would linger under a newly-opened menu.
    this.onDoc = (e) => { if (!this.el.contains(e.target)) this.close() }
    this.onKey = (e) => { if (e.key === "Escape") this.close() }
    this.onScroll = (e) => { if (!this.el.contains(e.target)) this.close() }
  },
  // Destroyed while open (e.g. @selected -> nil on leave/remove, or a
  // server-driven navigate) must drop the document listeners too — else
  // they'd survive on a detached node. close() does exactly that.
  destroyed() {
    window.removeEventListener("ed:open-reaction-grid", this.onOpen)
    this.close()
  },
  open(id, x, y, mine) {
    // Re-entrant: tear down any listeners from a prior open FIRST. If the
    // grid was already open (a new menu opened over it, then its chevron
    // clicked), a surviving onDoc would fire on this very opening click and
    // slam the grid shut — and leave a stale listener that breaks every
    // future open. Clearing first guarantees the opening gesture is clean.
    this.teardown()
    this.msgId = id
    // Mirror the per-message highlight the in-menu grid used to show: mark
    // the viewer's existing reactions (space-joined in the chevron's
    // data-mine) so the full grid still tells you what you've already picked.
    const set = new Set((mine || "").split(" ").filter(Boolean))
    this.el.querySelectorAll("[data-emoji]").forEach((b) => {
      const on = set.has(b.dataset.emoji)
      b.classList.toggle("ed-menu__react--active", on)
      b.setAttribute("aria-pressed", String(on))
    })
    this.el.hidden = false
    const w = this.el.offsetWidth, h = this.el.offsetHeight
    this.el.style.left = Math.max(8, Math.min(x, window.innerWidth - w - 8)) + "px"
    this.el.style.top = Math.max(8, Math.min(y, window.innerHeight - h - 8)) + "px"
    // Move focus into the popover so keyboard users land on it (the menu
    // that opened it has closed, dropping focus to <body>).
    const first = this.el.querySelector("[data-emoji]")
    if (first) first.focus({ preventScroll: true })
    // Defer the outside-interaction listeners so the same gesture that
    // opened the grid doesn't immediately close it.
    setTimeout(() => {
      document.addEventListener("click", this.onDoc)
      document.addEventListener("contextmenu", this.onDoc)
    }, 0)
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("scroll", this.onScroll, { capture: true, passive: true })
  },
  close() {
    this.el.hidden = true
    this.teardown()
  },
  teardown() {
    document.removeEventListener("click", this.onDoc)
    document.removeEventListener("contextmenu", this.onDoc)
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("scroll", this.onScroll, { capture: true })
  }
}
