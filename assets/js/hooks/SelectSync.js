export default {
  mounted() {
    // The stream container this bar drives (#messages OR #thread-replies).
    this.c = this.el.dataset.container || "#messages"
    this.anchor = null
    // The overlays are BUILT here, not rendered by the server (#561). One button + check
    // + icon per row measured 2600 of a 671-row feed's 9441 nodes — 27% — for a mode
    // that is switched on rarely. They cannot simply be rendered on demand instead: the
    // rows live in phx-update="stream" and do not re-render on a plain @selection change
    // (the same reason sync() exists at all), so a server-side :if would leave every
    // already-streamed row without one. The hook that already owns selection state owns
    // their lifetime too, and it lives exactly as long as the mode does.
    this.ensure()
    // Every click inside a row belongs to selection while this hook lives. Not just
    // clicks on the overlay: a row re-streamed by an unrelated event (a reaction, a read
    // tick, a thumbnail swap) comes back from the server WITHOUT one until the observer
    // below re-adds it, and a tap landing in that frame must not reach the lightbox
    // underneath. Capture phase, so it pre-empts LiveView's own click handling.
    this.onClick = (e) => {
      const row = e.target.closest(this.rowSel())
      if (!row) return
      const id = this.rowId(row)
      if (!id) return
      e.preventDefault()
      e.stopImmediatePropagation()
      if (e.shiftKey && this.anchor && this.anchor !== id) {
        // Shift-click a row → select the whole range from the last-clicked row to this one.
        this.pushEvent("select_range", { ids: this.range(this.anchor, id) })
      } else {
        // Paint the tick NOW, before the server answers (#521). The selection lives on
        // the server, so until its diff arrived a tap produced nothing at all — and
        // selecting five messages meant five taps that each looked ignored.
        //
        // Guessing is safe here precisely because sync() is authoritative: it repaints
        // from `data-selected` on the very next patch, so a wrong guess (a rejected
        // toggle, a race) corrects itself within one round trip and never persists.
        this.paint(row, !this.selected(row))
        this.pushEvent("toggle_select", { id })
      }
      this.anchor = id
    }
    document.addEventListener("click", this.onClick, true)
    // A selected row can be re-streamed by an INDEPENDENT event (a reaction, a read tick,
    // a thumbnail swap, an edit): morphdom then rebuilds it from the server markup, which
    // carries neither the overlay nor the highlight. #selbar only re-renders on a
    // @selection/@confirming change, so its own updated() won't fire. Watch the stream
    // container (like .DateRail) and restore both; rAF-coalesced so a burst of patches is
    // one pass, and ensure() is idempotent so our own insertions settle immediately.
    const container = document.querySelector(this.c)
    if (container) {
      this.mo = new MutationObserver(() => {
        if (this._raf) return
        this._raf = requestAnimationFrame(() => {
          this._raf = null
          this.ensure()
          this.sync()
        })
      })
      this.mo.observe(container, { childList: true, subtree: true })
    }
    this.sync()
  },
  updated() {
    this.ensure()
    this.sync()
  },
  destroyed() {
    document.removeEventListener("click", this.onClick, true)
    this.mo && this.mo.disconnect()
    if (this._raf) cancelAnimationFrame(this._raf)
    this.clear()
    // Removed, not hidden: hiding them would keep every node this change exists to drop.
    this.strip()
  },
  rowSel() {
    return this.c + " .ed-msg, " + this.c + " .ed-flat"
  },
  rows() {
    return [...document.querySelectorAll(this.rowSel())]
  },
  // The message id, from the stream's dom id (`messages-12` / `thread-12`). Digits only:
  // an unexpected prefix must yield nothing rather than push a nonsense id at the server.
  rowId(row) {
    const m = /-(\d+)$/.exec(row.id || "")
    return m && m[1]
  },
  ensure() {
    for (const row of this.rows()) {
      if (row.querySelector(":scope > .ed-select-hit")) continue
      const id = this.rowId(row)
      if (id) row.prepend(this.buildHit(row, id))
    }
  },
  // The overlay, exactly as the server used to render it: a full-row click-catcher with
  // a leading checkbox. No phx-click — the capture handler above pushes the event, and
  // both would fire on the same tap.
  buildHit(row, id) {
    const d = this.el.dataset
    const b = document.createElement("button")
    b.type = "button"
    b.className = "ed-select-hit"
    b.dataset.selectId = id
    b.setAttribute("aria-pressed", "false")
    // The same element the selection bar's Copy reads, so a row's text has one definition.
    const text = (
      row.querySelector(".ed-flat__body, .ed-bubble__cap .break-words")?.textContent || ""
    ).trim()
    b.setAttribute(
      "aria-label",
      text
        // A function, not a string: in a replacement string `$&`, `$\`` and `$'` are
        // substitution patterns, and this text is a message body — in a workplace chat,
        // one that regularly holds shell and regex snippets (#570 review).
        ? (d.labelSelectPreview || "").replace("{}", () => text.slice(0, 40))
        : d.labelSelect || "",
    )
    b.innerHTML =
      '<span class="ed-select-check" aria-hidden="true">' +
      `<svg class="ed-icon size-3" aria-hidden="true" focusable="false"><use href="${d.checkIcon}"></use></svg>` +
      "</span>"
    return b
  },
  strip() {
    document.querySelectorAll(this.c + " .ed-select-hit").forEach((h) => h.remove())
  },
  range(a, b) {
    const ids = this.rows().map((r) => this.rowId(r))
    let i = ids.indexOf(a), j = ids.indexOf(b)
    if (i < 0 || j < 0) return [b]
    if (i > j) [i, j] = [j, i]
    return ids.slice(i, j + 1).filter(Boolean)
  },
  selected(row) {
    return row.classList.contains("ed-msg--selected") || row.classList.contains("ed-flat--selected")
  },
  // One row's highlight, from the row itself: the optimistic path and the authoritative
  // one must agree on the markup or the tick would flicker between them — and the row is
  // the only thing both can count on, since the overlay may be a frame behind a re-stream.
  paint(row, on) {
    row.classList.toggle(row.classList.contains("ed-flat") ? "ed-flat--selected" : "ed-msg--selected", on)
    const hit = row.querySelector(":scope > .ed-select-hit")
    if (hit) hit.setAttribute("aria-pressed", on ? "true" : "false")
  },
  sync() {
    let ids = []
    try { ids = JSON.parse(this.el.dataset.selected || "[]") } catch (_e) {}
    // Seed the shift-range anchor from the message that entered select mode.
    if (!this.anchor && ids.length) this.anchor = String(ids[ids.length - 1])
    const set = new Set(ids.map(String))
    for (const row of this.rows()) this.paint(row, set.has(String(this.rowId(row))))
  },
  clear() {
    for (const row of this.rows()) this.paint(row, false)
  },
}
