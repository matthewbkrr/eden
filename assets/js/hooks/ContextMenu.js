// Optimistic reactions (#521). A reaction is the most frequent gesture in the app and it
// was completely mute: the handler answers `{:noreply, socket}` and the chips come back
// over PubSub, so with the socket slowed to 400ms nothing on screen changed AT ALL before
// the reply — measured, and the reason the tap feels dropped on a cross-border link.
//
// The client already knows the answer: whose reaction it is and which way it goes. So it
// paints it, and the server's re-render — which arrives either way — is the correction.
//
// Registered once at bundle load, like the overlay nav guard: every path that reacts goes
// through here — the chip's own `phx-click`, the menu's quick row, the shared emoji grid
// and the double-tap.
window.__edReact =
  window.__edReact ||
  ((id, emoji) => {
    const row =
      document.getElementById(`messages-${id}`) ||
      document.querySelector(`[data-message-id="${id}"]`)?.closest(".ed-msg, .ed-flat")
    if (!row || !emoji) return
    const esc = window.CSS && CSS.escape ? CSS.escape(emoji) : emoji
    let box = row.querySelector(".ed-reactions")
    const chip = box && box.querySelector(`.ed-react[phx-value-emoji="${esc}"]`)

    if (chip) {
      const mine = chip.classList.toggle("ed-react--mine")
      chip.setAttribute("aria-pressed", String(mine))
      const c = chip.querySelector(".ed-react__count")
      const n = Math.max(0, (Number(c && c.textContent) || 0) + (mine ? 1 : -1))
      // ALWAYS write the count, including the zero. The text is what the next toggle reads,
      // and skipping the write on the way down made the way back up compute 1 + 1 = 2 —
      // found by the test for the un-hide below, not by reading the code.
      if (c) c.textContent = String(n)
      if (n > 0) {
        // Un-hide (#562 review): taking the last reaction off hides the chip, and putting
        // it back before the server answers found the chip again but left it hidden — the
        // restored reaction was invisible until the round trip landed.
        chip.hidden = false
        delete chip.dataset.gone
      } else {
        // Spent, but NOT hidden yet (#565): hiding here empties the block in the same
        // frame, and the track then has nothing to close over — the space would still
        // vanish in one step. `__edCollapse` takes it away at the end of the animation,
        // or at once if other chips remain.
        chip.dataset.gone = "1"
      }
      window.__edCollapse(box)
      return
    }

    // A first reaction has no chip and may have no container. Build one where the server
    // puts it — last child of the row's main column — and ONLY where that column is
    // known: a guess at the wrong place would be worse than the round trip it saves.
    if (!box) {
      // Where the SERVER puts it, in both layouts: last child of the flat row's main
      // column, and — in a bubble row — a SIBLING of the bubble, not a child of it.
      // Appending inside `.ed-bubble` put the chip in the blue bubble, left-aligned, for
      // the length of a round trip before the authoritative render moved it (user report).
      // The flat side was checked against the DOM when this was written; the bubble side
      // was guessed, which is exactly what the comment below warned against.
      const host =
        row.querySelector(".ed-flat__main") || row.querySelector(".ed-bubble")?.parentElement
      if (!host) return
      box = document.createElement("div")
      box.className = "ed-reactions"
      box.dataset.optimistic = "1"
      host.appendChild(box)
    }
    box.hidden = false
    let strip = box.querySelector(".ed-reactions__row")
    if (!strip) {
      strip = document.createElement("div")
      strip.className = "ed-reactions__row"
      box.appendChild(strip)
    }
    const b = document.createElement("button")
    b.type = "button"
    b.className = "ed-react ed-react--mine"
    b.setAttribute("phx-click", "react")
    b.setAttribute("phx-value-id", String(id))
    b.setAttribute("phx-value-emoji", emoji)
    b.setAttribute("aria-pressed", "true")
    b.dataset.optimistic = "1"
    const em = document.createElement("span")
    em.className = "ed-react__emoji"
    // NOT aria-hidden here, unlike the server's chip (#562 review): that one carries an
    // `aria-label` built from the reactor list, and gettext is out of reach in a hook. The
    // emoji itself is a language-neutral name, and it lasts only until the authoritative
    // render replaces this node — a nameless button would not.
    em.textContent = emoji
    const ct = document.createElement("span")
    ct.className = "ed-react__count"
    ct.setAttribute("aria-hidden", "true")
    ct.textContent = "1"
    b.append(em, ct)
    strip.appendChild(b)
    // A block caught mid-close is still wearing the closing class, and appending into it
    // would leave the new reaction inside a collapsed track (#565 review). `__edCollapse`
    // is the one place that decides open or shut, so let it decide again.
    window.__edCollapse(box)
  })

// A refusal comes back as an event, not as a diff: the row's markup is the same either
// way, so there is nothing for morphdom to undo.
//
// It carries the server's own count and ownership, and the client SETS that — it does not
// invert its guess (#562 review). Inverting assumes a refusal means the reaction is
// absent, which is false for an add-add race: there the reaction IS recorded and the loser
// of the race is the one being told no, so an inversion would show "not mine" over a row
// where it is mine, with no later diff to correct it.
if (!window.__edReactUndo) {
  window.__edReactUndo = true
  window.addEventListener("phx:react_rejected", (e) => {
    const d = e.detail || {}
    window.__edSetReact?.(d.id, d.emoji, d.count, d.mine)
  })
}

