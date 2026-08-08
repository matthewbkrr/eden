// FLIP reorder for the DM sidebar (#194): when a chat bumps to the top on new activity
// the server delete+re-inserts its row, so it's a fresh node at index 0. Instead of
// teleporting, animate the swap: beforeUpdate snapshots each row's First top by dom-id;
// updated measures Last and plays the inverse via the Web Animations API (compositor-only,
// interruption-safe). The bumped row is matched by its STABLE dom-id, so it rises from its
// old slot while the displaced rows ease down (the space opening above it). Rows that did
// not move animate nothing; reduced-motion skips the animation (instant reorder).
export default {
  rows() {
    return [...this.el.children].filter((c) => c.id && c.id.startsWith("conversations-"))
  },
  beforeUpdate() {
    // Each row's top RELATIVE to the list container, so a shift of the whole list (the
    // folder tabs above re-rendering) cancels out and only a real reorder registers.
    const base = this.el.getBoundingClientRect().top
    this.first = new Map()
    this.firstOrder = this.rows().map((r) => r.id).join(",")
    for (const row of this.rows()) this.first.set(row.id, row.getBoundingClientRect().top - base)
  },
  updated() {
    const first = this.first
    this.first = null
    if (!first || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    // Animate ONLY a pure reorder: same SET of chats, different order. An unchanged order
    // is a no-op (re-send into the chat already on top); a changed SET is a folder switch
    // / new chat / filter, where morphdom repositioning the shared rows must not look like
    // a bump (#194).
    const ids = this.rows().map((r) => r.id)
    if (ids.join(",") === this.firstOrder) return
    if (ids.slice().sort().join(",") !== [...first.keys()].sort().join(",")) return
    const base = this.el.getBoundingClientRect().top
    // Animate the LIVE node refs (not getElementById — a delete+insert can leave the old
    // node briefly resolvable). The bumped row is a fresh node at the top: its First is
    // its OLD slot, so it RISES; the row it passed is pushed DOWN — a clean cross.
    const moves = []
    for (const row of this.rows()) {
      const f = first.get(row.id)
      if (f == null) continue // a brand-new conversation: let it appear, no FLIP
      const delta = f - (row.getBoundingClientRect().top - base)
      if (Math.abs(delta) >= 1) moves.push([row, delta])
    }
    for (const [row, delta] of moves) {
      row.animate(
        [{ transform: `translateY(${delta}px)` }, { transform: "translateY(0)" }],
        { duration: 320, easing: "cubic-bezier(0.16, 1, 0.3, 1)" }
      )
    }
  },
}
