// Theme is client-driven (data-theme on <html>), so aria-pressed on the
// theme segments can't be server-rendered — sync it here and on change.
export default {
  mounted() {
    this._sync = () => {
      const cur = document.documentElement.getAttribute("data-theme") || "system"
      this.el.querySelectorAll("[data-phx-theme]").forEach((b) =>
        b.setAttribute("aria-pressed", String(b.dataset.phxTheme === cur)))
    }
    this._sync()
    this._obs = new MutationObserver(this._sync)
    this._obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
  },
  destroyed() { this._obs && this._obs.disconnect() }
}
