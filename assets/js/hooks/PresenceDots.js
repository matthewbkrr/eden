// Live presence dots (#102, widened in #514). Rows in a `phx-update="stream"` container
// are never re-rendered by the server once they exist, so the dot inside them cannot be
// updated from the assign that changed. This host carries data-statuses (a {uid: status}
// map) which DOES re-render; on each update we re-apply, by user id, to every managed dot
// ([data-presence-uid]) anywhere on the page — the message list, the thread panel and the
// chat list. The initial server render already sets the right class, so there is no flash.
//
// The screen-reader label is updated too, from strings the server put on this host. That
// is what lets the sidebar's dots be managed at all: without it, making them live would
// have traded a stale label for no label (#514).
export default {
  mounted() { this.apply() },
  updated() { this.apply() },
  apply() {
    let map = {}
    try { map = JSON.parse(this.el.dataset.statuses || "{}") } catch (e) { return }
    const labels = {
      online: this.el.dataset.labelOnline || "",
      away: this.el.dataset.labelAway || "",
      dnd: this.el.dataset.labelDnd || "",
    }
    // Scoped to the three containers `dot_statuses/3` builds the map from — the chat
    // list, the room's message list and its thread panel. Absence from the map MEANS
    // offline, so a managed dot outside them would be hidden by a map that was never
    // about it (#546 review). Widen this and that function together, or not at all.
    document
      .querySelectorAll(
        "#conversations [data-presence-uid], #messages [data-presence-uid], " +
          "#thread-replies [data-presence-uid]",
      )
      .forEach((dot) => {
        const s = map[dot.dataset.presenceUid] || null
        dot.classList.toggle("ed-avatar__dot--hidden", !s)
        dot.classList.toggle("ed-avatar__dot--away", s === "away")
        dot.classList.toggle("ed-avatar__dot--dnd", s === "dnd")
        // The label sits INSIDE the dot, not beside it — the avatar renders it as the dot's
        // only child so the two can never drift apart in the markup.
        const label = dot.querySelector("[data-presence-label]")
        if (label) label.textContent = s ? labels[s] || "" : ""
      })
  }
}