// Open or close the block that holds the chips, animating the space rather than snapping
// it (#565). Empty means closing: the node stays for the length of the transition, because
// an element that has left the DOM has nothing to animate.
//
// This is the path a PERSON drives — taking their own last reaction off. A reaction
// removed by SOMEONE ELSE arrives as a node removal from the server and still snaps;
// holding that node back would mean intercepting morphdom, which is a different job.
window.__edCollapse =
  window.__edCollapse ||
  ((box) => {
    if (!box) return
    const chips = [...box.querySelectorAll(".ed-react")]
    const spent = chips.filter((c) => c.dataset.gone)
    const live = chips.filter((c) => !c.dataset.gone && !c.hidden)
    // Re-checked at call time, not captured: a chip that was spent when the close began
    // can be back by the time this runs, and dropping it then would take a LIVE reaction
    // off the screen (#565 review).
    const drop = (c) =>
      c.dataset.gone && (c.dataset.optimistic ? c.remove() : (c.hidden = true))

    // Whatever the previous close scheduled, it is superseded — both the timer AND the
    // listener. Leaving the listener attached meant the REOPEN's own transition ended up
    // running the old close's cleanup, with an array of chips that had since come back.
    clearTimeout(box.__collapseT)
    if (box.__onEnd) box.removeEventListener("transitionend", box.__onEnd)
    box.__onEnd = null

    if (live.length || !spent.length) {
      // The block stays open, so a spent chip just goes — there is no space to animate.
      spent.forEach(drop)
      box.classList.remove("ed-reactions--closing")
      box.hidden = false
      return
    }

    // Everything is going: close the track WITH the chips still inside, then take them
    // away. The node has to outlive the click or there is nothing to animate.
    box.classList.add("ed-reactions--closing")

    const finish = () => {
      clearTimeout(box.__collapseT)
      if (box.__onEnd) box.removeEventListener("transitionend", box.__onEnd)
      box.__onEnd = null
      spent.forEach(drop)
      if (box.querySelectorAll(".ed-react:not([hidden])").length) {
        box.classList.remove("ed-reactions--closing")
        return
      }
      box.hidden = true
      if (box.dataset.optimistic) box.remove()
    }

    // Nothing animates under reduced motion, so no `transitionend` ever arrives and the
    // cleanup would wait out the backstop while the track is already shut (#565 review).
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return finish()

    // The transition itself says when it is over, so the duration lives in ONE place — the
    // stylesheet. The timer is only a backstop for the cases where no transition runs at
    // all: a hidden tab, an engine that declines it.
    box.__onEnd = (e) =>
      e.target === box && e.propertyName === "grid-template-rows" && finish()
    box.addEventListener("transitionend", box.__onEnd)
    box.__collapseT = setTimeout(finish, 600)
  })

// Put one (message, emoji) chip into an exact state. Used by the correction above; the
// optimistic paint below is the same operation with a guessed count.
window.__edSetReact =
  window.__edSetReact ||
  ((id, emoji, count, mine) => {
    const row =
      document.getElementById(`messages-${id}`) ||
      document.querySelector(`[data-message-id="${id}"]`)?.closest(".ed-msg, .ed-flat")
    if (!row || !emoji) return
    const esc = window.CSS && CSS.escape ? CSS.escape(emoji) : emoji
    const box = row.querySelector(".ed-reactions")
    const chip = box && box.querySelector(`.ed-react[phx-value-emoji="${esc}"]`)
    if (!chip) return
    const c = chip.querySelector(".ed-react__count")
    if (c) c.textContent = String(count)
    chip.classList.toggle("ed-react--mine", !!mine)
    chip.setAttribute("aria-pressed", String(!!mine))
    if (count > 0) {
      chip.hidden = false
      delete chip.dataset.gone
    } else {
      chip.dataset.gone = "1"
    }
    window.__edCollapse(box)
  })

// The chip's own tap is declarative (`phx-click="react"`), so it never passes through the
// hook's push sites — catch it in capture, before LiveView sends anything.
if (!window.__edReactChipGuard) {
  window.__edReactChipGuard = true
  document.addEventListener(
    "click",
    (e) => {
      const chip = e.target.closest && e.target.closest(".ed-react")
      if (!chip || !chip.getAttribute("phx-click")) return
      window.__edReact(chip.getAttribute("phx-value-id"), chip.getAttribute("phx-value-emoji"))
    },
    true
  )
}

