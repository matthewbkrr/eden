export default {
  mounted() {
    this.el.addEventListener("click", () => {
      // The bar's stream container (#messages OR #thread-replies).
      const c = this.el.closest(".ed-selbar")?.dataset.container || "#messages"
      // Selected rows in chronological (document) order, both layouts.
      const rows = document.querySelectorAll(
        c + " .ed-flat--selected, " + c + " .ed-msg--selected",
      )
      const parts = []
      rows.forEach((r) => {
        const el = r.querySelector(".ed-flat__body, .ed-bubble__cap .break-words")
        const t = (el?.textContent || "").trim()
        if (t) parts.push(t)
      })
      const text = parts.join("\n\n")
      const done = () => this.pushEvent("selection_copied", {})
      if (!text) return done()
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(() => this.legacy(text, done))
      } else {
        this.legacy(text, done)
      }
    })
  },
  legacy(text, done) {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.style.position = "fixed"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.focus()
    ta.select()
    try { if (document.execCommand("copy")) done() } finally { ta.remove() }
  },
}
