// Autocomplete for `@` (#576).
//
// One popover for the page, like #reaction-grid (#72), driven by whichever composer has focus —
// the main one or the thread's. It does NOT decide who may be named: the list comes from the
// server, scoped to the open conversation, so the client never learns of anyone the sender
// cannot already see.
//
// The insertion is what makes the feature honest: a handle typed by hand can be misspelt and then
// names nobody (the server resolves against members and silently leaves it as text). Picking from
// the list guarantees the handle exists.
export default {
  mounted() {
    this.items = []
    this.active = 0
    this.input = null
    this.start = -1
    this.pending = null

    this.onInput = (e) => {
      const el = e.target
      if (!this.isComposer(el)) return
      this.input = el
      const q = this.query(el)
      if (q === null) return this.close()
      this.start = el.value.lastIndexOf("@", el.selectionStart - 1)
      // What this answer will be an answer TO. A reply that arrives after the caret moved on —
      // or after Escape — is stale, and inserting from it on Enter would name the wrong person
      // (#577 review).
      this.pending = q
      this.pushEvent("mention_search", { q })
    }

    // Keys are taken in the CAPTURE phase while the list is open: Enter must insert a mention,
    // not send the message, and the arrows must not move the caret.
    this.onKey = (e) => {
      if (this.el.hidden || !this.isComposer(e.target)) return
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        e.stopImmediatePropagation()
        const step = e.key === "ArrowDown" ? 1 : -1
        this.active = (this.active + step + this.items.length) % this.items.length
        this.paint()
      } else if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault()
        e.stopImmediatePropagation()
        this.insert(this.items[this.active])
      } else if (e.key === "Escape") {
        e.preventDefault()
        e.stopImmediatePropagation()
        this.close()
      }
    }

    this.onDoc = (e) => {
      if (!this.el.contains(e.target) && !this.isComposer(e.target)) this.close()
    }

    this.el.addEventListener("click", (e) => {
      const row = e.target.closest("[data-handle]")
      if (row) this.insert({ handle: row.dataset.handle })
    })

    document.addEventListener("input", this.onInput, true)
    document.addEventListener("keydown", this.onKey, true)
    document.addEventListener("click", this.onDoc, true)

    this.handleEvent("mention_candidates", ({ items }) => {
      // Still the question that was asked? `pending` is cleared by close(), so an answer landing
      // after Escape is dropped rather than reopening the list.
      if (this.pending === null || this.pending !== this.query(this.input)) return
      this.items = items || []
      this.active = 0
      this.items.length ? this.paint() : this.close()
    })
  },

  destroyed() {
    this.aria?.disconnect()
    document.removeEventListener("input", this.onInput, true)
    document.removeEventListener("keydown", this.onKey, true)
    document.removeEventListener("click", this.onDoc, true)
  },

  isComposer(el) {
    return el && (el.id === "composer-body" || el.id === "reply-body")
  },

  // The word being typed after an `@`, or null when the caret is not in one. The `@` has to start
  // a word — `me@host` is an address, the same rule the server parses bodies with.
  query(el) {
    if (!el) return null
    const upto = el.value.slice(0, el.selectionStart)
    // The same character class the server parses bodies with: a handle is `[a-zA-Z0-9_]`, so a
    // full stop ends it rather than joining it (#577 review).
    const m = /(?:^|[^\p{L}\p{N}_])@([a-zA-Z0-9_]*)$/u.exec(upto)
    return m ? m[1] : null
  },

  // A row is a face and two lines: who they are, then how to name them — the shape every
  // messenger uses for this list, so it needs no learning.
  //
  // Built as NODES, never as a markup string: BOTH text fields are user input. The display name
  // obviously so; the handle is constrained to `[a-z0-9_]` today, but a hole that depends on a
  // validation rule in another file opens the day that rule is relaxed (#577 review, P0).
  paint() {
    this.el.replaceChildren()
    this.items.forEach((it, i) => {
      const row = document.createElement("button")
      row.type = "button"
      row.id = `mention-opt-${i}`
      row.className = "ed-mention-pop__row" + (i === this.active ? " is-active" : "")
      row.setAttribute("role", "option")
      row.setAttribute("aria-selected", String(i === this.active))
      row.dataset.handle = it.handle

      const face = document.createElement("span")
      face.className = "ed-avatar ed-avatar--sm ed-mention-pop__face"
      if (it.everyone) {
        // Everyone is not a person, so the circle carries the handle's own mark instead of a
        // face. A glyph, not an icon: the sprite is built from what the .ex files reference, and
        // an icon named only here would silently not be in it.
        face.classList.add("ed-mention-pop__face--all")
        face.textContent = "@"
      } else if (it.avatar) {
        const img = document.createElement("img")
        img.src = it.avatar
        img.alt = ""
        face.append(img)
      } else {
        face.textContent = it.initial || ""
      }

      const text = document.createElement("span")
      text.className = "ed-mention-pop__text"
      const name = document.createElement("span")
      name.className = "ed-mention-pop__name"
      name.textContent = it.everyone ? this.el.dataset.labelAll || "Everyone" : it.name || it.handle
      const handle = document.createElement("span")
      handle.className = "ed-mention-pop__handle"
      handle.textContent = "@" + it.handle
      text.append(name, handle)

      row.append(face, text)
      this.el.append(row)
    })
    this.el.hidden = false
    // The list scrolls at 14rem, so steering past the fifth row would push the ring out of sight
    // — the one place where "where am I" stops being answerable at all.
    this.el.children[this.active]?.scrollIntoView({ block: "nearest" })
    this.describe()
    this.place()
  },

  // A screen reader follows the arrow keys through `aria-activedescendant`, while focus stays in
  // the composer where the typing is.
  //
  // Re-applied through an observer because the composer is patched on EVERY keystroke
  // (`composer_changed`) and morphdom removes any attribute the server did not render — so an
  // attribute set once here survives only until the next patch, which lands milliseconds later.
  describe() {
    if (!this.input) return
    const apply = () => {
      this.input.setAttribute("aria-activedescendant", `mention-opt-${this.active}`)
      this.input.setAttribute("aria-expanded", "true")
    }
    apply()
    this.aria?.disconnect()
    this.aria = new MutationObserver(() => {
      if (this.el.hidden) return
      if (!this.input.hasAttribute("aria-activedescendant")) apply()
    })
    this.aria.observe(this.input, { attributes: true, attributeFilter: ["aria-activedescendant"] })
  },

  place() {
    if (!this.input) return
    const gap = 8
    const r = this.input.getBoundingClientRect()
    const h = this.el.offsetHeight || 160
    const room = window.innerWidth - gap * 2
    // Wide enough to read a name and a handle, never wider than a comfortable list, never wider
    // than the screen. On a phone the composer INPUT is narrow (attach and emoji take their share)
    // — following it verbatim left a 210px column with names cut mid-word, so the list takes the
    // room it needs instead.
    const w = Math.round(Math.max(Math.min(room, 240), Math.min(r.width, 320, room)))
    const left = Math.round(Math.min(Math.max(gap, r.left), window.innerWidth - w - gap))
    // Above the composer: it sits at the bottom of the screen, and a list below it would be off
    // the viewport (and under the keyboard on a phone).
    this.el.style.left = `${left}px`
    this.el.style.top = `${Math.round(Math.max(gap, r.top - h - gap))}px`
    this.el.style.width = `${w}px`
  },

  insert(item) {
    if (!item || !this.input || this.start < 0) return this.close()
    const el = this.input
    const before = el.value.slice(0, this.start)
    const after = el.value.slice(el.selectionStart)
    const text = `@${item.handle} `
    el.value = before + text + after
    const caret = before.length + text.length
    el.setSelectionRange(caret, caret)
    // phx-change owns the body assign; without this the server would keep the pre-insert text and
    // overwrite the field on its next patch.
    el.dispatchEvent(new Event("input", { bubbles: true }))
    el.focus()
    this.close()
  },

  close() {
    this.aria?.disconnect()
    this.aria = null
    this.input?.removeAttribute("aria-activedescendant")
    this.input?.setAttribute("aria-expanded", "false")
    this.el.hidden = true
    this.items = []
    this.start = -1
    this.pending = null
  },
}
