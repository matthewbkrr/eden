// Is ANY modal <dialog> open — i.e. does something own input right now? `showModal()`
// makes a dialog modal, a plain `show()` does not, yet both set [open] (#531 review).
//
// Asks about the whole document, not the first match: `querySelector("dialog[open]")`
// returns whichever open dialog comes first in DOM order, so a non-modal popover sitting
// above the lightbox would answer for it and the guard would wave the gesture through
// under a real modal (#531 review, second round).
//
// On an engine that does not know `:modal` the selector throws; then fall back to "any
// open dialog at all", which errs toward skipping the gesture — harmless, where
// navigating out from under a modal is not.
const modalOpen = () => {
  try {
    return !!document.querySelector("dialog:modal")
  } catch (_e) {
    return !!document.querySelector("dialog[open]")
  }
}

export default {
  mounted() {
    this.target = null   // conversation id we're transitioning to (string), or null
    this.overlay = null
    this.timer = null
    this.userId = this.el.dataset.userId // scopes the cache so accounts never cross
    this.cache = window.__edMsgCache
    if (this.cache && this.userId) {
      // A DIFFERENT account now uses this browser → wipe the previous user's at-rest
      // snapshots. Belt-and-suspenders: the PRIMARY eviction is app.js wiping on any
      // signed-out page render; this catches a user switch that somehow skipped one.
      try {
        const last = localStorage.getItem("ed:cacheUser")
        if (last && last !== this.userId) this.cache.clearAll()
        localStorage.setItem("ed:cacheUser", this.userId)
      } catch (_e) {
        /* private mode: no localStorage — the memory cache dies with the tab anyway */
      }
    }
    // Capture phase so we paint BEFORE LiveView's click handling kicks off the patch.
    this.onClick = (e) => {
      // A tap that opens a panel gets its placeholder in the same gesture (#521).
      const opener = e.target.closest?.("[data-opens]")
      if (opener) {
        const kind = opener.dataset.opens
        // The profile ASIDE is the same column the thread panel uses, so it stands in with
        // the same skeleton rather than a second one shaped like it.
        if (kind === "aside") this.threadSkel(".ed-profile")
        else this.panelSkel(kind)
      }
      this.maybeStart(e)
    }
    document.addEventListener("click", this.onClick, true)
    // A pick is not a click — it lands on the upload input, and only the main `attachment`
    // channel opens the staging overlay (the resend and sequential channels are internal).
    //
    // `input`, NOT `change`: LiveView's uploader takes the files on the `input` event and
    // empties the element, so a `change` listener — even in the capture phase — is handed
    // `files.length === 0` and has nothing to paint. Measured, not assumed: the same probe
    // reads `input:attachment:1` then `change:attachment:0`.
    this.onPick = (e) => {
      const input = e.target
      if (input && input.type === "file" && input.name === "attachment") {
        this.pickPreview(input)
      }
    }
    document.addEventListener("input", this.onPick, true)
    // .ScrollBottom fires this once the real stream for a conversation is in the DOM:
    // snapshot it into the cache (so the NEXT open paints instantly), then, if this is the
    // conversation we're transitioning to, drop the overlay.
    this.onShown = (e) => {
      // Idempotent, and deliberately in BOTH places: the tap path calls it a round-trip
      // earlier so the list never flickers, and this one catches every other way a chat
      // opens — search result, permalink, notification, history.
      //
      // Gated on the URL for the same reason the dismiss below is (#482): a tap burst
      // A -> B -> A makes the server render every live_patch, so `ed:conv-shown` fires
      // for arrivals that have already been superseded. Washing on each would leave the
      // wash wherever the last one happened to land. The URL is the discriminator — a
      // superseded diff always arrives while it points elsewhere. NOT gated on
      // `this.target`: that is null when the chat was opened from a search result or a
      // permalink, which is exactly the case this call exists for (#544 review).
      if (String(this.urlConvId()) === String(e.detail.id)) this.markActive(e.detail.id)
      this.snapshot(e.detail.id)
      // Dismiss on the WINNING arrival, not merely on a matching id (#482). Every
      // tap in a burst sends its own live_patch and the server renders all of them —
      // LiveView gates only history on linkRef, never the diff — so an A → B → A
      // burst mounts three streams. Matching on id alone meant A's own first
      // arrival matched the (re-selected) target A and tore the overlay down; B then
      // painted into the bare pane, and the user watched it flip through a chat they
      // had already tapped away from. Measured: 1 superseded stream mounting
      // uncovered per burst.
      //
      // The URL is the discriminator: commitPendingLink only lets the LAST patch
      // write history, so a superseded diff always arrives while location still
      // points elsewhere.
      if (
        this.target != null &&
        String(e.detail.id) === String(this.target) &&
        String(this.urlConvId()) === String(this.target)
      ) this.dismiss()
      this.rehydrateDraft(e.detail.id)
    }
    window.addEventListener("ed:conv-shown", this.onShown)
    // A patch can settle WITHOUT the target stream ever mounting — tap a room whose
    // membership just got revoked (knock window, selected: nil) and #message-scroll
    // leaves the DOM entirely. Don't shimmer over the knock window for the full safety
    // timeout: when live navigation finishes and there's no message pane at all, drop the
    // overlay. (A rapid A→B mid-flight keeps its pane — A's id ≠ B's — so this never
    // dismisses a still-loading transition.)
    this.onLoadStop = () => {
      // A reconnect cycle fires loading-stop with the pane absent — that's not a
      // settled navigation, it's the socket coming back (#439: the eject killed the
      // overlay + typed draft seconds before the chat landed).
      // Belt: a settled nav means taps are meaningful again even if dismiss()
      // hasn't run yet — and it must run BEFORE the disconnected bail below, or
      // a reconnect-cycle settle leaves the long-press guard stuck (#461 review).
      if (this.target == null) window.__edNavBusy = false
      // The back patch we fired has LANDED — re-arm the gesture now instead of
      // waiting out the belt (#480). Two conditions, both load-bearing: _backFired
      // is set only by backFinish, so an unrelated settle during the ~450ms slide
      // cannot drop the guard mid-choreography (the double-tap hazard #433 added it
      // for); and the URL must be the destination that back asked for, so one of the
      // many OTHER things that settle on this topic — folder switch, mark_as_read, a
      // search keystroke — cannot release it while the back patch is still in flight
      // (#487 review).
      if (this._backFired && location.pathname === this._backFired) {
        clearTimeout(this._backingBelt)
        this._backFired = null
        this._backing = false
      }
      if (!window.liveSocket?.isConnected?.()) return
      // A settled live nav re-rendered the aside — drop the rail overlay (#445) and
      // keep the sidebar snapshot warm for the NEXT hop (idle: off the settle frame).
      if (this.asideOv) this.asideDismiss()
      const idle = window.requestIdleCallback || ((f) => setTimeout(f, 200))
      idle(() => this.stashAside())
      // A settled navigation whose URL has COMMITTED to the target drops the overlay.
      // One condition covers both cases that need it (#499 review — the separate
      // "settled but no pane" branch this replaced was strictly subsumed by it):
      //   • the pane mounted, but its conv-shown arrived before commitPendingLink ran,
      //     so onShown's URL check had not yet passed;
      //   • no pane will EVER mount — a room whose membership was revoked mid-open
      //     renders the knock window instead — which must not sit under a shimmer for
      //     the full 15s strand timeout.
      // The URL is what separates those from an intermediate settle in a burst: a
      // superseded patch never commits one, so its arrival leaves the overlay up
      // (#482, measured: overlay gone at t=1468 while streams mounted at 1545/1587/1610,
      // leaving all three to paint bare).
      if (this.target != null && String(this.urlConvId()) === String(this.target)) this.dismiss()
    }
    window.addEventListener("phx:page-loading-stop", this.onLoadStop)
    // History traversal (the native WKWebView swipe-back, Android system back, browser
    // back/forward): the gesture's snapshot promises the previous screen, but the live
    // DOM only catches up after LiveView's round-trip — so the old screen flashed back
    // for ~RTT after the swipe (user report: "свайп → тот же чат → потом список").
    // Mirror the tap path: make the DOM match the target URL instantly, client-side;
    // the patch then normalizes everything. Mobile only — desktop shows both panes.
    this.onPop = () => {
      if (window.matchMedia("(min-width: 768px)").matches) return
      const main = document.getElementById("chat-dropzone")
      const aside = document.querySelector(".ed-root > aside")
      if (!main || !aside) return
      const m =
        location.pathname.match(/^\/app\/c\/([^\/]+)$/) ||
        location.pathname.match(/^\/channels\/[^\/]+\/r\/([^\/]+)$/)
      if (m) {
        // Traversing INTO a chat (back from deeper, or forward-swipe): full instant
        // treatment off the (hidden but present) sidebar row — overlay from cache.
        // CSS.escape: the id segment is user-influenced (URL), a quote would throw in
        // querySelector (#437 review). Matches ROOM rows too — they carry BOTH classes
        // (ed-convo-wrap ed-room-wrap); closest() below just detects which kind.
        const row = document.querySelector(
          `.ed-convo-wrap[data-id="${CSS.escape(m[1])}"] a.ed-convo`,
        )
        if (row && String(this.target) !== String(m[1])) {
          this.begin(row, m[1], !!row.closest(".ed-room-wrap"))
        }
        main.classList.remove("hidden")
        aside.classList.add("hidden")
        document.querySelector("nav.ed-rail")?.classList.add("hidden")
      } else {
        // Back to the list: both screens are local DOM — swap them in the same task
        // the history commits, so the settled gesture never shows the stale chat.
        // A system back SUPERSEDES a pending backFinish (#480): _navGen was bumped
        // by begin() and the rail path but never here, so a hardware/gesture back
        // during the ~450ms slide still let the deferred anchor.click() fire and
        // push another list entry on top of the state that had just been popped —
        // silently growing the stack that #476 exists to keep flat.
        this._navGen = (this._navGen || 0) + 1
        this.announceNav()
        this.revealList(main, aside)
      }
    }
    window.addEventListener("popstate", this.onPop)
    // Edge swipe-back (#432): OUR recognizer, replacing WKWebView's native gesture
    // (see BridgeViewController — the native same-document traversal double-navigated
    // and flashed the just-left chat back over the list). Touch-only, left edge, open
    // chat only; the pane follows the finger over the pre-revealed list, release runs
    // the SAME deterministic choreography as the header back button.
    this._swipe = null
    this._swipeGen = 0
    // The non-passive touchmove listener attaches ONLY for a touch that started in the
    // edge zone, and detaches on release (#438 review): a document-wide non-passive
    // touchmove would force the browser to await JS on EVERY move — scroll jank.
    this._trackSwipe = () => {
      document.addEventListener("touchmove", this.onTouchMove, { passive: false })
      document.addEventListener("touchend", this.onTouchEnd)
      document.addEventListener("touchcancel", this.onTouchCancel)
    }
    this._untrackSwipe = () => {
      document.removeEventListener("touchmove", this.onTouchMove)
      document.removeEventListener("touchend", this.onTouchEnd)
      document.removeEventListener("touchcancel", this.onTouchCancel)
    }
    // Android owns the back gesture and there is no way to give it up: the iOS
    // half of #432 turned WKWebView's gesture off (BridgeViewController), but that is
    // a WebView property with no Android counterpart — the system edge swipe is an OS
    // gesture. So this recognizer, written to REPLACE a native gesture, was running
    // alongside a live one there: one swipe, two navigations. Let the OS have it.
    this._ownsBackGesture = !(window.Capacitor?.getPlatform?.() === "android")
    this.onTouchStart = (e) => {
      if (!this._ownsBackGesture) return
      if (e.touches.length !== 1 || this._backing) return
      if (window.matchMedia("(min-width: 768px)").matches) return
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
      const t = e.touches[0]
      if (t.clientX > 24) return
      // Mid-load (the instant-nav overlay is up): the swipe drags the OVERLAY and
      // cancels the pending navigation — before, the gesture was dead until the patch
      // landed (#439: "зашли в чат — функционал выхода не работает, пока грузится").
      const loadingOv = this.overlay && this.target != null ? this.overlay : null
      if (!loadingOv) {
        // Only on an open chat (its header carries the back link); the thread sheet
        // has its own back affordance — don't fight it.
        // A MODAL owns the gesture while it is open (#515). The lightbox is a native
        // <dialog>, and the chat header BEHIND it stays in the DOM — so [data-nav-back]
        // is still found and the edge-swipe armed itself under the photo, ready to
        // navigate the page the viewer cannot even see.
        //
        // Modality matters, not merely being open: `dialog.show()` also sets [open] but
        // does NOT capture input, so a non-modal popover must not kill back-navigation.
        if (modalOpen()) return
        if (!document.querySelector("[data-nav-back]") || document.querySelector(".ed-thread")) return
      }
      const main = document.getElementById("chat-dropzone")
      const aside = document.querySelector(".ed-root > aside")
      if (!loadingOv && (!main || !aside)) return
      // href at ARM time (#477): the mid-load cancel below must know whether the
      // pending patch pushed a history entry while the finger was down. It normally
      // has not — this branch can only arm before the patch acks — so the URL is
      // still the screen we came from, and popping would take a REAL earlier entry.
      this._swipe = { x: t.clientX, y: t.clientY, t0: e.timeStamp, main, aside, armed: false, dx: 0, ov: loadingOv, href: location.href }
      this._trackSwipe()
    }
    this.onTouchMove = (e) => {
      const s = this._swipe
      if (!s) return
      const t = e.touches[0]
      const dx = t.clientX - s.x
      const dy = t.clientY - s.y
      if (!s.armed) {
        // A mostly-vertical start is a scroll — hand the touch back untouched.
        if (Math.abs(dy) > 12 && Math.abs(dy) > Math.abs(dx)) {
          this._swipe = null
          this._untrackSwipe()
          return
        }
        if (dx < 8) return
        s.armed = true
        s.gen = ++this._swipeGen
        if (!s.ov) {
          // Lift the pane and reveal the list + rail beneath, exactly like the button path.
          s.main.classList.add("ed-main-pop", "ed-main-pop--drag")
          s.aside.classList.remove("hidden")
          document.querySelector("nav.ed-rail")?.classList.remove("hidden")
          document.querySelectorAll(".ed-convo--active").forEach((n) => n.classList.remove("ed-convo--active"))
        }
      }
      s.dx = Math.max(0, dx)
      ;(s.ov || s.main).style.transform = "translateX(" + s.dx + "px)"
      e.preventDefault() // the pane is following the finger — no scroll/selection
    }
    // touchcancel is NOT a release (#481). The OS took the touch away, and routing it
    // into onTouchEnd made the commit test read whatever travel had accumulated — a
    // system-claimed gesture is exactly a fast flick (40px in 60ms = 0.67, well over
    // the 0.35 threshold), so it COMMITTED a back the user never performed.
    //
    // The LIVE case is iOS, where this recognizer IS the back gesture and the system
    // still interrupts it: a notification-shade pull, an incoming-call banner, Control
    // Center. Android's edge-back detector produces the same shape, but the platform
    // gate in onTouchStart means we never arm there any more (#490 review) — so that
    // path is closed upstream, and this handler is correct on its own terms rather
    // than leaning on the gate staying in place.
    //
    // The same class was already recognised and fixed for the long-press timer in
    // #462; the swipe recognizer never got the same treatment.
    this.onTouchCancel = () => {
      const s = this._swipe
      this._swipe = null
      this._untrackSwipe()
      if (!s || !s.armed) return
      this.abortSwipe(s)
    }
    this.onTouchEnd = (e) => {
      const s = this._swipe
      this._swipe = null
      this._untrackSwipe()
      if (!s || !s.armed) return
      if (s.ov) {
        // Mid-load: the overlay was the dragged screen.
        const el = s.ov
        const w0 = el.offsetWidth || window.innerWidth
        const dt0 = Math.max(1, e.timeStamp - s.t0)
        if (s.dx > w0 * 0.35 || s.dx / dt0 > 0.35) {
          document.activeElement?.blur?.()
          clearTimeout(this.timer)
          this.timer = null
          this.overlay = null
          this.target = null
          el.style.transition = "transform 0.25s var(--ed-ease)"
          el.style.transform = "translateX(100%)"
          setTimeout(() => el.remove(), 300)
          // The overlay covered the whole screen; the DOM underneath is still the
          // conversation we were LEAVING (or the list, if we came from there). Swap
          // to the list in this task so the settled gesture never flashes it.
          this.revealList(document.getElementById("chat-dropzone"), document.querySelector(".ed-root > aside"))
          this.cancelPending(s.href)
        } else {
          this.abortSwipe(s)
        }
        return
      }
      const w = s.main.offsetWidth || window.innerWidth
      const dt = Math.max(1, e.timeStamp - s.t0)
      const commit = s.dx > w * 0.35 || s.dx / dt > 0.35 // far enough, or a flick
      s.main.classList.remove("ed-main-pop--drag") // transitions back on
      void s.main.offsetWidth
      if (commit) {
        this._backing = true
        this.announceNav()
        document.activeElement?.blur?.() // keyboard drops with the slide (#439)
        // The gesture committed — the third of the three points that had no feedback at
        // all on the phone (#518).
        window.__edTap?.()
        s.main.style.transform = ""
        s.main.classList.add("ed-main-pop--out")
        const anchor = document.querySelector("[data-nav-back]")
        if (anchor) {
          this.backFinish(s.main, anchor)
        } else {
          // Can't happen on a chat screen; belt only — and it must release the guard
          // too, or back would stay dead until a remount (#438 review).
          history.back()
          setTimeout(() => (this._backing = false), 1000)
        }
      } else {
        this.abortSwipe(s)
      }
    }
    document.addEventListener("touchstart", this.onTouchStart, { passive: true })
    // Which row did the FINGER GO DOWN ON (#483)? The sidebar re-sorts by activity —
    // any message in any conversation does stream_delete_by_dom_id + stream_insert(at:
    // 0) — so a row can slide out from under a finger that is already resting on it,
    // and the click the browser then dispatches belongs to whatever row took its place.
    // Measured: the tap opened the arriving chat instead of the aimed one, 6 times out
    // of 6. Recorded unconditionally (the swipe recognizer's own touchstart bails on
    // desktop, Android and reduced motion, none of which apply to this).
    this.onTapStart = (e) => {
      const wrap = e.target.closest?.(".ed-convo-wrap")
      this._tapRow = wrap ? wrap.dataset.id : null
      this._tapAt = e.timeStamp
      const t = e.touches[0]
      this._tapXY = t ? { x: t.clientX, y: t.clientY } : null
    }
    // A gesture that turned into a SCROLL is no longer a tap on that row, so the
    // remembered intent goes with it (#497 review). Without this it survived until the
    // next touchstart and could steer an unrelated activation that arrived inside the
    // 1500ms window — a keyboard Enter on a focused row, say. touchend is deliberately
    // NOT a clearing point: the click being steered arrives after it.
    this.onTapMove = (e) => {
      const d = this._tapXY
      const t = e.touches[0]
      if (!d || !t) return
      if (Math.abs(t.clientX - d.x) > 10 || Math.abs(t.clientY - d.y) > 10) {
        this._tapRow = null
        this._tapXY = null
      }
    }
    this.onTapCancel = () => {
      this._tapRow = null
      this._tapXY = null
    }
    document.addEventListener("touchstart", this.onTapStart, { passive: true })
    document.addEventListener("touchmove", this.onTapMove, { passive: true })
    document.addEventListener("touchcancel", this.onTapCancel, { passive: true })
    // Swipe DOWN over the chat dismisses the keyboard (#439, TG behavior). The
    // h-screen layout keeps the native scrollView unscrollable, so iOS's interactive
    // dismiss never engages — a decisive downward drag blurs instead. Passive.
    this.onKbStart = (e) => {
      const a = document.activeElement
      // Scoped to the message panes (#443 review): a downward drag inside a modal /
      // caption textarea must not drop the keyboard mid-edit.
      const overPane = e.target.closest?.("#message-scroll, #thread-scroll")
      this._kbDrag =
        overPane && a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA")
          ? { x: e.touches[0].clientX, y: e.touches[0].clientY }
          : null
    }
    this.onKbMove = (e) => {
      const d = this._kbDrag
      if (!d) return
      const dy = e.touches[0].clientY - d.y
      const dx = Math.abs(e.touches[0].clientX - d.x)
      if (dy > 28 && dy > dx * 1.5) {
        this._kbDrag = null
        document.activeElement?.blur?.()
      }
    }
    document.addEventListener("touchstart", this.onKbStart, { passive: true })
    document.addEventListener("touchmove", this.onKbMove, { passive: true })
    // Readiness beacon: the e2e sync-probes (click + read the overlay in one task) must
    // not race this listener's attachment — connected() alone doesn't guarantee hooks
    // have mounted yet.
    // Suspended mid-gesture, the app must not come back and finish it (#493). A
    // WKWebView that is backgrounded defers pending timers and can flush them on
    // resume: the 450ms long-press, backFinish's 450ms fallback, the swipe-cancel
    // cleanup. Nothing in the app cleared any of that — the exhaustive grep for
    // visibility handling found only the keyboard reset, the focus heartbeat and
    // idle presence, none of which touch gesture state. Drop everything in flight;
    // the overlay is deliberately left alone, since the navigation it covers may
    // still land, and its own 15s strand timer already bounds it.
    this.onSuspend = () => {
      this._swipe = null
      this._untrackSwipe()
      this._backing = false
      this._backFired = null
      clearTimeout(this._backingBelt)
      this._tapRow = null
      this._tapXY = null
      window.__edNavBusy = false
    }
    this.onVisibility = () => {
      if (document.visibilityState !== "visible") this.onSuspend()
    }
    document.addEventListener("visibilitychange", this.onVisibility)
    // Native lifecycle is the authoritative signal on a hard suspend (native.js
    // relays appStateChange); visibilitychange covers browsers and most backgrounds.
    window.addEventListener("ed:suspend", this.onSuspend)
    window.__edInstantNavReady = true
  },
  maybeStart(e) {
    // Primary click only — modified clicks (open-in-new-tab etc.) don't patch.
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
    // Mobile thread close (#432) — a BUTTON, so checked before the anchor gate below:
    // the sheet slides off to the right, then the real close event fires. Capture-phase
    // stopPropagation keeps LiveView's own phx-click from closing it instantly mid-slide.
    const closer = e.target.closest?.('[phx-click="close_thread"], [phx-click="close_threads"]')
    // Desktop: the panel is `:if={@thread_root}` on the server, so it stood there for the
    // whole round trip after the click — measured, the panel left only when the diff
    // arrived (#521). Take it off screen now and let the event go on to LiveView, whose
    // diff removes the node for real; morphdom drops this inline style with it.
    //
    // Not the mobile choreography below: there the panel is the whole screen and slides
    // away, and the event is deferred until the slide ends. Here it is a column beside the
    // chat, so it simply stops being there — and the click is answered in the same frame.
    if (closer && !window.matchMedia("(max-width: 767px)").matches) {
      const sheet = closer.closest(".ed-thread")
      if (sheet) sheet.style.display = "none"
    }
    if (closer && window.matchMedia("(max-width: 767px)").matches) {
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
      const sheet = closer.closest(".ed-thread")
      if (!sheet) return
      e.preventDefault()
      e.stopPropagation()
      const evt = closer.getAttribute("phx-click")
      let sent = false
      const fire = () => {
        if (sent) return
        sent = true
        sheet.removeEventListener("transitionend", onEnd)
        this.pushEvent(evt, {})
      }
      // transitionend BUBBLES: a child's transition (the tapped button's own 160ms
      // background fade, hovers) would fire a {once:true} listener before the sheet's
      // slide finishes — filter for the sheet's own transform (#433 review).
      const onEnd = (ev) => {
        if (ev.target === sheet && ev.propertyName === "transform") fire()
      }
      sheet.addEventListener("transitionend", onEnd)
      setTimeout(fire, 400)
      sheet.classList.add("ed-thread--out")
      return
    }
    // Opening a thread costs a full round trip before anything appears: the panel is
    // `:if={@thread_root}` on the server, and behind that reply the server runs a query, a
    // WRITE (mark_thread_read), a follow lookup and a stream reset. Measured with the
    // socket at 500ms: 1022ms of nothing, and on a phone that is a full-screen transition
    // with no frame at all (#521). Paint the panel's shape now; the real one replaces it.
    const opener = e.target.closest?.('[phx-click="open_thread"], [phx-click="open_threads"]')
    if (opener && !document.querySelector(".ed-thread")) this.threadSkel()

    const anchor = e.target.closest && e.target.closest("a")
    if (!anchor) return
    // Logging out wipes the at-rest cache BEFORE navigating away (shared-machine privacy).
    if (anchor.getAttribute("href") === "/users/log_out") {
      if (this.cache) this.cache.clearAll()
      return
    }
    // Mobile back (chat → list, #432): both screens are already local DOM — reveal the
    // list, slide the chat pane off to the right over it, THEN run the real patch (the
    // re-click below carries a bypass flag). Desktop / reduced-motion falls through to
    // the plain instant patch.
    if (anchor.hasAttribute("data-nav-back")) {
      if (
        this._backing ||
        window.matchMedia("(min-width: 768px)").matches ||
        window.matchMedia("(prefers-reduced-motion: reduce)").matches
      ) {
        return
      }
      const main = document.getElementById("chat-dropzone")
      const aside = document.querySelector(".ed-root > aside")
      if (!main || !aside) return
      // Armed for the WHOLE choreography (#433 review): a double-tap mid-slide falls
      // through to the plain instant patch above instead of re-running the slide, and
      // the programmatic re-click below passes through to LiveView the same way.
      this._backing = true
      this.announceNav()
      e.preventDefault()
      e.stopPropagation()
      // Leaving the chat dismisses the keyboard WITH the slide (#439: it hung over the
      // list for a beat — the focused input left the DOM and WebKit noticed late).
      document.activeElement?.blur?.()
      // Same task: lift main into a fixed layer FIRST, then un-hide the list — no
      // intermediate frame where both share the flex row at 50/50. The channel RAIL is
      // hidden by the same @selected-driven class as the aside — reveal it too, or the
      // slide exposes a rail-less list and the rail pops in a round-trip later,
      // squeezing the list (user report).
      main.classList.add("ed-main-pop")
      aside.classList.remove("hidden")
      document.querySelector("nav.ed-rail")?.classList.remove("hidden")
      // The just-left chat's row still carries the server-rendered --active wash until
      // the patch lands — it read as a stuck blue row for a round-trip (#439). Clear it
      // client-side; the patch re-renders the truth either way.
      document.querySelectorAll(".ed-convo--active").forEach((n) => n.classList.remove("ed-convo--active"))
      // Force a style flush between the start and end states: a rAF does NOT guarantee
      // an intervening recalc, so the browser sometimes saw only the final transform and
      // skipped the transition entirely (the "back animation is gone" report — a timing
      // lottery, not a logic change). Reading offsetWidth commits translateX(0) first.
      void main.offsetWidth
      main.classList.add("ed-main-pop--out")
      this.backFinish(main, anchor)
      return
    }
    // Rail navigation (#445 wave 1): a channel/home tap answers ON-SCREEN in one
    // frame — the active dot moves, the sidebar paints its cached list (or a
    // skeleton), and on desktop the entry room opens through the normal chat
    // overlay. The patch then normalizes everything. Settings/logout fall through.
    if (anchor.classList.contains("ed-rail__btn")) {
      const href = anchor.getAttribute("href") || ""
      const chan = href.match(/^\/channels\/([^\/]+)(?:\/r\/([^\/]+))?$/)
      const home = href === "/app"
      if (!home && !chan) return
      const railKey = home ? "m" : "c:" + chan[1]
      // Repeat tap on the same in-flight rail target — swallow entirely (the
      // ed-convo lesson: queued duplicate patches re-open after every back).
      if (this.asideOv && this._railKey === railKey) {
        e.preventDefault()
        e.stopPropagation()
        return
      }
      // Already there (incl. our own optimistic activation): the patch is a no-op.
      if (anchor.classList.contains("ed-rail__btn--active")) return
      this._navGen = (this._navGen || 0) + 1
      this._railKey = railKey
      this.stashAside()
      document
        .querySelectorAll(".ed-rail__btn--active")
        .forEach((b) => b.classList.remove("ed-rail__btn--active"))
      const slot = anchor.closest(".ed-rail__slot")
      ;(slot ? slot.querySelectorAll(".ed-rail__btn:not(.ed-rail__btn--me)") : [anchor]).forEach(
        (b) => b.classList.add("ed-rail__btn--active")
      )
      this.asidePaint(railKey, anchor.getAttribute("title") || "")
      // Desktop: the entry room opens in the main pane — full instant treatment
      // with the room's cached thread; the name rides the cache meta (#445),
      // falling back to the channel's (corrected by the patch if they differ).
      const roomId = chan && chan[2]
      if (roomId && window.matchMedia("(min-width: 768px)").matches) {
        // Freshness: snapshot whatever conversation is being left (same as begin).
        const leaving = document.getElementById("message-scroll")
        const leavingMsgs = leaving && document.getElementById("messages")
        if (leaving && leavingMsgs && this.cache && this.userId && leaving.dataset.conversationId) {
          this.cache.put(this.userId, leaving.dataset.conversationId, leavingMsgs.innerHTML, this.paneTitle())
        }
        this.target = roomId
        const cached = this.cache && this.userId ? this.cache.peek(this.userId, roomId) : null
        const glyph = document.createElement("span")
        glyph.className = "ed-room__hash ed-room__hash--lg"
        glyph.textContent = "#"
        this.paint({
          name: (cached && cached.name) || anchor.getAttribute("title") || "",
          iconNode: glyph,
          isRoom: true,
          cachedHTML: cached && cached.html,
        })
        if (!cached && this.cache && this.userId) {
          this.cache.get(this.userId, roomId).then((hit) => {
            if (!hit || this.target !== roomId || !this.overlay) return
            this.fillCache(hit.html)
            // A cross-reload hit also carries the room's real name (meta) — the
            // paint above could only guess the channel's.
            const nameEl = hit.name && this.overlay.querySelector(".ed-nav-skel__name")
            if (nameEl) nameEl.textContent = hit.name
          })
        }
      }
      return // no preventDefault — the patch link must still fire
    }
    if (!anchor.classList.contains("ed-convo")) return
    let link = anchor
    // Honour the row the finger went down on (#483). The sidebar re-sorts on activity
    // in ANY conversation, so a row can slide away under a resting finger and the
    // browser then dispatches the click against whatever took its place — opening a
    // chat the user never aimed at. The touch target is fixed at touchstart, so that
    // is the intent; hit-testing at release is not.
    //
    // Only for a genuinely recent touch (a stale id must never steer a later mouse
    // click), only when both rows are real, and never while a context menu is open —
    // that click belongs to the menu, whose own capture handler runs after this one
    // and would be robbed of it.
    const aimed = this._tapRow
    this._tapRow = null
    if (
      aimed &&
      e.timeStamp - (this._tapAt || 0) < 1500 &&
      String(aimed) !== String(anchor.closest(".ed-convo-wrap")?.dataset.id) &&
      !document.querySelector("[data-menu]:not([hidden])")
    ) {
      const intended = document.querySelector(
        `.ed-convo-wrap[data-id="${CSS.escape(aimed)}"] a.ed-convo`,
      )
      if (intended) {
        e.preventDefault()
        e.stopPropagation()
        intended.click() // re-enters here with _tapRow cleared, so it just proceeds
        return
      }
    }
    // The tapped row is already open? The patch is a no-op, so nothing will ever
    // announce — don't strand an overlay.
    if (link.classList.contains("ed-convo--active")) return
    const wrap = link.closest(".ed-convo-wrap")
    const id = wrap && wrap.dataset.id
    if (!id) return
    // A repeat tap on the SAME chat while its transition is still in flight (laggy
    // link, no visual response yet) must be a NO-OP, TG-style: without this every tap
    // queued another identical patch + history entry, and once the network caught up
    // the stale queue re-opened the chat after each "back" (user report: "открылось
    // 3 чата, пришлось жать 3 раза выйти"). Swallow it entirely.
    if (this.overlay && this.target != null && String(this.target) === String(id)) {
      e.preventDefault()
      e.stopPropagation()
      return
    }
    // Own the row's appearance client-side (#514). Opening a chat used to re-stream the
    // WHOLE sidebar server-side for two visual facts: which row is active and that the
    // opened one has no unread left. That cost ~6 queries and a full stream table on
    // every navigation — and it arrived a round-trip late, so the list this hook had
    // already repainted flickered back. The client knows both facts at tap time.
    //
    // The server still renders the truth on a fresh load or any later re-stream; this
    // only removes the round-trip whose sole job was to agree with what already happened.
    this.markActive(id)

    const isRoom = wrap.classList.contains("ed-room-wrap")
    // A tap that SUPERSEDES an in-flight back must REPLACE the chat's history entry
    // instead of pushing on top of it (#476). LiveView pushes history state only in the
    // server-reply callback (live_socket.js pushHistoryPatch -> view.js pushLinkPatch),
    // so a back that backFinish cancels on _navGen (#439) — which is exactly what a fast
    // "back then tap another chat" does — never pushes its list entry at all. The stack
    // silently became chat -> chat -> chat, and the next system back (Android hardware,
    // iOS history.back()) landed in a chat the user had opened earlier instead of the
    // list. Replacing here compensates for the list entry that was cancelled.
    //
    // The condition is precise, not "while _backing": we must still be ON a chat URL,
    // i.e. the back has not landed and owns no entry of its own. Once it HAS landed the
    // URL is already the list, and replacing would EAT that list entry — back would then
    // skip past the list to whatever preceded it (settings, another chat).
    if (this._backing && /^\/(app\/c|channels\/[^\/]+\/r)\//.test(location.pathname)) {
      const prev = link.getAttribute("data-phx-link-state")
      link.setAttribute("data-phx-link-state", "replace")
      // LiveView reads the attribute synchronously in its own click handler (window,
      // bubble — always after this capture listener), so restoring on the next task is
      // safe and keeps the row from replacing forever after.
      setTimeout(() => {
        if (prev == null) link.removeAttribute("data-phx-link-state")
        else link.setAttribute("data-phx-link-state", prev)
      }, 0)
    }
    this.begin(link, id, isRoom)
    // Do NOT preventDefault — the <.link patch> navigation must still fire.
  },
  // Run the real patch once the pane's slide-out lands. Shared by the header back
  // button and the edge-swipe recognizer. transitionend BUBBLES — a child's transition
  // (the tapped button's own background fade) would fire early; filter for the pane's
  // own transform, with a timeout fallback.
  backFinish(main, anchor) {
    let done = false
    // Superseded-navigation stamp (#439, the zz-nav-races repro): if the user taps
    // INTO another chat mid-slide, begin() bumps the generation — firing the delayed
    // back-patch then would land AFTER that chat's patch and yank them to the list
    // ("на 2-3 клике чат не открывается"). The forward patch owns cleanup instead.
    const gen = (this._navGen = (this._navGen || 0) + 1)
    const go = () => {
      if (done) return
      done = true
      main.removeEventListener("transitionend", onEnd)
      if (this._navGen !== gen) {
        this._backing = false
        return
      }
      // Release the guard on the SETTLE, not on a clock (#480). The fixed 1000ms
      // ran from the click, i.e. up to ~1.45s from the gesture, while a normal RTT
      // put the user inside the next screen in about a third of that — so the edge
      // swipe out of THAT screen refused to arm (onTouchStart bails on _backing) and
      // back was simply dead for the rest of the second. Fast switching made it
      // worse, which is exactly when it was reported.
      //
      // Stamped with the DESTINATION, not a bare boolean (#487 review): plenty of
      // unrelated things settle on this topic — a folder switch, mark_as_read, a
      // search keystroke — and any of them would otherwise drop the guard while the
      // back patch was still in flight. onLoadStop releases only once the URL is
      // actually the screen this back asked for. Set BEFORE the click so no ordering
      // question remains, even though the click's own settle is necessarily async.
      // The timeout stays as a belt for a patch that never settles (stalled socket),
      // where the old behaviour — clearing while still pending — is also the safer one.
      this._backFired = anchor.getAttribute("href")
      clearTimeout(this._backingBelt)
      this._backingBelt = setTimeout(() => {
        this._backFired = null
        this._backing = false
      }, 1000)
      anchor.click() // real patch; morphdom then normalizes every class
    }
    const onEnd = (ev) => {
      if (ev.target === main && ev.propertyName === "transform") go()
    }
    main.addEventListener("transitionend", onEnd)
    setTimeout(go, 450) // fallback if the filtered event never fires
  },
  // One signal for "the app is navigating", broadcast from every entry point: a chat
  // tap (begin), the header back branch, a committed edge swipe, and history traversal.
  // The ContextMenu hook listens while a menu is open, because NOTHING else closes one
  // on navigation (#478): close() is reachable only from an outside click, Escape, a
  // scroll or destroyed(), and the back path stopPropagations its own tap in capture so
  // the outside-click listener never sees it. A menu left open then rides the screen it
  // belongs to — visible over the list for the whole ~450ms slide, and on mobile still
  // OPEN (hidden=false, `active` pointing at it) inside a pane that was merely given
  // class="hidden", ready to reappear the moment that pane is shown again.
  announceNav() {
    window.dispatchEvent(new Event("ed:nav"))
  },
  // Undo an edge swipe without navigating: glide the dragged screen home and restore
  // the exact pre-gesture state (the server never heard about any of this). Shared by
  // the "not far enough" release and by touchcancel, which must ALWAYS land here (#481).
  // Generation-stamped (#438 review): if a NEW gesture armed during the ~450ms glide,
  // this stale cleanup must not strip its classes / re-hide the list out from under it.
  abortSwipe(s) {
    if (s.ov) {
      // Mid-load: the dragged screen was the loading overlay, and the pane beneath it
      // was never touched — only the overlay has to come home.
      s.ov.style.transition = "transform 0.2s var(--ed-ease)"
      s.ov.style.transform = ""
      setTimeout(() => (s.ov.style.transition = ""), 250)
      return
    }
    // Idempotent for the release path (which already dropped it), required for the
    // touchcancel path (which skips that code). The forced reflow commits the current
    // transform before the class re-enables transitions, or the glide is skipped —
    // same reason the commit branch reads offsetWidth (#436).
    s.main.classList.remove("ed-main-pop--drag")
    void s.main.offsetWidth
    const fin = () => {
      s.main.removeEventListener("transitionend", onEnd)
      if (this._swipeGen !== s.gen) return
      s.main.classList.remove("ed-main-pop")
      s.main.style.transform = ""
      s.aside.classList.add("hidden")
      document.querySelector("nav.ed-rail")?.classList.add("hidden")
    }
    let done = false
    const once = () => { if (!done) { done = true; fin() } }
    const onEnd = (ev) => {
      if (ev.target === s.main && ev.propertyName === "transform") once()
    }
    s.main.addEventListener("transitionend", onEnd)
    setTimeout(once, 450)
    s.main.style.transform = "translateX(0px)"
  },
  // The conversation the URL currently commits to, or null. Both patterns are
  // deliberately UNANCHORED at the end (#499 review asked where the /m/:id branch is —
  // there is none, and none is needed): /app/c/34/m/99 and /channels/13/r/36/m/7 match
  // the same expressions and yield 34 and 36. The onPop patterns anchor with $ because
  // they decide whether a URL is a chat screen at all; this one only has to name the
  // conversation, so the permalink suffix is simply ignored.
  urlConvId() {
    const m =
      location.pathname.match(/^\/app\/c\/([^\/]+)/) ||
      location.pathname.match(/^\/channels\/[^\/]+\/r\/([^\/]+)/)
    return m ? m[1] : null
  },
  // Put the LIST on screen right now, client-side. Both screens are local DOM, so
  // the swap happens in the same task as the gesture that asked for it and the
  // settled gesture never flashes the chat it just left; the patch then normalizes
  // every class. Shared by history traversal (onPop) and the mid-load cancel.
  // Move the active wash onto a conversation's sidebar row and drop its unread badge.
  // Keyed by id, not by the tapped element, because a chat opens from more places than
  // the list: a search result, a message permalink, a notification, history. Those never
  // touch a `.ed-convo-wrap`, and before this they left the row unwashed with a stale
  // badge until something else re-streamed the sidebar (#544 review).
  markActive(id) {
    const wrap = document.querySelector(`.ed-convo-wrap[data-id="${CSS.escape(String(id))}"]`)
    document
      .querySelectorAll(".ed-convo--active")
      .forEach((n) => n.classList.remove("ed-convo--active"))
    if (!wrap) return
    wrap.querySelector("a.ed-convo")?.classList.add("ed-convo--active")
    // Opening a chat marks it read; the badge is the one part of the row the server would
    // otherwise have to come back to correct. Removed, not hidden — a re-stream renders
    // the row afresh, so there is no stale state to restore.
    wrap.querySelector(".ed-badge")?.remove()
  },

  revealList(main, aside) {
    if (!main || !aside) return
    document.activeElement?.blur?.()
    document.querySelectorAll(".ed-convo--active").forEach((n) => n.classList.remove("ed-convo--active"))
    main.classList.add("hidden")
    aside.classList.remove("hidden")
    document.querySelector("nav.ed-rail")?.classList.remove("hidden")
    // A full-screen thread sheet would keep covering the list until the patch.
    document.querySelector(".ed-thread")?.classList.add("hidden")
  },
  // Undo a navigation the user swiped away while it was still in flight (#477).
  //
  // There is NO optimistic pushPatch to undo, despite what this code used to claim:
  // LiveView pushes history state only in the server-reply callback (live_socket.js
  // pushHistoryPatch -> view.js pushLinkPatch), and the mid-load branch can only arm
  // WHILE that patch is unacked. So the old unconditional history.back() popped a
  // real, unrelated entry every time — landing on the previously visited chat, or
  // traversing out of the app entirely (first tap after login -> /login, a full page
  // load), or, when the chat screen was history entry 0, doing nothing at all while
  // the patch went on to ack and open the very chat the user had just cancelled.
  //
  // Pop only when the URL actually moved since the gesture armed — i.e. the patch
  // DID ack mid-gesture and really pushed. Otherwise supersede FORWARD through the
  // always-rendered list link: that bumps LiveView's linkRef, so the in-flight chat
  // patch's historyPatch is dropped on arrival, and the app settles on the list with
  // the history stack untouched. The link is `replace`, so the settle cannot add an
  // entry of its own either.
  // Deliberately does NOT bump _navGen (#486 review): that generation supersedes a
  // pending backFinish, and one can never be pending here — backFinish holds
  // _backing for its whole choreography, and onTouchStart refuses to arm this
  // gesture while _backing is set. The navigation actually superseded here is the
  // in-flight chat PATCH, and the link click below is what does it, via linkRef.
  cancelPending(armedHref) {
    if (armedHref && location.href !== armedHref) {
      history.back()
      return
    }
    const list = document.querySelector("[data-nav-list]")
    // The link rides the ChatLive root, so it is always present here; the pop is a
    // belt for a DOM we don't own rather than a path we expect to take.
    if (list) list.click()
    else history.back()
  },
  // Start the instant transition INTO a chat: paint the overlay (cache or skeleton),
  // snapshot the conversation being left, kick the async IDB fill. Shared by the tap
  // path (maybeStart) and history traversal (onPop — the native swipe-back/forward).
  begin(link, id, isRoom) {
    // Any forward navigation supersedes a pending back-patch (see backFinish).
    this._navGen = (this._navGen || 0) + 1
    // …and the guard drops WITH it (#480). backFinish's go() also clears _backing on
    // a superseded generation, but go() does not run until transitionend or its 450ms
    // fallback — so for the rest of that window the back choreography was already dead
    // while its guard was still up, and onTouchStart refused to arm the edge swipe out
    // of the screen we are opening right now. Measured: the navlog shows the swipe
    // marker followed by no history.back(), no popstate and no cancel click at all,
    // which is what kept the tap→midloadSwipe plan red (and #477's fix unreachable).
    // The destination stamp goes with it, or a later settle on that same URL could
    // match and release a guard belonging to a DIFFERENT, newer back (#487 review).
    this._backing = false
    this._backFired = null
    // In-flight beacon (#439): rapid chat switching keeps the main thread busy
    // (cache parse + morphs), delaying touchend past the 450ms long-press
    // threshold — the row context menu popped on plain taps. ContextMenu checks
    // this before opening.
    window.__edNavBusy = true
    this.announceNav()
    // The name span nests badge spans whose sr-only text ("Muted"/"Favorite") would ride
    // along in textContent — strip them on a clone so a muted chat's overlay header reads
    // "Вася", not "Вася Без звука".
    const nameEl = link.querySelector(".ed-convo__name")
    let name = ""
    if (nameEl) {
      const clone = nameEl.cloneNode(true)
      clone.querySelectorAll(".ed-convo__muted, .sr-only").forEach((n) => n.remove())
      name = clone.textContent.trim()
    }
    // The leading child is the real avatar (DM/group) or the room # glyph — CLONE the
    // node (never serialize→re-parse its HTML) so the header shows WHO you're opening
    // instantly, with no innerHTML path for the (user-controlled) display name/initials.
    const iconNode = link.firstElementChild ? link.firstElementChild.cloneNode(true) : null
    // The sidebar renders the avatar at base size and the room glyph small; the REAL
    // header uses size sm for avatars and --lg for the glyph. Match it, or the clone
    // reads oversized/undersized for the overlay's lifetime (the "аватарка больше" jump).
    if (iconNode) iconNode.classList.add(isRoom ? "ed-room__hash--lg" : "ed-avatar--sm")
    this.target = id
    // Same-session revisit → paint the cached thread synchronously (no skeleton flash).
    const cached = this.cache && this.userId ? this.cache.peek(this.userId, id) : null
    this.paint({ name, iconNode, isRoom, cachedHTML: cached && cached.html })
    // Freshness: snapshot the conversation we're LEAVING, right now — everything sent or
    // received while it was open (including the user's own last message) is in this DOM
    // and would otherwise be missing from its next cache paint (the shown-time snapshot
    // is as-of-OPEN). After paint() so the innerHTML serialization can't delay the
    // overlay's first frame; the IDB write inside put() is async anyway.
    const leaving = document.getElementById("message-scroll")
    const leavingMsgs = leaving && document.getElementById("messages")
    if (leaving && leavingMsgs && this.cache && this.userId && leaving.dataset.conversationId) {
      this.cache.put(this.userId, leaving.dataset.conversationId, leavingMsgs.innerHTML, this.paneTitle())
    }
    // No in-memory hit (a cross-reload first open): try IndexedDB and swap in if it lands
    // before the real stream — else the skeleton just stays until the real stream does.
    if (!cached && this.cache && this.userId) {
      this.cache.get(this.userId, id).then((hit) => {
        if (hit && this.target === id && this.overlay) this.fillCache(hit.html)
      })
    }
  },
  paint({ name, iconNode, isRoom, cachedHTML }) {
    this.remove() // clear any prior overlay instantly (rapid taps)
    const ov = document.createElement("div")
    ov.className = "ed-nav-skel"
    ov.setAttribute("aria-hidden", "true") // decorative; real content lands in ~RTT
    const pane = document.getElementById("chat-dropzone")
    const desktop = window.matchMedia("(min-width: 768px)").matches
    const curScroll = document.getElementById("message-scroll")
    // Desktop: cover the pane's header + message area ONLY. When a chat is open, the
    // overlay's bottom edge sits at the top of the composer, so the real input stays
    // visible (and interactive) straight through the transition — TG-style, the composer
    // persists across chats. The pane is a floating card on desktop (1px border +
    // --ed-radius-panel, overflow hidden): mirror its border and corners so the card
    // doesn't visibly square off for the overlay's lifetime.
    if (desktop && pane && pane.offsetParent !== null) {
      const r = pane.getBoundingClientRect()
      const cs = getComputedStyle(pane)
      const bottom = curScroll ? curScroll.getBoundingClientRect().bottom : r.bottom
      ov.style.left = r.left + "px"
      ov.style.top = r.top + "px"
      ov.style.width = r.width + "px"
      ov.style.height = bottom - r.top + "px"
      ov.style.borderTop = ov.style.borderLeft = ov.style.borderRight =
        cs.borderTopWidth + " " + cs.borderTopStyle + " " + cs.borderTopColor
      ov.style.borderTopLeftRadius = cs.borderTopLeftRadius
      ov.style.borderTopRightRadius = cs.borderTopRightRadius
      if (!curScroll) {
        // Empty state (no chat open): the whole card is covered — keep its bottom edge too.
        ov.style.borderBottom = ov.style.borderTop
        ov.style.borderBottomLeftRadius = cs.borderBottomLeftRadius
        ov.style.borderBottomRightRadius = cs.borderBottomRightRadius
      }
    } else {
      // Mobile / hidden pane: the chat opens as a full-screen pane.
      ov.classList.add("ed-nav-skel--full")
    }
    const full = ov.classList.contains("ed-nav-skel--full")
    // No real composer visible beneath (mobile full-screen from the list / desktop empty
    // state) → the overlay draws a composer SKELETON at its bottom, so the shell reads
    // complete ("шапка + лента + инпут") instead of ending in blank space. The full-screen
    // (mobile) header also leads with a back-arrow placeholder — the real mobile header
    // has one, and without it the avatar/name would jump right at the handoff.
    const needFoot = !curScroll
    // Static skeleton via innerHTML (no dynamic content); the name goes in as text and the
    // avatar/glyph as a cloned node — so nothing user-controlled is ever parsed as HTML.
    ov.innerHTML = this.shellMarkup(isRoom, needFoot, full)
    ov.querySelector(".ed-nav-skel__name").textContent = name
    const ph = ov.querySelector(".ed-nav-skel__ph")
    if (ph) {
      ph.placeholder = this.el.dataset.composerPlaceholder || ""
      // Persist keystrokes: a long-stalled socket makes LiveView fall back to a
      // FULL page load for the pending navigation (window.location) — the overlay
      // and any in-memory draft die with the document. The stash survives; the
      // next conv-shown for this chat rehydrates it (rehydrateDraft).
      const draftFor = String(this.target)
      ph.addEventListener("input", () => {
        try {
          sessionStorage.setItem(
            "ed:navdraft",
            JSON.stringify({ id: draftFor, text: ph.value, at: Date.now() })
          )
        } catch (_e) {}
      })
    }
    // Before the title (not head-prepend): the mobile variant's back placeholder must
    // stay leftmost, icon between it and the title — mirroring the real header order.
    if (iconNode) ov.querySelector(".ed-nav-skel__title").before(iconNode)
    document.body.appendChild(ov)
    this.overlay = ov
    if (cachedHTML) this.fillCache(cachedHTML)
    // Safety net: if the nav errors and nothing ever announces, don't strand it.
    // Generous on purpose (#439): at 6s this EJECTED every slow load back onto the
    // list ("чат вылетает") — a suspended/resumed WebView or a cross-border rejoin
    // takes longer. onLoadStop already handles a patch that settles without a pane.
    this.timer = setTimeout(() => this.dismiss(), 15000)
  },
  // Replace the skeleton body with a cached render of the thread (display-only). The source
  // is the app's OWN prior server render (HEEx-escaped), parsed via <template> and shown
  // outside LiveView's managed tree — so phx-hooks stay dormant. <script> nodes are
  // REMOVED before adoption (template parsing doesn't run them, but adopting the content
  // would — none should exist in our render; defense-in-depth since IndexedDB is
  // client-writable). ids are stripped to avoid duplicate-id collisions with the real
  // #messages during the fade; transient state classes (selection wash, jump highlight,
  // enter animation) captured mid-effect are stripped so they don't replay.
  fillCache(html) {
    if (!this.overlay) return
    const body = this.overlay.querySelector(".ed-nav-skel__body")
    if (!body) return
    try {
      const tpl = document.createElement("template")
      tpl.innerHTML = html
      tpl.content.querySelectorAll("script").forEach((n) => n.remove())
      tpl.content.querySelectorAll("[id]").forEach((n) => n.removeAttribute("id"))
      const transient = ["ed-msg--selected", "ed-flat--selected", "ed-msg--focus", "ed-msg--enter"]
      tpl.content.querySelectorAll("." + transient.join(", .")).forEach((n) => {
        n.classList.remove(...transient)
      })
      body.replaceChildren(tpl.content)
      body.classList.add("ed-nav-skel__body--cache")
      body.scrollTop = body.scrollHeight // a chat opens pinned to its newest message
      // A photo that needs a (re)decode painted as a hard gray box for a frame or two
      // (user recording, t≈11.4s) — fade late images in instead; already-decoded ones
      // (img.complete) render instantly as before. Errors reveal too (alt box > void).
      body.querySelectorAll("img").forEach((img) => {
        if (img.complete) return
        img.classList.add("ed-imgwait")
        const show = () => img.classList.add("ed-imgin")
        img.addEventListener("load", show, { once: true })
        img.addEventListener("error", show, { once: true })
      })
    } catch (_e) {
      /* a malformed snapshot just leaves the skeleton — navigation must not break */
    }
  },
  // Snapshot the just-rendered #messages into the cache so the NEXT open of this
  // conversation paints instantly. Best-effort; scoped by user id.
  snapshot(convId) {
    if (!this.cache || !this.userId || !convId) return
    // Defer the ~0.5 MB innerHTML serialization + IndexedDB write off the navigation paint.
    // At idle, only snapshot if this conversation is STILL open — a fast navigate-away must
    // not cache the new conversation's DOM under the old id (the new one snapshots itself on
    // its own ed:conv-shown).
    const run = () => {
      const scroll = document.getElementById("message-scroll")
      if (!scroll || scroll.dataset.conversationId !== String(convId)) return
      const msgs = document.getElementById("messages")
      if (msgs) this.cache.put(this.userId, convId, msgs.innerHTML, this.paneTitle())
    }
    if (window.requestIdleCallback) requestIdleCallback(run, { timeout: 2000 })
    else setTimeout(run, 200)
  },
  shellMarkup(isRoom, withFoot, withBack) {
    let rows = ""
    if (isRoom) {
      // Flat rooms: a leading avatar on every row (Mattermost layout).
      for (const w of [58, 40, 72, 34, 64, 48, 30]) {
        rows += `<div class="ed-nav-skel__row"><span class="ed-nav-skel__av ed-skel-shimmer"></span><span class="ed-nav-skel__bubble ed-skel-shimmer" style="width:${w}%"></span></div>`
      }
    } else {
      // DMs: alternating incoming/outgoing bubbles.
      for (const [me, w] of [[0, 60], [1, 44], [0, 72], [0, 32], [1, 54], [1, 38], [0, 66]]) {
        rows += `<div class="ed-nav-skel__row ${me ? "ed-nav-skel__row--me" : ""}"><span class="ed-nav-skel__bubble ed-skel-shimmer" style="width:${w}%"></span></div>`
      }
    }
    // The composer is static chrome — nothing about it "loads", so it must NOT look
    // like a preloader (user report: the shimmer pill was shorter than the real bar,
    // so the handoff jumped). A pixel replica out of the REAL composer's classes:
    // same paperclip / input / emoji / send, same paddings → same height, zero jump.
    // The safe-area / keyboard bottom padding lives on the overlay CONTAINER
    // (.ed-nav-skel--full, keyboard-lift v2) — not here, or the two would stack.
    // The input is REAL (#439): you can type while the chat loads; dismiss() hands
    // the draft + focus into the mounting composer.
    const foot = withFoot
      ? `<div class="ed-nav-skel__foot flex flex-col gap-2 p-3 border-t shrink-0" style="border-color: var(--ed-border);"><div class="flex items-center gap-2"><span class="ed-btn--icon">${window.edIcon("hero-paper-clip-micro", "size-5")}</span><input type="text" enterkeyhint="send" class="ed-input ed-nav-skel__ph"><span class="ed-btn--icon">${window.edIcon("hero-face-smile-micro", "size-5")}</span><span class="ed-btn ed-btn--primary ed-btn--send">${window.edIcon("hero-paper-airplane-micro", "size-4")}</span></div></div>`
      : ""
    // The real mobile header leads with a back arrow (md:hidden) — mirror it on the
    // full-screen variant so the avatar/name don't shift right at the handoff.
    const back = withBack
      ? `<span class="ed-nav-skel__back">${window.edIcon("hero-arrow-left-mini", "size-5")}</span>`
      : ""
    return `<div class="ed-nav-skel__head">${back}<div class="ed-nav-skel__title"><span class="ed-nav-skel__name"></span><span class="ed-nav-skel__sub ed-skel-shimmer"></span></div></div><div class="ed-nav-skel__body">${rows}</div>${foot}`
  },
  // The open pane's header title — snapshot meta for the cache (#445). Best-effort:
  // rooms/groups render it as the header's semibold truncate; a miss just means the
  // rail overlay falls back to the channel name for a round-trip.
  paneTitle() {
    const el = document.querySelector("#chat-dropzone header .font-semibold.truncate")
    return el ? el.textContent.trim() : undefined
  },
  // Sidebar snapshots (#445): the aside's rendered HTML per rail target — "m"
  // (messenger) or "c:<channel id>". Kept on window so a settings round-trip
  // (LiveView remount) doesn't lose them. Display-only, same trust model as the
  // message cache: our own prior server render, sanitized on adoption.
  asideKey() {
    const m = location.pathname.match(/^\/channels\/([^\/]+)/)
    return m ? "c:" + m[1] : "m"
  },
  stashAside() {
    const aside = document.querySelector(".ed-root > aside")
    if (!aside) return
    const store = (window.__edAsideCache = window.__edAsideCache || new Map())
    // LRU, capped (#446 review): one aside render per rail target is small (tens
    // of KB), but "per visited channel, forever" needs a bound like MsgCache's.
    const k = this.asideKey()
    store.delete(k)
    store.set(k, aside.outerHTML)
    while (store.size > 12) store.delete(store.keys().next().value)
  },
  asidePaint(key, title) {
    this.asideRemove()
    const aside = document.querySelector(".ed-root > aside")
    // Mobile inside a chat the aside is hidden and the rail with it — nothing to cover.
    if (!aside || aside.offsetParent === null) return
    const r = aside.getBoundingClientRect()
    let ov = null
    const store = window.__edAsideCache
    const cached = store && store.get(key)
    if (cached) {
      try {
        // The snapshot is the aside ELEMENT (outerHTML) so its own layout classes
        // ride along; ids are stripped against duplicate-id collisions with the
        // real aside underneath, scripts defensively (template parsing never runs
        // them, adoption would).
        const tpl = document.createElement("template")
        tpl.innerHTML = cached
        const node = tpl.content.firstElementChild
        node.querySelectorAll("script").forEach((n) => n.remove())
        node.querySelectorAll("[id]").forEach((n) => n.removeAttribute("id"))
        node.removeAttribute("id")
        node.classList.remove("hidden")
        ov = node
      } catch (_e) {
        ov = null
      }
    }
    if (!ov) {
      ov = document.createElement("div")
      let rows = ""
      for (const w of [64, 48, 72, 40, 56, 66, 36, 58]) {
        rows += `<div class="ed-nav-skel__row"><span class="ed-nav-skel__av ed-skel-shimmer"></span><span class="ed-nav-skel__bubble ed-skel-shimmer" style="width:${w}%"></span></div>`
      }
      ov.innerHTML = `<div class="ed-aside-skel__head"><span class="ed-aside-skel__title"></span></div><div class="ed-aside-skel__body">${rows}</div>`
      ov.querySelector(".ed-aside-skel__title").textContent = title
    }
    ov.classList.add("ed-aside-skel")
    ov.setAttribute("aria-hidden", "true")
    ov.style.left = r.left + "px"
    ov.style.top = r.top + "px"
    ov.style.width = r.width + "px"
    ov.style.height = r.height + "px"
    document.body.appendChild(ov)
    this.asideOv = ov
    this.asideTimer = setTimeout(() => this.asideDismiss(), 15000)
  },
  // A panel, on screen before the server has heard about the tap (#521). Every one of
  // these is `:if={@assign}` — it does not exist in the DOM until the diff lands, and the
  // handlers put their queries on top of the round trip. Measured with the socket at
  // 500ms: the profile card first painted at 1191ms, the new-chat modal at 1067ms.
  //
  // Same contract as the thread and photo placeholders below: paint now, step aside when
  // the real one arrives, give up at once if the socket is down.
  panelSkel(kind) {
    this.panelDismiss()
    // WHICH of this shape are on screen right now, not how many: the placeholder waits for
    // one it has not seen. "None at all" would skip a modal opened from inside another
    // (add members from a group's card), and counting would miss the case where LiveView
    // replaces one with another and the count never moves (#573 review, two rounds).
    const before = new Set(document.querySelectorAll(this.panelReal(kind)))
    const ov = document.createElement("div")
    ov.className = "ed-skel-panel"
    ov.dataset.kind = kind
    ov.setAttribute("aria-hidden", "true")
    const rows =
      '<div class="ed-skel-panel__line ed-skel-shimmer"></div>' +
      '<div class="ed-skel-panel__line ed-skel-shimmer" style="width:70%"></div>' +
      '<div class="ed-skel-panel__line ed-skel-shimmer" style="width:45%"></div>'
    ov.innerHTML =
      '<div class="ed-skel-panel__scrim"></div>' +
      `<div class="ed-skel-panel__card ed-skel-panel__card--${kind}">${rows}</div>`
    // An anchored card lands where the real one will, through the same placement the
    // .Popover hook uses — a placeholder that appears somewhere else would only move the
    // jump, not remove it. Without that function there is nothing to place it by, and an
    // unplaced card stays `visibility: hidden`: better no placeholder at all than an
    // invisible one that answers nothing (#573 review — and #511 proposes loading the
    // interaction hooks lazily, which would make this reachable).
    if (kind === "popover" && !window.__edPlacePopover) return
    document.body.appendChild(ov)
    if (kind === "popover") window.__edPlacePopover(ov.querySelector(".ed-skel-panel__card"))
    this.panelOv = ov

    const t0 = performance.now()
    const poll = () => {
      if (this.panelOv !== ov) return
      const fresh = [...document.querySelectorAll(this.panelReal(kind))].some(
        (n) => !before.has(n),
      )
      if (fresh) this.panelDismiss()
      else if (!window.liveSocket?.isConnected()) this.panelDismiss()
      else if (performance.now() - t0 < 10_000) this.panelRaf = requestAnimationFrame(poll)
      else this.panelDismiss()
    }
    this.panelRaf = requestAnimationFrame(poll)
  },
  // What "the real one arrived" means for each shape. The modals share no class, so the
  // marker is the scrim every one of them renders.
  panelReal(kind) {
    return kind === "popover" ? ".ed-popover" : "[data-modal]"
  },
  panelDismiss() {
    const ov = this.panelOv
    cancelAnimationFrame(this.panelRaf)
    this.panelOv = null
    if (ov) ov.remove()
  },
  // A picked photo, on screen before the server has heard about it (#521). The staging
  // overlay is gated on `live_entries(...)` — the SERVER's list — so between closing the
  // picker and seeing a thumbnail there was a full round trip: measured at 1060ms with the
  // socket at 500ms, on a file that is already on the device.
  //
  // Same shape as the thread placeholder below: paint now, step aside when the real one
  // arrives. Two rules keep the handoff invisible rather than merely early:
  //
  //   * the placeholder carries the panel's chrome as empty blocks, so the box it draws is
  //     the box the real overlay draws (the e2e asserts the photo does not move);
  //   * it stays until the real preview has actually painted, and marks the overlay
  //     `--handoff` on the way out — the lone-photo grow-in exists to cover the decode, and
  //     replaying it under a photo already on screen would read as a flinch.
  //
  // Images only. A video or a document changes the panel's anatomy (film tile, file list),
  // and a placeholder that guesses that wrong would move things on handoff — worse than the
  // wait it saves.
  pickPreview(input) {
    const files = [...(input.files || [])]
    if (!files.length || !files.every((f) => /^image\//.test(f.type || ""))) return
    if (document.querySelector("[data-upload-preview]")) return
    // One composer, read once, used for both the cap and the object-URL store below: only
    // the main `attachment` channel reaches here, and it renders inside #composer (the
    // thread's own tray is `thread_attachment`, which this listener never sees).
    const composer = input.closest("#composer")
    // A pick past the staging cap is stopped dead by SendQueue (stopImmediatePropagation +
    // a cleared input, #193): nothing stages, so no overlay is ever coming and a
    // placeholder would be a photo that vanishes a few seconds later. Same number, read
    // from the same attribute.
    if (files.length > (Number(composer?.dataset.maxStaged) || 50)) return
    this.pickDismiss()

    // The object URL SendQueue would mint anyway, keyed the way it keys them: filling the
    // shared store here means one URL per file rather than two, its owner still revokes it,
    // and .ImgPreview reads back the very URL already decoded for this placeholder — so the
    // real preview paints from a warm cache.
    const store = composer?.edenVideoUrls
    const mine = []
    // Every picked file, not the first ten: the overlay shows all of them (albums of ten
    // are a SEND-side split), so a truncated placeholder would resize the panel on handoff.
    const tiles = files
      .map((f) => {
        const key = `${f.name}:${f.size}:${f.lastModified}`
        let url
        if (store) {
          if (!store.has(key)) store.set(key, URL.createObjectURL(f))
          url = store.get(key)
        } else {
          url = URL.createObjectURL(f)
          mine.push(url)
        }
        return `<div class="ed-compose__tile"><img class="ed-compose__img" src="${url}" alt=""></div>`
      })
      .join("")

    // album_cols/1, in the same order the server uses.
    const n = files.length
    const cols = n <= 3 ? n : n === 4 ? 2 : 3
    const grid = `ed-compose__grid ed-album--${cols}${n === 1 ? " ed-compose__grid--single" : ""}`

    const ov = document.createElement("div")
    ov.className = "ed-compose ed-compose-skel"
    ov.setAttribute("aria-hidden", "true")
    ov.innerHTML =
      '<div class="ed-compose__scrim"></div>' +
      '<div class="ed-compose__panel">' +
      '<div class="ed-compose__head"></div>' +
      `<div class="ed-compose__body"><div class="${grid}">${tiles}</div></div>` +
      '<div class="ed-compose__foot"></div>' +
      "</div>"
    // It looks modal, so it behaves modally: a tap lands HERE rather than falling through
    // to a message underneath (#569 review P1) — and dismisses, so a placeholder whose
    // answer never comes can never hold the screen hostage either.
    //
    // On release, not on press: the placeholder has to still be under the finger when the
    // press is delivered, or the press retargets to whatever was beneath and focuses it —
    // the fall-through this listener exists to stop.
    ov.addEventListener("pointerup", () => this.pickDismiss())
    document.body.appendChild(ov)
    this.pickOv = ov
    this.pickUrls = mine

    // Polled rather than observed: what ends the placeholder is an image finishing its
    // decode, which is not a DOM mutation.
    const t0 = performance.now()
    const poll = () => {
      if (this.pickOv !== ov) return
      const real = document.querySelector("[data-upload-preview]")
      const imgs = real ? [...real.querySelectorAll(".ed-compose__img")] : []
      // Settled, not decoded (#569 review): a file that says image/png and is not one ends
      // with `naturalWidth === 0` forever, and waiting for a decode that will never come
      // parked a dead placeholder over the live overlay for the whole ceiling. A src it has
      // finished with — succeeded or failed — is the real signal, and .ImgPreview sizes the
      // box before it assigns one either way, so this cannot hand off early.
      const painted = imgs.length > 0 && imgs.every((im) => !!im.getAttribute("src") && im.complete)
      if (painted) {
        real.classList.add("ed-compose--handoff")
        this.pickDismiss()
      } else if (!window.liveSocket?.isConnected()) {
        // The answer is not merely late, it is not coming: a pick made across a dropped
        // socket is lost with the cleared input, there is nothing to resume. Better an
        // empty screen than a modal that answers nothing.
        this.pickDismiss()
      } else if (performance.now() - t0 < 10_000) {
        // Ten seconds, not three (#569 review): what the placeholder waits for is one round
        // trip, not the upload, but on a bad mobile link that round trip can still be
        // seconds — and a slow link is exactly where the placeholder is worth the most.
        this.pickRaf = requestAnimationFrame(poll)
      } else {
        this.pickDismiss()
      }
    }
    this.pickRaf = requestAnimationFrame(poll)
  },
  pickDismiss() {
    const ov = this.pickOv
    cancelAnimationFrame(this.pickRaf)
    this.pickOv = null
    if (ov) ov.remove()
    // Off the page first, then let the URLs go — nothing can be asked to paint one that has
    // just been revoked. And only what this placeholder minted alone: a URL that went into
    // the shared store is revoked by its owner, and pulling it out from under .ImgPreview
    // would blank the preview it is about to hand over to.
    ;(this.pickUrls || []).forEach((u) => URL.revokeObjectURL(u))
    this.pickUrls = null
  },
  // The thread panel's shape, painted before the server has said anything. Same skeleton
  // parts as the sidebar overlay above — the same idea aimed at a different rectangle:
  // full screen on a phone, the 24rem column on desktop.
  // `waitFor` is what counts as "the real thing arrived": the thread panel by default, the
  // profile aside when this stands in for that (#521). Same column, same shimmer, one
  // painter — a second copy of it would drift.
  threadSkel(waitFor = ".ed-thread") {
    // A placeholder already up widens what it waits for instead of being ignored: tapping
    // the thread and then the profile (or the other way round) must not leave a shimmer
    // waiting for a panel that is no longer the one coming (#573 review).
    if (this.threadOv) {
      this.threadWaitFor = `${this.threadWaitFor}, ${waitFor}`
      // ...and the backstop counts from THIS request: the first one's clock would expire
      // mid-wait for a panel asked for seconds later (#573 review).
      clearTimeout(this.threadTimer)
      this.threadTimer = setTimeout(() => this.threadSkelDismiss(), 8000)
      return
    }
    this.threadWaitFor = waitFor
    const wide = window.matchMedia("(min-width: 768px)").matches
    const ov = document.createElement("div")
    let rows = ""
    for (const w of [72, 54, 66, 44, 60]) {
      rows += `<div class="ed-nav-skel__row"><span class="ed-nav-skel__av ed-skel-shimmer"></span><span class="ed-nav-skel__bubble ed-skel-shimmer" style="width:${w}%"></span></div>`
    }
    ov.innerHTML =
      '<div class="ed-aside-skel__head"><span class="ed-aside-skel__title"></span></div>' +
      `<div class="ed-aside-skel__body">${rows}</div>`
    ov.classList.add("ed-aside-skel", "ed-thread-skel")
    ov.setAttribute("aria-hidden", "true")

    if (wide) {
      const pane = document.getElementById("chat-dropzone") || document.body
      const r = pane.getBoundingClientRect()
      const w = 24 * parseFloat(getComputedStyle(document.documentElement).fontSize || "16")
      ov.style.left = r.right - w + "px"
      ov.style.top = r.top + "px"
      ov.style.width = w + "px"
      ov.style.height = r.height + "px"
    } else {
      ov.style.inset = "0"
    }
    document.body.appendChild(ov)
    this.threadOv = ov

    // Gone the moment the real panel exists — or after a bounded wait, so a reply that
    // never comes cannot leave a shimmer on screen.
    //
    // Scoped to the app root rather than the whole document (#567 review): the callback
    // used to run on every mutation anywhere on the page for as long as the placeholder
    // lived. Subtree is kept on purpose — both asides are direct children of the root
    // TODAY, and a version of this that depended on that would fail silently the day one
    // of them gains a wrapper, leaving a shimmer up until the backstop (#567 review, second
    // round). The callback is one selector query; the scope is what makes it cheap.
    const host = document.querySelector(".ed-root") || document.body
    this.threadMo = new MutationObserver(() => {
      if (document.querySelector(this.threadWaitFor)) this.threadSkelDismiss()
    })
    this.threadMo.observe(host, { childList: true, subtree: true })
    // F2: the socket is what decides, not only the clock. A pane asked for across a
    // dropped socket is not late, it is not coming — and the observer would never fire to
    // notice, because nothing mutates (#573 review). Checked on a coarse interval; the
    // arrival itself is still the observer's job, which is instant.
    this.threadPoll = setInterval(() => {
      if (!window.liveSocket?.isConnected()) this.threadSkelDismiss()
    }, 250)
    this.threadTimer = setTimeout(() => this.threadSkelDismiss(), 8000)
  },
  threadSkelDismiss() {
    const ov = this.threadOv
    if (!ov) return
    this.threadOv = null
    clearTimeout(this.threadTimer)
    clearInterval(this.threadPoll)
    this.threadMo && this.threadMo.disconnect()
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return ov.remove()
    ov.classList.add("ed-aside-skel--out")
    setTimeout(() => ov.remove(), 200)
  },
  asideDismiss() {
    const ov = this.asideOv
    if (!ov) return
    clearTimeout(this.asideTimer)
    this.asideOv = null
    this._railKey = null
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      ov.remove()
      return
    }
    ov.classList.add("ed-aside-skel--out")
    let done = false
    const fin = () => {
      if (!done) {
        done = true
        ov.remove()
      }
    }
    ov.addEventListener("transitionend", (ev) => {
      if (ev.target === ov && ev.propertyName === "opacity") fin()
    })
    setTimeout(fin, 300)
  },
  asideRemove() {
    clearTimeout(this.asideTimer)
    if (this.asideOv) {
      this.asideOv.remove()
      this.asideOv = null
    }
  },
  // The crash net for the replica draft: after a full-load fallback the direct
  // handoff in dismiss() never ran (the document died) — pick the stash up when
  // the chat finally shows. One-shot, 60s expiry, never clobbers an existing draft.
  rehydrateDraft(convId) {
    let d = null
    try { d = JSON.parse(sessionStorage.getItem("ed:navdraft")) } catch (_e) {}
    if (!d) return
    // Consume-or-expire, never clear on a mere mismatch (#444 review): a conv-shown
    // for a DIFFERENT chat (deep link, quick detour) must not kill a draft typed for
    // this one — it stays claimable by its own chat until the 60s expiry.
    if (Date.now() - (d.at || 0) > 60000) {
      try { sessionStorage.removeItem("ed:navdraft") } catch (_e) {}
      return
    }
    if (String(d.id) !== String(convId) || !d.text) return
    try { sessionStorage.removeItem("ed:navdraft") } catch (_e) {}
    const real = document.getElementById("composer-body")
    if (real && !real.value) {
      real.value = d.text
      real.dispatchEvent(new Event("input", { bubbles: true }))
    }
  },
  dismiss() {
    window.__edNavBusy = false
    if (!this.overlay) { this.target = null; return }
    clearTimeout(this.timer)
    this.timer = null
    this.target = null
    const ov = this.overlay
    this.overlay = null
    // The replica composer is a REAL input while the chat loads (#439) — carry the
    // typed draft and focus into the just-mounted composer so nothing is lost at
    // the handoff. Never clobber an existing draft (edit banners, rehydrated text).
    const ph = ov.querySelector("input.ed-nav-skel__ph")
    const real = ph && document.getElementById("composer-body")
    if (real) {
      if (ph.value && !real.value) {
        real.value = ph.value
        real.dispatchEvent(new Event("input", { bubbles: true }))
      }
      if (document.activeElement === ph) real.focus()
    }
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) { ov.remove(); return }
    const fade = () => {
      // Fade out on the next frame so the opacity transition actually runs.
      requestAnimationFrame(() => {
        ov.classList.add("ed-nav-skel--out")
        let done = false
        const fin = () => { if (!done) { done = true; ov.remove() } }
        // transitionend BUBBLES — a hovered cached row's transition would remove the
        // overlay mid-fade; filter for the overlay's own opacity (#433 review).
        ov.addEventListener("transitionend", (ev) => {
          if (ev.target === ov && ev.propertyName === "opacity") fin()
        })
        setTimeout(fin, 400) // fallback if the filtered event never fires
      })
    }
    // A fast server can land the real stream before the TG-push entrance finishes —
    // fading a half-slid card looks broken. Let the slide complete, then fade (#432).
    const push = ov.getAnimations?.().find((a) => a.animationName === "ed-nav-push")
    if (push && push.playState === "running") {
      let went = false
      const go = () => { if (!went) { went = true; fade() } }
      push.addEventListener?.("finish", go, { once: true })
      push.finished?.then(go).catch(go)
      setTimeout(go, 450)
    } else {
      fade()
    }
  },
  remove() {
    clearTimeout(this.timer)
    this.timer = null
    // Sweep ALL overlays, not just this.overlay: dismiss() nulls this.overlay while its node
    // is still fading, so a rapid re-nav must clear that lingering node too (never stack).
    document.querySelectorAll(".ed-nav-skel").forEach((n) => n.remove())
    this.overlay = null
  },
  destroyed() {
    this.threadSkelDismiss()
    this.panelDismiss()
    this.pickDismiss()
    this.onPick && document.removeEventListener("input", this.onPick, true)
    window.__edInstantNavReady = false
    document.removeEventListener("click", this.onClick, true)
    window.__edNavBusy = false
    this.asideRemove()
    window.removeEventListener("ed:conv-shown", this.onShown)
    window.removeEventListener("phx:page-loading-stop", this.onLoadStop)
    window.removeEventListener("popstate", this.onPop)
    document.removeEventListener("touchstart", this.onTouchStart)
    document.removeEventListener("touchstart", this.onTapStart)
    document.removeEventListener("touchmove", this.onTapMove)
    document.removeEventListener("touchcancel", this.onTapCancel)
    document.removeEventListener("touchstart", this.onKbStart)
    document.removeEventListener("touchmove", this.onKbMove)
    this._untrackSwipe() // move/end may still be attached mid-gesture
    clearTimeout(this._backingBelt)
    document.removeEventListener("visibilitychange", this.onVisibility)
    window.removeEventListener("ed:suspend", this.onSuspend)
    this.remove()
  },
}
