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
    const m = /(?:^|[^\p{L}\p{N}_])@([a-zA-Z0-9_.-]*)$/u.exec(upto)
    return m ? m[1] : null
  },

  paint() {
    // Built as NODES, never as a markup string: BOTH fields here are user input. The display
    // name obviously so; the handle is constrained to `[a-z0-9_]` today, but a hole that depends
    // on a validation rule somewhere else is a hole that opens the day that rule is relaxed
    // (#577 review, P0). `setAttribute`/`textContent` cannot break out of anything.
    this.el.replaceChildren()
    this.items.forEach((it, i) => {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "ed-mention-pop__row" + (i === this.active ? " is-active" : "")
      row.setAttribute("role", "option")
      row.setAttribute("aria-selected", String(i === this.active))
      row.dataset.handle = it.handle
      const name = document.createElement("span")
      name.className = "ed-mention-pop__name"
      name.textContent = it.name || ""
      const handle = document.createElement("span")
      handle.className = "ed-mention-pop__handle"
      handle.textContent = "@" + it.handle
      row.append(name, handle)
      this.el.append(row)
    })
    this.el.hidden = false
    this.place()
  },

  place() {
    if (!this.input) return
    const r = this.input.getBoundingClientRect()
    const h = this.el.offsetHeight || 160
    this.el.style.left = `${Math.round(r.left)}px`
    // Above the composer: it sits at the bottom of the screen, and a list below it would be off
    // the viewport (and under the keyboard on a phone).
    this.el.style.top = `${Math.round(Math.max(8, r.top - h - 8))}px`
    this.el.style.width = `${Math.round(Math.min(r.width, 320))}px`
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
    this.el.hidden = true
    this.items = []
    this.start = -1
    this.pending = null
  },
}
