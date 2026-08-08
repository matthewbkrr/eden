// Profile gallery month dividers (#136): groups the photo/video grid by month in the
// viewer's LOCAL timezone from each tile's data-ts (UTC unix), like the message
// DateRail (#83) — so a busy gallery stays scannable. Re-derived on every patch
// (pagination append, live prepend, tab switch) since morphdom drops injected nodes.
export default {
  mounted() {
    this.locale = this.el.dataset.locale || undefined
    this.reconcile()
  },
  updated() { this.reconcile() },
  reconcile() {
    this.el.querySelectorAll(".ed-gallery-month").forEach((h) => h.remove())
    const thisYear = new Date().getFullYear()
    let last = null
    for (const tile of [...this.el.querySelectorAll("[data-ts]")]) {
      const d = new Date(Number(tile.dataset.ts) * 1000)
      const key = `${d.getFullYear()}-${d.getMonth()}`
      if (key === last) continue
      last = key
      const opts = d.getFullYear() === thisYear
        ? { month: "long" }
        : { month: "long", year: "numeric" }
      let label = d.toLocaleDateString(this.locale, opts)
      label = label.charAt(0).toUpperCase() + label.slice(1)
      const h = document.createElement("div")
      h.className = "ed-gallery-month"
      h.setAttribute("role", "heading")
      h.setAttribute("aria-level", "3")
      h.textContent = label
      this.el.insertBefore(h, tile)
    }
  }
}
