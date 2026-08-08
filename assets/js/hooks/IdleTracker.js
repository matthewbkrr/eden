// Auto-away (#102): after IDLE_MS of no input this session reports idle;
// the next activity reports active. Only transitions are pushed (no spam),
// and the server only acts on it for "auto" users.
export default {
  mounted() {
    this.IDLE_MS = 10 * 60 * 1000
    this.idle = false
    // Match the server's mount default (tab_visible: true) so we only push on a real
    // change, not on every mount.
    this.active = true
    this.events = ["mousemove", "keydown", "wheel", "touchstart", "click", "scroll"]
    this.bump = () => {
      clearTimeout(this.timer)
      if (this.idle) { this.idle = false; this.pushEvent("presence_active", {}) }
      this.timer = setTimeout(() => {
        this.idle = true
        this.pushEvent("presence_idle", {})
      }, this.IDLE_MS)
    }
    // "Actively looking here" = the tab is visible AND the window has focus. document.hidden
    // alone misses an alt-tab to ANOTHER APP (the tab stays "visible"), which is exactly when
    // an OPEN chat should still ping you — otherwise it suppresses its own notification while
    // you're not even in the browser (#206 follow-up). Drives tab_visible/tab_hidden, which
    // gate notification suppression AND auto-read. Pushed only on a real change.
    this.syncActive = () => {
      const active = !document.hidden && document.hasFocus()
      if (active === this.active) return
      this.active = active
      this.pushEvent(active ? "tab_visible" : "tab_hidden", {})
      if (active) this.bump()
    }
    // Auto-away to OTHERS tracks the tab being HIDDEN (switched/minimized), not a mere window
    // blur: briefly alt-tabbing to another app shouldn't broadcast "away" — you're still here.
    this.onVisibility = () => {
      if (document.hidden) {
        clearTimeout(this.timer)
        if (!this.idle) { this.idle = true; this.pushEvent("presence_idle", {}) }
      }
      this.syncActive()
    }
    this.events.forEach((e) => window.addEventListener(e, this.bump, { passive: true }))
    document.addEventListener("visibilitychange", this.onVisibility)
    window.addEventListener("blur", this.syncActive)
    window.addEventListener("focus", this.syncActive)
    this.bump()
    this.syncActive()
  },
  destroyed() {
    clearTimeout(this.timer)
    this.events.forEach((e) => window.removeEventListener(e, this.bump))
    document.removeEventListener("visibilitychange", this.onVisibility)
    window.removeEventListener("blur", this.syncActive)
    window.removeEventListener("focus", this.syncActive)
  }
}
