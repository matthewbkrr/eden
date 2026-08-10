// Keeps a shared menu's OPEN state across a server patch (#579).
//
// These menus are server markup (`hidden`, unpositioned) that .ContextMenu takes over on open:
// it clears `hidden` and writes an inline position. A LiveView patch walks the node and puts the
// server's version back — and it does so without close() ever running, so the menu blinks out
// while the hook still believes it is open: `active` still points at the row, the document
// listeners stay armed, focus never returns to the opener.
//
// Its siblings solve this with `phx-update="ignore"`, which is simpler and is what #mention-pop
// and #emoji-picker already do. #room-menu cannot: its admin items sit behind a SERVER gate on
// `@channel.role`, and the rail switches channels with `patch=` — so that block has to be able to
// arrive in a diff, and ignoring the subtree would freeze whichever variant rendered first (a
// channel owner reaching a channel from /app would silently lose Add members / Rename room /
// Delete room for the whole session). So this one stays patchable and re-asserts instead.
export default {
  beforeUpdate() {
    this.wasOpen = !this.el.hidden
    this.place = this.el.getAttribute("style")
  },
  updated() {
    if (!this.wasOpen) return
    // The patch also wiped what fillSidebar() wrote — every `phx-value-id`, the `data-needs`
    // visibility, the copy link. Re-arm through .ContextMenu rather than restoring those here:
    // that hook owns the row->menu wiring, and a second copy of it would drift. A false answer
    // means the menu has no live owner any more, so it stays down.
    if (!window.__edMenuRearm?.(this.el)) return
    this.el.hidden = false
    // The whole attribute, not left/top one at a time: position() is the only writer of this
    // element's inline style, so restoring what it wrote keeps the two in step.
    if (this.place) this.el.setAttribute("style", this.place)
  },
}