// Telegram-style context menu, shared by message bubbles and sidebar chats:
// open it with a right-click (desktop) or a long-press (touch) anywhere on
// the host element — no visible trigger. The dropdown is position:fixed at
// the pointer, clamped to the viewport, so no scroll container can clip it.
// Copy items (when present) run client-side; the rest dispatch to the server.
//
// `active` (module-scoped) is the one menu currently open. Opening another
// closes it through close() so its document listeners are torn down — never
// by mutating `.hidden` directly (that would orphan the listeners). The host
// (this.el) and the menu node both carry stable ids, so their listeners
// survive a stream re-render; menu visibility/position is re-applied in
// updated(), which is why the markup needs no phx-update="ignore" and item
// labels stay free to change (e.g. a future Mute/Unmute toggle).
let active = null
export default {
  mounted() {
    this.onDoc = (e) => { if (!this.menu.contains(e.target)) this.close() }
    this.onKey = (e) => this.onKeydown(e)
    // Capture phase so a scroll in ANY ancestor container closes the menu —
    // but NOT the menu's own scrollable emoji grid (#67), which would slam
    // the menu shut the moment you tried to browse the full picker.
    this.onScroll = (e) => { if (!(this.menu && this.menu.contains(e.target))) this.close() }
    // Navigating closes the menu (#478). Nothing else did: close() is reachable only
    // from an outside click, Escape, a scroll or destroyed(), and the header-back path
    // stopPropagations its own tap in CAPTURE, so the outside-click listener never saw
    // it — the menu stayed open over the list for the whole ~450ms slide, until
    // backFinish's programmatic re-click finally bubbled. Worse on mobile, where the
    // pane is merely given class="hidden": the menu goes invisible while staying OPEN
    // (hidden=false, `active` still pointing here, isConnected still true) and returns
    // the moment that pane is shown again.
    this.onNav = () => this.close()
    // Same rule for a suspend (#493): an armed long-press must not survive the app
    // going away and pop a menu on resume with no finger on the screen, and an
    // already-open menu is a transient affordance anchored to a viewport that may
    // have changed while we were gone — close it, exactly as navigation does.
    this.onSuspend = () => {
      clearTimeout(this._lpTimer)
      this._lpTarget = null
      this.longPressed = false
      this.close()
    }
    this.onVisibility = () => {
      if (document.visibilityState !== "visible") this.onSuspend()
    }
    document.addEventListener("visibilitychange", this.onVisibility)
    window.addEventListener("ed:suspend", this.onSuspend)
    this.wire()

    // Desktop: right-click the host. A keyboard context-menu (Shift+F10 /
    // Menu key) reports clientX/Y 0 — fall back to the host's top-left.
    this.el.addEventListener("contextmenu", (e) => {
      e.preventDefault()
      const r = this.el.getBoundingClientRect()
      this.open(e.clientX || r.left + 8, e.clientY || r.top + 8)
    })

    // Double-click a message → react with the viewer's configured emoji (#106).
    // Only on real message rows: the same hook also hosts sidebar/channel context
    // menus, which carry no data-message-id — gating the whole setup here keeps
    // those hosts listener-free. Listen on the full message ROW (.ed-msg in DM
    // bubbles, the .ed-flat host in rooms/threads) so the hit area matches rooms,
    // not just the narrow bubble. Skips interactive descendants — buttons, inputs,
    // video, existing chips and real text links (a:not(.ed-photo)); PHOTOS are
    // reactable (<a class="ed-photo">): the .Lightbox hook defers its open ~250ms so
    // a double-click reacts instead. The emoji rides #composer's dataset (present
    // for DM, room AND thread rows).
    if (this.el.dataset.messageId) {
      // The double-click react zone is the BUBBLE, not the whole row (#383/R179) — a
      // dbl-click on the empty margin beside your own message no longer fires a reaction.
      // When the gesture is turned off, dbl_click_reaction returns nil → data-dbl-react is
      // empty → the `if (!emoji) return` below makes this a no-op.
      const dblRow = this.el.closest(".ed-bubble") || this.el
      const canReact = (t) =>
        !t.closest("button, input, textarea, video, .ed-reactions, a:not(.ed-photo)")
      // preventDefault on the SECOND mousedown stops the browser selecting the word
      // BEFORE it paints — clearing the selection after dblclick still flickered.
      dblRow.addEventListener("mousedown", (e) => {
        if (e.detail === 2 && canReact(e.target)) e.preventDefault()
      })
      dblRow.addEventListener("dblclick", (e) => {
        if (!canReact(e.target)) return
        const emoji = document.getElementById("composer")?.dataset.dblReact
        if (!emoji) return
        e.preventDefault()
        window.__edReact?.(this.el.dataset.messageId, emoji)
        this.pushEvent("react", { id: this.el.dataset.messageId, emoji })
      })
    }

    // Touch: long-press opens the menu; a horizontal LEFT-swipe on a
    // message row quote-replies (#71). A move cancels the long-press
    // (it's a scroll/swipe/select).
    let sx, sy, dx, swiping
    const SWIPE = 56 // px of leftward travel past which a swipe quote-replies
    const ENGAGE = 12 // px before a mouse drag counts as a swipe (vs a click)
    const CLAMP = 90 // px the row follows the gesture 1:1 before the elastic tail
    const SETTLE = 200 // ms of wheel silence before a trackpad swipe re-arms
    const WHEEL_START = 8 // px of horizontal intent before a wheel gesture even begins (#383/R184)
    const reset = () => {
      this.el.style.transition = "transform 0.18s var(--ed-ease)"
      this.el.style.transform = ""
      // Drop the compositor hint the gesture asked for (#515). It is set only while a
      // row is actually being dragged: declaring it statically would promote every one
      // of ~200 rendered rows to its own layer, which costs far more than it saves.
      this.el.style.willChange = ""
      swiping = false
    }
    // Rubber-band the row to the gesture: follow the finger 1:1 up to CLAMP (a
    // comfortable, Telegram-like drag distance), then a soft exponential elastic
    // tail past it so it never hits a hard wall. The reply trigger (SWIPE) sits
    // well inside the 1:1 region, so it stays precise. `delta` is <= 0 (left).
    const pull = (delta) => {
      if (delta >= -CLAMP) return delta
      const extra = -delta - CLAMP
      return -(CLAMP + 30 * (1 - Math.exp(-extra / 70)))
    }
    this.el.addEventListener("touchstart", (e) => {
      const t = e.touches[0]; sx = t.clientX; sy = t.clientY; dx = 0; swiping = false
      this.el.style.transition = "none"
      // Mark a recent touch so a touchscreen laptop's synthesized mouse events
      // don't ALSO run the desktop drag path → double reply (#110 review S2).
      this.recentTouch = true
      clearTimeout(this._touchGuard)
      this._touchGuard = setTimeout(() => { this.recentTouch = false }, 700)
      // A stale swallow flag must not eat the NEXT real tap (#479): longPressed is
      // otherwise cleared only by the click handler below, so a menu opened without a
      // following click on this row (navigated away, opened another chat) left it set
      // on a hook that survives every sidebar re-render.
      this.longPressed = false
      // Instance state, not a closure (#439 THE actual long-press leak): rapid
      // switching re-streams the sidebar, morphdom REPLACES the row mid-touch,
      // the hook dies — and with it the touchend cancel — while a closure timer
      // survived and opened the menu on the detached hook ~150ms after the nav
      // settled (which is why the __edNavBusy guard alone missed it). destroyed()
      // now owns the timer, and the callback refuses on a disconnected element.
      // A second finger's touchstart must not orphan the first timer (#462 review).
      //
      // Remember the TOUCH TARGET, not just the row (#479). The cancels below sit on
      // this.el and reach it only by bubbling from the leaf the finger actually landed
      // on; a touch target is fixed at touchstart and never re-targeted. If morphdom
      // discards that leaf mid-gesture — and the sidebar's <time> is discarded on
      // EVERY patch, see local_time — the event fires on a node whose propagation path
      // is just itself. It never reaches the row, and it would never reach `document`
      // either, so no amount of listener placement can save this: the timer has to
      // check at FIRE time. Both #462 guards still pass here (the row survives, so
      // destroyed() never runs and isConnected is true), which is why a ~320ms still
      // tap could open the menu.
      this._lpTarget = e.target
      clearTimeout(this._lpTimer)
      this._lpTimer = setTimeout(() => {
        if (window.__edNavBusy) return
        if (!this.el.isConnected) return
        // The finger's own node left the tree: its touchend can no longer be observed,
        // so this timer cannot be trusted to represent a still-held finger.
        if (this._lpTarget && !this._lpTarget.isConnected) return
        // …and the host must actually be on screen (same predicate as updated(), #478).
        if (this.el.getClientRects().length === 0) return
        this.open(sx, sy)
        this.longPressed = true
      }, 450)
    }, { passive: true })
    const cancel = () => { clearTimeout(this._lpTimer); this._lpTarget = null }
    this.el.addEventListener("touchmove", (e) => {
      const t = e.touches[0]
      dx = t.clientX - sx
      const dy = t.clientY - sy
      if (Math.abs(dx) > 10 || Math.abs(dy) > 10) cancel()
      // Drag a message row left with the finger (rubber-banded); reply on release.
      if (this.el.dataset.messageId && dx < -10 && Math.abs(dx) > Math.abs(dy)) {
        swiping = true
        // Promote for the duration of the drag only — see reset() (#515).
        this.el.style.willChange = "transform"
        this.el.style.transform = `translateX(${pull(dx)}px)`
      }
    }, { passive: true })
    // Passive: neither handler calls preventDefault, so saying so up front lets the
    // browser keep the gesture on the compositor instead of waiting to find out (#519).
    // Every rendered row carries these two listeners.
    this.el.addEventListener("touchend", () => {
      cancel()
      if (swiping && dx <= -SWIPE) this.fireReply()
      if (swiping) reset()
    }, { passive: true })
    // iOS hands the touch to a system gesture (edge swipe, notification pull):
    // touchend never comes — only touchcancel. Without this the armed timer
    // popped the menu seconds into an unrelated gesture (#439).
    this.el.addEventListener("touchcancel", () => {
      cancel()
      if (swiping) reset()
    }, { passive: true })
    // Desktop swipe-to-reply (#110) — DM/group BUBBLES only (rooms use flat
    // rows; the thread panel too, so they keep right-click → Reply). Two inputs:
    //   • Mouse: a CLEARLY horizontal left drag (past ENGAGE AND axis-dominant),
    //     so dragging to SELECT TEXT isn't hijacked (#110 review M1).
    //   • Trackpad: a PASSIVE wheel — keeps the list's vertical scroll on the
    //     compositor fast-path (review M3); the row follows the gesture and
    //     replies past SWIPE. overscroll-x-contain on the scroller stops the
    //     browser's back/forward nav, so we never need preventDefault here.
    // The document-level drag listeners + wheel timer are torn down in
    // destroyed() so an interrupted gesture can't leak a detached node (M2).
    if (this.el.classList.contains("ed-bubble")) {
      let msx = 0, msy = 0, mdx = 0, mDrag = false
      this._dragMove = (e) => {
        mdx = e.clientX - msx
        const mdy = e.clientY - msy
        // Engage only past ENGAGE AND when clearly horizontal; else a
        // vertical/diagonal text-selection drag would slide the row + reply.
        if (!mDrag && (mdx > -ENGAGE || Math.abs(mdx) <= Math.abs(mdy))) return
        mDrag = true
        this.el.style.transition = "none"
        this.el.style.willChange = "transform"
        this.el.style.transform = `translateX(${pull(mdx)}px)`
        e.preventDefault() // suppress text selection once it IS a swipe
      }
      this._dragUp = () => {
        document.removeEventListener("mousemove", this._dragMove)
        document.removeEventListener("mouseup", this._dragUp)
        if (mDrag && mdx <= -SWIPE) this.fireReply()
        // A real drag suppresses the click it would otherwise fire (opening a
        // photo). `dragged` is distinct from the touch long-press flag.
        if (mDrag) { reset(); this.dragged = true; setTimeout(() => { this.dragged = false }, 0) }
      }
      this.el.addEventListener("mousedown", (e) => {
        if (e.button !== 0 || this.recentTouch) return
        msx = e.clientX; msy = e.clientY; mdx = 0; mDrag = false
        clearTimeout(this._wheelTimer) // a just-ended wheel settle must not reset mid-drag
        clearTimeout(this._wheelSnap)
        document.addEventListener("mousemove", this._dragMove)
        document.addEventListener("mouseup", this._dragUp)
      })
      // A photo is a natively-draggable <img>: without this a left drag starts
      // the browser's image drag-and-drop and fights the reply swipe.
      this.el.addEventListener("dragstart", (e) => e.preventDefault())
      // Trackpad two-finger swipe. Vertical-dominant wheels fall through so
      // normal scroll is untouched; positive wx = leftward (tracks the OS scroll
      // direction). The row FOLLOWS the swipe rubber-banded, just like the mouse
      // drag — it must not snap back the instant it crosses SWIPE or a quick flick
      // only nudges ~20px. There's no "release" event (the OS keeps sending
      // decaying momentum wheels for ~1s after a flick), so on crossing SWIPE we
      // reply, let it follow a beat longer for feedback, then snap back and ignore
      // the rest of the momentum tail — a BOUNDED follow so the row can't sit
      // frozen until momentum dies. Idle silence (SETTLE) clears the state.
      let wx = 0
      this.el.addEventListener("wheel", (e) => {
        // A vertically-dominant tick is a scroll, not a swipe — RESET any partial pull so a
        // diagonal flick's momentum tail can't accumulate into a false reply (#383/R184).
        if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) {
          if (wx > 0) { wx = 0; reset() }
          return
        }
        // Horizontal scroll INSIDE a wide medium / link is the user scrolling that, not a
        // reply gesture on the bubble.
        if (e.target.closest?.("video, a, .ed-media, .ed-album, input, textarea")) return
        // Require real horizontal intent to START — a stray small deltaX doesn't begin one.
        if (wx === 0 && Math.abs(e.deltaX) < WHEEL_START) return
        clearTimeout(this._wheelTimer)
        this._wheelTimer = setTimeout(() => {
          wx = 0
          this._wheelFired = false
          this._wheelDone = false
          reset()
        }, SETTLE)
        if (this._wheelDone) return // replied + snapped; ignore the momentum tail
        wx = Math.max(0, wx + e.deltaX)
        this.el.style.transition = "none"
        this.el.style.willChange = "transform"
        this.el.style.transform = `translateX(${pull(-wx)}px)`
        if (!this._wheelFired && wx >= SWIPE) {
          this._wheelFired = true
          this.fireReply()
          this._wheelSnap = setTimeout(() => { this._wheelDone = true; reset() }, 180)
        }
      }, { passive: true })
    }
    // Swallow the click/navigation a long-press OR a desktop drag would
    // otherwise fire (a photo opening, or following a sidebar chat link).
    this.el.addEventListener("click", (e) => {
      if (this.longPressed || this.dragged) {
        e.preventDefault()
        e.stopPropagation()
        this.longPressed = false
        this.dragged = false
      }
    }, true)
  },
  // A stream re-render morphs the item; re-bind the (possibly new) menu node
  // and restore the open state the server render doesn't know about.
  updated() {
    this.wire()
    if (active === this) {
      // Belt (#478): a host that is not RENDERED must not own the active menu —
      // re-asserting hidden=false on one is precisely what armed a menu to reappear
      // together with the pane it lives in, which navigation merely gives
      // class="hidden" rather than removing.
      //
      // getClientRects(), not offsetParent (#488 review): offsetParent is also null
      // for position:fixed and for detached nodes, so it would close menus it has no
      // business closing. A box that generates no client rects is exactly "display:none
      // somewhere up the tree", and a visible fixed element still reports rects.
      if (this.el.getClientRects().length === 0) return this.close()
      this.menu.hidden = false
      this.position(this.x, this.y)
    }
  },
  destroyed() {
    this.close()
    // Tear down anything an in-flight desktop gesture left on `document` or
    // any pending timer, so an interrupted drag/swipe (the row destroyed by a
    // conversation switch, delete, or pagination mid-gesture) can't leak a
    // detached node via a live listener/closure (#110 review M2/M3).
    if (this._dragMove) document.removeEventListener("mousemove", this._dragMove)
    if (this._dragUp) document.removeEventListener("mouseup", this._dragUp)
    document.removeEventListener("visibilitychange", this.onVisibility)
    window.removeEventListener("ed:suspend", this.onSuspend)
    clearTimeout(this._touchGuard)
    clearTimeout(this._lpTimer)
    clearTimeout(this._wheelTimer)
    clearTimeout(this._wheelSnap)
  },
  // Bind the menu node + its delegated click handler. Idempotent: re-runs on
  // updated() and only attaches the listener to a freshly morphed-in node.
  wire() {
    // Message rows share ONE page-level menu (#508); every other host (sidebar chats,
    // the channel rail) still owns its menu inline, so both paths live here.
    this.menu = document.getElementById(this.sharedMenuId()) || this.el.querySelector("[data-menu]")
    if (this.menu && !this.menu._wired) {
      this.menu._wired = true
      // The shared node outlives every hook instance, so the handler resolves the CURRENT
      // owner (`active`, set in open()) rather than closing over whichever row happened
      // to wire it first — otherwise every click would carry the first-rendered message's
      // id. No `|| this` fallback: a click can only arrive while a menu is open, and an
      // open menu always has an owner. Two review rounds read that fallback as the bug
      // itself, which is reason enough for it not to exist.
      this.menu.addEventListener("click", (e) => active && active.onItem(e))
      // A long press opens the menu UNDER the finger, and lifting that same finger lands
      // a click on whatever item is now beneath it — the item fires without ever being
      // chosen (user report). Arm on a fresh press ON THE MENU instead of on a timer: the
      // press that opened it happened on the row, before this node was visible, so it can
      // never arm it.
      const arm = () => (this.menu.dataset.armed = "1")
      this.menu.addEventListener("pointerdown", arm, true)
      this.menu.addEventListener("touchstart", arm, { capture: true, passive: true })
      this.menu.addEventListener(
        "click",
        (e) => {
          if (this.menu.dataset.armed) return
          e.preventDefault()
          e.stopPropagation()
        },
        true
      )
    }
    // Optional visible trigger (the flat rows' hover "⋯") — anchors the
    // same menu under the button. Wired here so a stream morph that
    // replaces the node re-attaches the listener.
    const trigger = this.el.querySelector("[data-menu-trigger]")
    if (trigger && !trigger._wired) {
      trigger._wired = true
      trigger.addEventListener("click", (e) => {
        e.preventDefault(); e.stopPropagation()
        // Toggle: a second click on the trigger closes the open menu.
        // stopPropagation above keeps onDoc from firing, so without
        // this branch open() just re-opens (active === this) and the
        // menu never closes from the trigger.
        if (active === this && this.menu && !this.menu.hidden) {
          this.close()
          return
        }
        const r = trigger.getBoundingClientRect()
        this.open(r.left, r.bottom + 4)
      })
    }
  },
  // Which page-level menu this host uses, if any. Message rows, sidebar chats and room
  // rows each share one (#508); the folder tabs and the members panel are bounded by the
  // screen rather than by the account, so they still own their menu inline.
  sharedMenuId() {
    const d = this.el.dataset
    if (d.messageId) return "message-menu"
    if (d.room) return "room-menu"
    if (this.el.classList.contains("ed-convo-wrap")) return "convo-menu"
    return ""
  },
  // Point a shared sidebar menu at the row that just opened it. The items keep their
  // plain `phx-click` markup and only their `phx-value-id` is rewritten — that is what
  // keeps `data-confirm` working, which a hook-side pushEvent would have thrown away.
  fillSidebar() {
    const d = this.el.dataset
    this.menu.querySelectorAll("[phx-click]").forEach((b) => b.setAttribute("phx-value-id", d.id))

    const toggle = (need, on) =>
      this.menu.querySelectorAll(`[data-needs="${need}"]`).forEach((n) => { n.hidden = !on })
    toggle("muted", d.muted === "1")
    toggle("unmuted", d.muted !== "1")

    if (d.room) {
      toggle("fav", d.fav === "1")
      toggle("unfav", d.fav !== "1")
      toggle("deletable", d.deletable === "1")
      const copy = this.menu.querySelector("[data-copy-link]")
      if (copy) copy.dataset.link = d.link || ""
    } else {
      toggle("group", d.group === "1")
      toggle("direct", d.group !== "1")
    }
  },
  onItem(e) {
    // The reaction row's "more" chevron opens the shared full-emoji grid
    // popover (#72) for this message, then closes the menu.
    const expand = e.target.closest("[data-react-expand]")
    if (expand) {
      e.preventDefault()
      // Anchor the grid to the MENU's on-screen box, not the chevron —
      // the chevron is the rightmost item in the reacts row, so on a
      // right-aligned bubble its left edge clamps the grid to the far
      // screen edge. The menu's top-left puts the grid where the menu was.
      const mr = this.menu.getBoundingClientRect()
      window.dispatchEvent(new CustomEvent("ed:open-reaction-grid", {
        detail: {
          id: this.el.dataset.messageId,
          mine: expand.dataset.mine || "",
          x: mr.left,
          y: mr.top
        }
      }))
      this.close()
      return
    }
    // Shared-menu items (#508) carry data-act and no per-message state: the id comes
    // from the row that owns the menu right now. Inline menus (sidebar) keep their own
    // phx-click markup and fall through to the plain close below.
    const act = e.target.closest("[data-act]")
    if (act) return this.act(act)
    const ct = e.target.closest("[data-copy-text]")
    const cl = e.target.closest("[data-copy-link]")
    if (ct) this.copy(ct.dataset.text, "text")
    else if (cl) this.copy(cl.dataset.link, "link")
    // A reaction (phx-click="react") or forward/delete dispatches to the
    // server; either way the menu closes.
    if (e.target.closest("button")) this.close()
  },
  // Run one shared-menu item for the row that currently owns the menu.
  act(btn) {
    const d = this.el.dataset
    const id = d.messageId
    if (!id) return this.close()
    // The thread panel and the main stream share the menu, so "which surface" is read
    // from where the row lives rather than baked in at render time.
    const surface = this.el.closest(".ed-thread") ? "thread" : "main"
    switch (btn.dataset.act) {
      case "react":
        window.__edReact?.(id, btn.dataset.emoji)
        this.pushEvent("react", { id, emoji: btn.dataset.emoji })
        break
      case "reply":
        // Same path as the swipe gesture: pushes the row's own reply event and focuses
        // the matching composer, so a reply from a thread row stays in the thread.
        this.close()
        return this.fireReply()
      case "copy_text":
        return this.copy(d.text || "", "text")
      case "copy_link":
        // The row carries the path; the origin is the client's business.
        return this.copy(location.origin + (d.link || ""), "link")
      case "forward_prompt":
      case "enter_select":
        this.pushEvent(btn.dataset.act, { id, surface })
        break
      case "delete_for_both": {
        // `data-confirm` is a phx-click feature and these items push directly, so the
        // confirmation is asked here — with the server-rendered, localized text, and in
        // the app's own sheet rather than the system alert titled with the origin (#518).
        // The menu closes first: the question belongs over the chat, not over a menu on
        // its way out.
        const text = btn.dataset.confirmText
        this.close()
        if (!text) {
          this.pushEvent("delete_for_both", { id })
          return
        }
        window.__edConfirm(text).then((ok) => ok && this.pushEvent("delete_for_both", { id }))
        return
      }
      default:
        this.pushEvent(btn.dataset.act, { id })
    }
    this.close()
  },
  // Fire the quote-reply for this row — from a swipe or from the menu's Reply item.
  // In the thread panel the row carries reply_in_thread, so either gesture replies INTO
  // the thread, not the room; and the focus moves to that surface's composer. A real
  // method, not a closure stashed on the instance (#528 review read the old
  // `const fireReply = this._fireReply = …` as belonging to some other hook).
  fireReply() {
    if (!this.el.dataset.messageId) return
    // The swipe crossed its threshold — the same confirmation a native app gives (#518).
    window.__edTap?.()
    const event = this.el.dataset.replyEvent || "reply"
    this.pushEvent(event, { id: this.el.dataset.messageId })
    const sel = event === "reply_in_thread" ? "#reply-body" : "#composer-body"
    const input = document.querySelector(sel)
    input && input.focus()
  },
  // Point the shared menu at THIS row: which items apply, and which reactions the
  // viewer already left. The predicates are computed server-side onto the row
  // (data-can-*), so the rules that decide "can I edit this" stay in Elixir.
  fill() {
    const d = this.el.dataset
    const toggle = (need, on) =>
      this.menu.querySelectorAll(`[data-needs="${need}"]`).forEach((n) => { n.hidden = !on })
    toggle("thread", d.canThread === "1")
    toggle("edit", d.canEdit === "1")
    toggle("copy", d.canCopy === "1")
    toggle("own", d.own === "1")
    const mine = new Set((d.emojiMine || "").split(" ").filter(Boolean))
    this.menu.querySelectorAll('[data-act="react"]').forEach((b) => {
      const on = mine.has(b.dataset.emoji)
      b.classList.toggle("ed-menu__react--active", on)
      b.setAttribute("aria-pressed", String(on))
    })
    const more = this.menu.querySelector("[data-react-expand]")
    if (more) more.dataset.mine = d.emojiMine || ""
  },
  onKeydown(e) {
    if (e.key === "Escape") { this.close(); this.opener && this.opener.focus() }
    else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      const items = [...this.menu.querySelectorAll("[role=menuitem]:not([hidden])")]
      if (!items.length) return
      const i = items.indexOf(document.activeElement)
      const n = e.key === "ArrowDown" ? i + 1 : i - 1
      items[(n + items.length) % items.length].focus()
    }
  },
  open(x, y) {
    // Hosts without a menu node (e.g. the thread panel root) no-op.
    if (!this.menu) return
    if (active && active !== this) active.close()
    active = this
    this.x = x; this.y = y
    // Remember a focused trigger (keyboard open) to restore focus on Escape.
    this.opener = this.el.contains(document.activeElement) ? document.activeElement : null
    // Shared menu (#508): aim it at this row BEFORE it is shown, so no frame ever
    // paints another message's item set.
    if (this.el.dataset.messageId) this.fill()
    else if (this.sharedMenuId()) this.fillSidebar()
    // The press that opened it gets its tap back (#518): 450ms of holding with no signal
    // at all was the single most "web page" moment left on the phone. A no-op in a
    // browser, where the helper is not defined.
    window.__edTap?.("medium")
    // Disarmed until a press lands on the menu itself — see the capture listener in bind().
    delete this.menu.dataset.armed
    // A re-open inside the previous exit cancels it outright, or the menu would come back
    // mid-fade and finish invisible.
    clearTimeout(this.menu.__closeTimer)
    this.menu.classList.remove("ed-menu--closing")
    this.menu.removeAttribute("aria-hidden")
    this.menu.hidden = false
    const trigger = this.el.querySelector("[data-menu-trigger]")
    if (trigger) trigger.setAttribute("aria-expanded", "true")
    this.position(x, y)
    const first = this.menu.querySelector("[role=menuitem]:not([hidden])")
    first && first.focus()
    // Defer the outside-click listener so the same gesture doesn't close it.
    setTimeout(() => document.addEventListener("click", this.onDoc), 0)
    window.addEventListener("ed:nav", this.onNav)
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("scroll", this.onScroll, { capture: true, passive: true })
  },
  close() {
    if (active === this) active = null
    // Closing ends the gesture too (#479): otherwise a menu dismissed without a click
    // on this row leaves longPressed set, and the hook survives sidebar re-renders, so
    // the flag would swallow a genuine tap later — the row simply would not open.
    // DISARM as well (#489 review): a close arriving while a press is still counting —
    // an outside click, a scroll, or the ed:nav of #478 — otherwise left the timer to
    // fire anyway and re-open the menu 450ms later, right after it was dismissed.
    this.longPressed = false
    clearTimeout(this._lpTimer)
    this._lpTarget = null
    if (this.menu) {
      // Fade it out instead of cutting (#517): the box stays for exactly one
      // --ed-dur-quick, unclickable and `aria-hidden` from this instant, and only then
      // becomes `hidden`. Assistive tech and pointers are told at once; only the pixels
      // take the extra frames.
      const m = this.menu
      if (!m.hidden && !m.classList.contains("ed-menu--closing")) {
        // Focus leaves before the menu is marked hidden from assistive tech (#572 review):
        // activating an item with the keyboard leaves focus INSIDE the menu, and
        // `aria-hidden` over the focused element is exactly the state the attribute must
        // never be in. Back to whatever opened it, or the host row.
        if (m.contains(document.activeElement)) {
          // Back to whatever opened it — and if that was not a focusable thing (a menu
          // opened by right-click has no trigger to return to), simply out: calling
          // focus() on a plain <div> does nothing, and focus would have stayed put.
          if (this.opener && this.opener.isConnected) this.opener.focus()
          else document.activeElement.blur()
        }
        m.classList.add("ed-menu--closing")
        m.setAttribute("aria-hidden", "true")
        clearTimeout(m.__closeTimer)
        m.__closeTimer = setTimeout(() => {
          m.hidden = true
          m.classList.remove("ed-menu--closing")
          m.removeAttribute("aria-hidden")
        }, window.__edMs("--ed-dur-quick", 160))
      }
    }
    const trigger = this.el.querySelector("[data-menu-trigger]")
    if (trigger) trigger.setAttribute("aria-expanded", "false")
    // removeEventListener is a no-op if not attached — safe to call always.
    document.removeEventListener("click", this.onDoc)
    window.removeEventListener("ed:nav", this.onNav)
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("scroll", this.onScroll, { capture: true })
  },
  position(x, y) {
    const mw = this.menu.offsetWidth || 220
    const mh = this.menu.offsetHeight || 240
    const left = Math.max(8, Math.min(x, window.innerWidth - mw - 8))
    const top = Math.max(8, Math.min(y, window.innerHeight - mh - 8))
    this.menu.style.left = `${left}px`
    this.menu.style.top = `${top}px`
  },
  copy(text, what) {
    const done = () => this.pushEvent("copied", { what })
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done).catch(() => this.legacyCopy(text, done))
    } else {
      this.legacyCopy(text, done)
    }
    this.close()
  },
  // Fallback for non-secure contexts (HTTP, old WebViews) where the async
  // Clipboard API is unavailable.
  legacyCopy(text, done) {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.style.position = "fixed"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.focus()
    ta.select()
    try { if (document.execCommand("copy")) done() } finally { ta.remove() }
  }
}
