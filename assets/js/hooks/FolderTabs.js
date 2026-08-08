// Slides the selected-tab oval under the active folder tab. The folder
// list persists across selection (phx-click, no navigation), so the
// indicator can transition between positions instead of teleporting.
export default {
  mounted() {
    this.indicator = this.el.querySelector("[data-indicator]")
    this.place(false)
    // Re-measure after fonts/layout settle and on container resize.
    this.ro = new ResizeObserver(() => this.place(false))
    this.ro.observe(this.el)
    // Instant response (#445 wave 3): flip the active tab + slide the oval AT
    // the click, not after the server re-renders the class an RTT later (the
    // tap read as dead). `pending` survives unrelated re-renders — see updated().
    this.el.addEventListener(
      "click",
      (e) => {
        const btn = e.target.closest && e.target.closest("button.ed-folder-tab")
        if (!btn) return
        this.pending = btn.getAttribute("phx-value-id") || ""
        this.pendingAt = Date.now()
        this.apply(this.pending)
      },
      true
    )
  },
  // Optimistically mark tab `id` active. Class-only — the server render is the
  // source of truth and rewrites these on every patch (that's why updated()
  // re-asserts while the ack is in flight).
  apply(id) {
    this.el.querySelectorAll("button.ed-folder-tab").forEach((b) => {
      const on = (b.getAttribute("phx-value-id") || "") === id
      b.classList.toggle("ed-folder-tab--active", on)
      b.setAttribute("aria-pressed", String(on))
    })
    this.place(true)
  },
  updated() {
    // A broadcast re-render mid-flight (presence diff, sidebar re-sort — anything)
    // rewrites/replaces the buttons with the OLD server truth and the optimistic
    // flip visibly snapped back (probe evidence: the tapped node was replaced
    // wholesale). Re-assert until the select_folder ack lands — the patch whose
    // server truth matches `pending` clears it. 10s cap: a dead event must not
    // pin a lie.
    if (this.pending != null) {
      // Ack detection (#448 review): LiveView keeps phx-click-loading on the
      // clicked button until ITS reply lands (and preserves it through unrelated
      // patches) — once it's gone, the server has answered and its truth stands
      // even when it differs (a rejected/no-op select_folder must not be
      // re-asserted for the 10s cap).
      const btn = Array.from(this.el.querySelectorAll("button.ed-folder-tab")).find(
        (b) => (b.getAttribute("phx-value-id") || "") === this.pending
      )
      const acked = !btn || !btn.classList.contains("phx-click-loading")
      const active = this.el.querySelector(".ed-folder-tab--active")
      const truth = active ? active.getAttribute("phx-value-id") || "" : null
      if (acked || truth === this.pending || Date.now() - this.pendingAt > 10000) {
        this.pending = null
      } else {
        this.apply(this.pending)
        return // apply() already placed the oval
      }
    }
    this.place(true)
  },
  destroyed() { this.ro && this.ro.disconnect() },
  place(animate) {
    const active = this.el.querySelector(".ed-folder-tab--active")
    if (!active || !this.indicator) return
    // Overlay the active tab's exact box. offset* are relative to the
    // shared offsetParent (.ed-folders), so this stays correct under
    // horizontal scroll (the indicator scrolls with the content).
    this.indicator.style.transition = animate ? "" : "none"
    this.indicator.style.width = `${active.offsetWidth}px`
    this.indicator.style.height = `${active.offsetHeight}px`
    this.indicator.style.transform =
      `translate(${active.offsetLeft}px, ${active.offsetTop}px)`
    this.indicator.style.opacity = "1"
    if (!animate) {
      // Flush so the first real selection animates from the right spot.
      void this.indicator.offsetWidth
      this.indicator.style.transition = ""
    }
  }
}
