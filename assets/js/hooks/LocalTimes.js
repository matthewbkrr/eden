// ONE implementation of "rewrite this <time> in the viewer's zone", shared by the three
// places that need it: this hook, `.DateRail` (the main feed) and `.LocalTime` (a single
// label outside any feed). Registered at bundle load — every colocated module's top level
// runs when the index imports it, well before any `mounted()` — the same way the overlay
// nav guard above is (#560 review: it was triplicated).
//
// Writes through `firstChild.nodeValue` rather than `textContent` where it can: assigning
// `textContent` REPLACES the text node, which is a childList mutation inside the very
// subtree the observers watch, so every format pass re-fired them and bought a redundant
// rAF and a full re-scan. `nodeValue` mutates characterData, which nothing here observes.
window.__edFmtTime =
  window.__edFmtTime ||
  ((t) => {
    const d = new Date(t.getAttribute("datetime"))
    if (isNaN(d)) return
    const text = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
    if (t.firstChild && t.firstChild.nodeType === 3) t.firstChild.nodeValue = text
    else t.textContent = text
    t.dataset.lt = "1"
  })
window.__edFmtTimes =
  window.__edFmtTimes ||
  ((root) => {
    for (const t of root.querySelectorAll("time[datetime]:not([data-lt])")) {
      window.__edFmtTime(t)
    }
  })

export default {
  mounted() { this.fmt(); this.watch() },
  updated() { this.fmt() },
  destroyed() {
    this.mo && this.mo.disconnect()
    this._raf && cancelAnimationFrame(this._raf)
  },
  watch() {
    this.mo = new MutationObserver(() => {
      if (this._raf) return
      this._raf = requestAnimationFrame(() => { this._raf = null; this.fmt() })
    })
    this.mo.observe(this.el, { childList: true, subtree: true })
  },
  fmt() { window.__edFmtTimes(this.el) }
}
