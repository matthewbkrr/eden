// Copies data-url to the clipboard and briefly flips the label to
// data-copied. Falls back to a hidden textarea on non-secure contexts.
export default {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.url
      const done = () => {
        const old = this.el.textContent
        this.el.textContent = this.el.dataset.copied
        setTimeout(() => (this.el.textContent = old), 1500)
      }
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
  }
}
