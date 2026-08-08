// Composer emoji picker (#60): toggle a small grid; clicking a glyph
// inserts it at the caret in the message input. Closes on outside click
// or Esc. Dispatches "input" so phx-change keeps the body assign in sync.
export default {
  mounted() {
    this.toggle = this.el.querySelector("[data-emoji-toggle]")
    this.pop = this.el.querySelector("[data-emoji-pop]")
    this.onDoc = (e) => { if (!this.el.contains(e.target)) this.setOpen(false) }
    this.onKey = (e) => { if (e.key === "Escape") this.setOpen(false) }
    this.toggle.addEventListener("click", (e) => {
      e.preventDefault()
      this.setOpen(this.pop.hidden)
    })
    this.pop.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-emoji]")
      if (!btn) return
      e.preventDefault()
      // Stay open so several emoji can be picked in a row (#90); the
      // picker still closes on outside-click, Esc, or the toggle.
      this.insert(btn.dataset.emoji)
    })
  },
  destroyed() {
    document.removeEventListener("click", this.onDoc)
    document.removeEventListener("keydown", this.onKey)
  },
  setOpen(open) {
    this.pop.hidden = !open
    this.toggle.setAttribute("aria-expanded", String(open))
    const fn = open ? "addEventListener" : "removeEventListener"
    document[fn]("click", this.onDoc)
    document[fn]("keydown", this.onKey)
  },
  insert(emoji) {
    // Re-query each time: phx-update="ignore" is on the picker, not the
    // input, so the input can be re-rendered and a ref cached at mount
    // could go stale (#82 review).
    const i = this.el.closest("form")?.querySelector('input[name="message[body]"]')
    if (!i) return
    const s = i.selectionStart ?? i.value.length
    const e = i.selectionEnd ?? i.value.length
    i.value = i.value.slice(0, s) + emoji + i.value.slice(e)
    const pos = s + emoji.length
    i.setSelectionRange(pos, pos)
    i.dispatchEvent(new Event("input", { bubbles: true }))
    i.focus()
  },
}
