// Modal a11y: move focus into the dialog on open, keep Tab cycling within
// it, and restore focus to the trigger on close. For role=dialog panels.
export default {
  mounted() {
    this._prev = document.activeElement
    const f = this._focusables()
    ;(f[0] || this.el).focus()
    this._onKey = (e) => {
      if (e.key !== "Tab") return
      const els = this._focusables()
      if (!els.length) { e.preventDefault(); this.el.focus(); return }
      const first = els[0], last = els[els.length - 1], a = document.activeElement
      if (e.shiftKey && (a === first || a === this.el)) { e.preventDefault(); last.focus() }
      else if (!e.shiftKey && a === last) { e.preventDefault(); first.focus() }
    }
    this.el.addEventListener("keydown", this._onKey)
  },
  destroyed() {
    this.el.removeEventListener("keydown", this._onKey)
    if (this._prev && this._prev.focus) this._prev.focus()
  },
  _focusables() {
    return [...this.el.querySelectorAll(
      'a[href],button:not([disabled]),textarea:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])'
    )].filter((el) => el.offsetParent !== null)
  }
}
