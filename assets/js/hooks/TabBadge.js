// #216: reflect total unread in the browser tab as a "(N) " prefix on the title, so a
// backgrounded tab shows there's something waiting. The count rides data-count (recomputed
// server-side on every unread change). The title is kept in sync with live_title via a
// MutationObserver: live_title rewrites <title> on navigation, which would otherwise drop
// our prefix. NOTE (was a favicon dot too): dynamically rewriting the favicon <link> is
// unreliable across browsers — Firefox caches it, so the dot would stick after the count
// cleared and the brand mark wouldn't reliably show. The favicon now stays the static
// brand icon from the layout (never touched here); the title carries the count.
export default {
  mounted() {
    this.titleEl = document.querySelector("title")
    this.apply()
    this.obs = new MutationObserver(() => this.apply())
    if (this.titleEl) {
      this.obs.observe(this.titleEl, { childList: true, characterData: true, subtree: true })
    }
  },
  updated() { this.apply() },
  destroyed() {
    if (this.obs) this.obs.disconnect()
    this.apply(0)
  },
  count() { return parseInt(this.el.dataset.count || "0", 10) || 0 },
  apply(force) {
    const n = force === 0 ? 0 : this.count()
    // Strip any prefix we added so we re-read the base title live_title set.
    const base = document.title.replace(/^\(\d+\+?\)\s+/, "")
    const next = n > 0 ? "(" + (n > 99 ? "99+" : n) + ") " + base : base
    if (document.title !== next) document.title = next // re-fires the observer; the
    // guard above makes the second pass a no-op (base strips back to the same string).
  },
}
