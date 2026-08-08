// Where an anchored card goes, in one place: the real profile card and the placeholder
// that stands in for it while the server answers (#521) have to agree, or the card would
// jump on handoff.
window.__edPlacePopover = (el) => {
  if (window.innerWidth < 768) return // CSS bottom sheet
  const w = el.offsetWidth, h = el.offsetHeight, gap = 8
  const a = window.__edAnchor
  let left, top
  if (a) {
    left = Math.max(gap, Math.min(a.left, window.innerWidth - w - gap))
    top = a.bottom + gap
    if (top + h > window.innerHeight - gap) top = Math.max(gap, a.top - h - gap)
  } else {
    // No recorded anchor (e.g. a trigger missing data-profile-trigger):
    // center it rather than leave the card invisible.
    left = Math.max(gap, (window.innerWidth - w) / 2)
    top = Math.max(gap, (window.innerHeight - h) / 2)
  }
  el.style.left = `${left}px`
  el.style.top = `${top}px`
  el.style.visibility = "visible"
}
// Positions the profile card at the clicked avatar/name (window.__edAnchor,
// recorded in app.js before the round-trip). Below-and-left-aligned to the
// trigger, clamped to the viewport, flipping above if it would overflow.
// On a narrow viewport the CSS makes it a bottom sheet — skip positioning.
export default {
  mounted() {
    this.place()
    // Move focus into the dialog (role=dialog/aria-modal) so a screen
    // reader announces it and Escape is reliable; focus returns to the
    // trigger naturally when the popover closes and the DOM restores.
    this.el.focus()
  },
  // A presence diff can morph the card while it's open; re-place so it
  // never ends up hidden (place() always restores visibility).
  updated() { this.place() },
  place() {
    window.__edPlacePopover(this.el)
  }
}
