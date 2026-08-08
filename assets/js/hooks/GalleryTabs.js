// Profile media-gallery tabs (#136): slide a cobalt underline under the active tab
// (the panel persists across tab clicks, so it transitions rather than teleports) and
// wire ←/→ keyboard navigation per the APG tabs pattern (roving tabindex on the server).
export default {
  mounted() {
    this.indicator = this.el.querySelector("[data-gallery-indicator]")
    this.place(false)
    this.ro = new ResizeObserver(() => this.place(false))
    this.ro.observe(this.el)
    this.onKeyBound = (e) => this.onKey(e)
    this.el.addEventListener("keydown", this.onKeyBound)
  },
  updated() { this.place(true) },
  destroyed() {
    this.ro && this.ro.disconnect()
    this.el.removeEventListener("keydown", this.onKeyBound)
  },
  onKey(e) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return
    const tabs = [...this.el.querySelectorAll('[role="tab"]')]
    const i = tabs.findIndex((t) => t.getAttribute("aria-selected") === "true")
    if (i < 0) return
    e.preventDefault()
    const n = tabs.length
    const next = e.key === "ArrowRight" ? (i + 1) % n : (i - 1 + n) % n
    tabs[next].focus()
    tabs[next].click()
  },
  place(animate) {
    const active = this.el.querySelector(".ed-gallery-tab--on")
    if (!active || !this.indicator) return
    // offsetLeft is relative to the sticky tab bar (its offsetParent), so the
    // underline tracks the active tab even when the bar scrolls horizontally.
    this.indicator.style.transition = animate ? "" : "none"
    this.indicator.style.width = `${active.offsetWidth}px`
    this.indicator.style.transform = `translateX(${active.offsetLeft}px)`
    this.indicator.style.opacity = "1"
    if (!animate) {
      void this.indicator.offsetWidth
      this.indicator.style.transition = ""
    }
  }
}
