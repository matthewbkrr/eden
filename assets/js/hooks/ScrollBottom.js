// How long a jumped-to message stays lit, from the stylesheet that animates it
// (`--ed-hold-focus`). Two timers used to carry the number themselves and had already
// drifted apart — 2200 here, 1600 in the lightbox's "show in chat" — so the lightbox's
// flash went out by a frame in the middle of its own fade (#517). Read once: the token is
// on :root and cannot change without a stylesheet reload.
// Any JS timer that clocks a CSS animation reads its duration from the stylesheet rather
// than carrying a copy (#517). Copies drift: `--ed-hold-focus` already had a 1600 and a
// 2200 in two different hooks for one 2200ms animation.
const durs = new Map()
window.__edMs = (name, fallback) => {
  // `null`, not `0`, as the "not read yet" sentinel — and `Number.isFinite`, not `!n`, to
  // decide the fallback: `0s` is a legitimate value (no motion at all, the natural way to
  // switch an animation off), and both of the obvious shortcuts would quietly turn it into
  // the default — the opposite of what was asked (#571 review).
  if (!durs.has(name)) {
    // Unit-aware: `2.2s` and `2200ms` are the same duration, and a bare parseFloat would
    // turn the first into a two-millisecond flash. The stylesheet is free to write either.
    const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
    const n = parseFloat(raw)
    durs.set(name, !Number.isFinite(n) ? fallback : /ms$/.test(raw) ? n : n * 1000)
  }
  return durs.get(name)
}
let holdMs = null
window.__edFocusHold = () => {
  if (holdMs === null) holdMs = window.__edMs("--ed-hold-focus", 2200)
  return holdMs
}
export default {
  mounted() {
    // Remember which conversation we're pinned to; a switch is a patch (no
    // remount), so updated() must re-pin instantly rather than mounted (#109).
    this.convId = this.el.dataset.conversationId
    // Permalink / "jump to root": the server marks a main-stream focus target via
    // data-focus-* (and, for the long-history case, loads a window AROUND it so it's
    // even IN the DOM — #jump). On a fresh load, scroll to that target instead of the
    // bottom; otherwise land at the latest as usual.
    const focus = this.checkFocus()
    if (focus) this.focusOn(focus)
    else this.toBottom()
    // A fresh mount = list→chat (or a deep-link): the real stream is in the DOM now.
    this.announceShown()
    // Thread-reply targets (`thread-<id>`, a different container with no
    // scroll-to-bottom of its own) arrive as an event rather than via data-focus-*.
    this.handleEvent("focus_message", ({ domId }) => this.focusOn(domId))
    // Runs for nodes added AFTER mount only — the initial list is already
    // in the DOM when the observer starts, so it never animates (no
    // page-load choreography). Two jobs:
    //   1. Atomic swap: when MY real row streams in (data-client-id, in
    //      #messages), drop its optimistic twin from #pending in this same
    //      microtask — before paint. The list never holds both, so it can't
    //      grow-then-shrink by a row (the "whole line dips then snaps up"
    //      jerk). Both text AND media rows carry data-client-id now (#95: the
    //      id rides the fire-and-forget media_sending push, not the upload
    //      form), so one precise id-keyed swap covers both — no heuristic.
    //   2. Rise-in for everyone else's messages.
    this.riser = new MutationObserver((muts) => {
      // Which optimistic-node container this scroller owns (#142): the main
      // pane uses #pending-messages; the thread panel passes data-pending-id.
      const pendingId = this.el.dataset.pendingId || "pending-messages"
      // A conversation switch / older-page load streams DOZENS of rows in one patch —
      // that's history materializing, not messages arriving; rising-in the whole list
      // makes the entry twitch. Worst over the instant-nav cache: the SAME rows are
      // already on screen, so the handoff visibly re-animates identical content (#427
      // polish). Count the batch first — bulk keeps the twin-swap work below but skips
      // the enter animation; live single arrivals still rise in.
      let batch = 0
      for (const mut of muts) {
        for (const node of mut.addedNodes) {
          if (node.nodeType !== 1) continue
          if (node.matches?.(".ed-msg, .ed-flat") || node.querySelector?.(".ed-msg, .ed-flat")) batch++
        }
      }
      const bulk = batch >= 4
      for (const mut of muts) {
        for (const node of mut.addedNodes) {
          if (node.nodeType !== 1) continue
          const row = node.matches?.(".ed-msg, .ed-flat") ? node
            : node.querySelector?.(".ed-msg, .ed-flat")
          if (!row) continue
          // An optimistic node sitting in #pending already animated itself
          // (addOptimistic / addOptimisticMedia); never re-animate it.
          const inPending = !!row.closest("#" + pendingId)
          if (inPending) continue
          if (row.dataset.clientId) {
            // My own message just streamed in. A media send still renders an
            // optimistic twin (local preview + progress ring) — drop it in this
            // same microtask, BEFORE paint, and don't animate: it already rose
            // in, so a second animation would double up. Text sends render no
            // optimistic node anymore, so there's no twin → fall through and
            // rise in like a thread reply (one smooth transition, shared by the
            // whole list — DMs, rooms, and threads alike).
            const twin = document.getElementById(pendingId)
              ?.querySelector(`[data-client-id="${row.dataset.clientId}"]`)
            if (twin) {
              // Carry the local poster frame(s) onto the real <video>(s) so a
              // just-sent clip shows its frame while /files loads, instead of
              // flashing gray/"unsupported" until it decodes (#130). The server
              // poster ({:thumbnail_ready}) then takes over via morphdom. Only
              // when the poster↔video count is unambiguous (a lone clip or an
              // all-video album), so a mixed album never lands a photo's frame
              // on a video.
              const posters = [...twin.querySelectorAll("img")].map((i) => i.src)
              const vids = [...row.querySelectorAll("video")]
              if (vids.length && posters.length === vids.length) {
                vids.forEach((v, i) => {
                  if (!v.getAttribute("poster")) v.setAttribute("poster", posters[i])
                })
              }
              // Same idea for PHOTOS: carry the local snapshot onto the real <img>(s)
              // (BEFORE paint) so a just-sent photo shows instantly instead of flashing
              // the cobalt bubble + "Photo" alt while /files loads — the thumbnail isn't
              // generated yet, so the real src is the full original (a slow fetch).
              // morphdom swaps to the server thumb on {:thumbnail_ready}, keeping this
              // frame until the thumb decodes. Skip avatar/header imgs (flat rooms).
              const realImgs = [...row.querySelectorAll("img")].filter(
                (i) => !i.closest(".ed-avatar, .ed-flat__gutter, .ed-flat__head"),
              )
              if (realImgs.length && realImgs.length === posters.length) {
                realImgs.forEach((img, i) => {
                  if (posters[i]?.startsWith("data:")) img.src = posters[i]
                })
              }
              // A twin left a merged file group — re-fuse the remaining optimistic rows so
              // the shrinking in-flight bubble stays one bubble (its owner is the SendQueue
              // hook, which listens for this).
              // Motion handoff (#439): the twin may be mid rise-in (the 0.28s
              // ed-msg--sent float-up) when the ack lands — dropping it and showing
              // the real row at rest popped the bubble to its final spot (the very
              // jerk that once forced a bare fade). Carry the CURRENT transform +
              // opacity onto the real row and glide them out, so rapid sends each
              // finish their own motion seamlessly across the swap.
              const cs = getComputedStyle(twin)
              const noMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
              if (!noMotion && (cs.transform !== "none" || parseFloat(cs.opacity) < 1)) {
                row.style.transform = cs.transform === "none" ? "" : cs.transform
                row.style.opacity = cs.opacity
                row.style.transition = "transform 0.18s var(--ed-ease), opacity 0.18s var(--ed-ease)"
                requestAnimationFrame(() => {
                  row.style.transform = "translateY(0)"
                  row.style.opacity = "1"
                })
                setTimeout(() => {
                  row.style.transform = ""
                  row.style.opacity = ""
                  row.style.transition = ""
                }, 220)
              }
              const gid = twin.dataset.groupId
              twin.remove()
              if (gid) window.dispatchEvent(new CustomEvent("ed:regroup", { detail: { groupId: gid } }))
              continue
            }
          }
          if (!bulk) {
            row.classList.add("ed-msg--enter")
            setTimeout(() => row.classList.remove("ed-msg--enter"), 200)
          }
        }
      }
    })
    this.riser.observe(this.el, { childList: true, subtree: true })
    // Auto-load older messages on scroll near the top (#113), replacing the
    // "Load older" button. updated() preserves the scroll position across
    // the prepend so the list doesn't jump.
    // Track "at the bottom" on every scroll so the ResizeObserver below can
    // re-pin after a viewport shrink. Start pinned — mount() just scrolled down.
    this.pinned = true
    // `follow` is a STICKY "stay at the bottom" intent: unlike `pinned` (which
    // beforeUpdate recomputes to false the instant content grows taller than the
    // viewport), it survives content growing below — a late-decoding image, the
    // real row swapping in for its optimistic twin. Cleared only when the user
    // scrolls UP. The image-load re-pin honors it so a just-sent photo lands fully
    // in view even when its grow exceeds the pinned threshold (#104).
    this.follow = true
    this.lastTop = this.el.scrollTop
    this.onScroll = () => {
      const top = this.el.scrollTop
      this.pinned = this.el.scrollHeight - top - this.el.clientHeight < 48
      if (this.pinned) this.follow = true
      else if (top < this.lastTop - 2) this.follow = false
      this.lastTop = top
      this.maybeLoadOlder()
    }
    this.el.addEventListener("scroll", this.onScroll, { passive: true })
    // The reply bar / typing row live OUTSIDE #message-scroll (in the composer),
    // so their appearing never triggers this hook's updated(). A ResizeObserver
    // catches the viewport shrinking and keeps the last message visible above the
    // composer instead of letting it hide behind the reply bar.
    this.ro = new ResizeObserver(() => {
      if ((this.pinned || this.sticky()) && !this._focusing()) this.toBottom(false)
    })
    this.ro.observe(this.el)
    // After a send the user always wants their message at the bottom, but the send
    // settles in stages (optimistic node, modal→bar composer resize, the real row,
    // late media decode) — each can leave it short, and `pinned`/`follow` are too
    // fragile across those transients (esp. Firefox) (#104). So when SendQueue
    // signals a send, glue to the bottom for a short window, then stop. This is
    // send-only, so it never yanks someone scrolled up reading history.
    this.onAfterSend = () => {
      // ed:after-send is dispatched ONLY by the main composer (SendQueue); the open
      // thread panel shares this hook but must NOT stick on a main-stream send (#187
      // review: a main send was yanking a scrolled-up thread to its bottom). The thread
      // composer scrolls its own pane separately, never via this event.
      if (this.el.id !== "message-scroll") return
      this.stickUntil = performance.now() + 1200
      // Pin SYNCHRONOUSLY first (#351) — the optimistic node was just appended in this same
      // tick, so an immediate toBottom lands it at the bottom with NO one-frame gap where it
      // sits below the fold and then jumps up.
      this.toBottom(false)
      // Then let the settle stages announce themselves (#519). This used to be a
      // requestAnimationFrame loop running for the whole 1200ms window: on a 565-row feed
      // that is ~72 read-scrollHeight/write-scrollTop pairs, each a synchronous layout of
      // the entire list, landing exactly while media decodes and the composer resizes.
      // Measured at 79 `scrollHeight` reads for one send.
      //
      // Every stage it was covering CHANGES A HEIGHT — the composer resizing, the real row
      // replacing the optimistic one, a photo decoding — and two ResizeObservers already
      // watch those heights. `sticky()` simply lets them pin during the window, so the same
      // work happens on the three or four frames where something actually moved.
      // A settle that changes no observed height (a font swap, a late attribute) would
      // otherwise be missed, so a few coarse re-pins remain as a backstop. Three, not
      // seventy-two.
      //
      // Held as a list (#556 review): a second send inside the window overwrote the ids of
      // the first one's timers and left them running, and `destroyed()` could then not
      // clear what it could no longer name — a pin firing at a feed that had been
      // navigated away from.
      ;(this._stickTimers || []).forEach(clearTimeout)
      this._stickTimers = [120, 420, 900].map((ms) =>
        setTimeout(() => {
          if (this.sticky() && !this._focusing()) this.toBottom(false)
        }, ms)
      )
    }
    window.addEventListener("ed:after-send", this.onAfterSend)
    // A just-sent (or received) photo/video/file row grows AFTER we scrolled — its
    // media decodes late (no server dimensions yet) or its card lays out a frame
    // later — leaving it below the fold (#104). The earlier per-image `load` re-pin
    // was timing-fragile (worked in Chrome, missed Firefox; never covered files).
    // Instead observe the message CONTENT's height and re-pin on ANY growth while
    // `follow` (sticky-bottom) holds — covers images, video posters, and file cards
    // uniformly, on every browser. The separator churn (#83) nets to zero before
    // this fires (the MutationObserver re-adds it in the same task), so it doesn't
    // trigger here.
    this.content = this.el.querySelector("#messages")
    if (this.content) {
      this.contentRo = new ResizeObserver(() => {
        if ((this.follow || this.sticky()) && !this._focusing()) this.toBottom(false)
      })
      this.contentRo.observe(this.content)
    }
  },
  maybeLoadOlder() {
    if (this.loadingMore || this.el.dataset.hasMore !== "true") return
    if (this.el.scrollTop > 300) return
    this.loadingMore = true
    this.prevHeight = this.el.scrollHeight
    this.pushEvent("load_more", {})
  },
  // True while a jump highlight is in its dwell window — used to suppress every
  // auto-scroll-to-bottom path (mount, conv re-pin, ResizeObservers) so they can't
  // yank the view off the message we just jumped to.
  _focusing() {
    return this.focusUntil && Date.now() < this.focusUntil
  },
  // The server flags a main-stream jump target on #message-scroll as
  // data-focus-id (+ a monotonic data-focus-nonce so re-jumping the SAME message
  // re-fires). Returns the dom id to focus, or null when there's nothing new.
  checkFocus() {
    const nonce = this.el.dataset.focusNonce
    const id = this.el.dataset.focusId
    if (!id || nonce === this.lastFocusNonce) return null
    this.lastFocusNonce = nonce
    return "messages-" + id
  },
  // Scroll a message into view and briefly highlight it (permalink / jump-to-root /
  // tapped quote). Robust on a long, busy chat where the server just loaded a window
  // AROUND an older target:
  //   - retry until the row is actually in the DOM,
  //   - stop the auto-follow so a late image-decode can't yank back to the bottom,
  //   - center INSTANTLY (a far jump teleports — a smooth scroll across thousands of
  //     px onto still-settling layout was landing in "random" spots), then
  //   - HOLD it centered for a short window: re-center every frame while images in the
  //     fresh window decode and grow (each grow shifts the target; holding pins it),
  //   - keep a longer dwell so updated() can re-apply the highlight class a re-render
  //     would otherwise strip.
  focusOn(domId) {
    this.follow = false
    this.pinned = false
    this.focusId = domId
    let tries = 0
    const go = () => {
      const el = document.getElementById(domId)
      if (!el) {
        if (tries++ < 12) return setTimeout(go, 50)
        this.focusId = null
        return this.pushEvent("message_unavailable")
      }
      el.classList.add("ed-msg--focus")
      this.focusUntil = Date.now() + window.__edFocusHold()
      const holdUntil = Date.now() + 800
      const hold = () => {
        const node = document.getElementById(domId)
        if (!node) return
        node.scrollIntoView({ block: "center", behavior: "auto" })
        if (Date.now() < holdUntil) {
          requestAnimationFrame(hold)
        } else if (this.el.contains(node)) {
          // A jump scrolls programmatically, so no 'scroll' event fires to kick
          // maybeLoadOlder — the top "load older" affordance sat visible-but-idle, and
          // the target could be stranded at the very top of a deep-jump window (#188).
          // Trigger one load now; updated()'s prepend path keeps the target put and the
          // continuation below fills until ~300px of older context sits above it.
          // Guard: focus_message reaches BOTH the main + thread .ScrollBottom hooks, but
          // only the pane that actually holds the target should load — else a jump to a
          // thread reply fires a spurious main-stream load (#188 review).
          this.maybeLoadOlder()
        }
      }
      hold()
      setTimeout(() => {
        this.focusUntil = 0
        this.focusId = null
        document.getElementById(domId)?.classList.remove("ed-msg--focus")
      }, window.__edFocusHold())
    }
    requestAnimationFrame(go)
  },
  beforeUpdate() {
    this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
    // Snapshot the message-row count so updated() only re-pins on a genuinely NEW
    // message — never on an incidental re-render (typing here or in a thread, a
    // reaction, a read tick, a reply-count footer). Re-pinning on every patch made
    // the list chase the transient separator height and twitch on every keystroke
    // (#104). Sent messages scroll via SendQueue + the image-load re-pin, not here.
    this.prevCount = this.el.querySelectorAll(".ed-msg, .ed-flat").length
  },
  // A new message while pinned: glide the list up to make room so it
  // eases in from the bottom instead of snapping (the "jerk"). Mount
  // stays instant — no page-load scroll choreography.
  updated() {
    // Re-apply the jump highlight if this patch re-rendered the focused row and
    // morphdom stripped the JS-added class (active rooms re-render rows often). A
    // gone/other-conversation row resolves to null → harmless no-op.
    if (this._focusing()) {
      document.getElementById(this.focusId)?.classList.add("ed-msg--focus")
    }
    // A jump target landed in this patch (the server loaded a window AROUND an older
    // message and bumped data-focus-nonce): scroll to it instead of re-pinning to the
    // bottom. Checked before the conv-switch/re-pin paths so neither fights the jump.
    const focus = this.checkFocus()
    if (focus) {
      this.convId = this.el.dataset.conversationId
      this.loadingMore = false
      this.focusOn(focus)
      return
    }
    // Switched conversation (a patch, so mounted() didn't re-run): jump
    // INSTANTLY to the latest message instead of smooth-scrolling from the
    // previous chat's scroll position — that glide was the #109 bug. Checked
    // FIRST and abandons any in-flight older-load from the previous chat, so
    // its restore math never runs against the new conversation (review).
    if (this.el.dataset.conversationId !== this.convId) {
      this.convId = this.el.dataset.conversationId
      this.loadingMore = false
      this.toBottom(false)
      this.announceShown()
      return
    }
    // An older-page prepend (#113): keep the same content under the viewport
    // by adding the prepended height to scrollTop. Only when rows were
    // actually added — the final empty page removes the spinner instead, so
    // the height SHRINKS; don't yank the viewport up then (review).
    if (this.loadingMore) {
      // Restore in a rAF so the prepended height is measured AFTER the DateRail
      // hook (#83) has injected the older days' separators — otherwise their
      // height isn't in `delta` and the viewport jumps by it. rAF runs after all
      // hooks' updated() in this patch, before paint, so there's no flash.
      //
      // The flag is released INSIDE that frame, not before it (#519). Clearing it here
      // let the next scroll event re-arm `maybeLoadOlder` while this compensation was
      // still pending — and that re-arm overwrites `prevHeight` with the ALREADY GROWN
      // height, so the pending delta computes to zero and a whole page of history goes
      // uncompensated. Measured on the stand: two pages prepended (+3249 then +3477),
      // only the second one compensated, the reader thrown 3249px off.
      requestAnimationFrame(() => {
        const delta = this.el.scrollHeight - this.prevHeight
        this.loadingMore = false
        if (delta > 0) this.el.scrollTop += delta
        // Keep filling while a jump is still settling and the top affordance would
        // otherwise sit visible-but-idle (#188): self-terminates once ~300px of older
        // context is above the target (scrollTop > 300) or there's no more — so it never
        // runs away when someone just parks near the top during normal reading.
        if (
          this._focusing() &&
          this.el.scrollTop <= 300 &&
          this.el.dataset.hasMore === "true"
        ) {
          this.maybeLoadOlder()
        }
      })
      return
    }
    // Only re-pin when a new message actually arrived (row count grew). Incidental
    // patches leave the count unchanged and must NOT move the list (#104). Never
    // while a jump is settling — that would steal the view back to the bottom.
    if (
      this.pinned &&
      !this._focusing() &&
      this.el.querySelectorAll(".ed-msg, .ed-flat").length > this.prevCount
    ) {
      this.toBottom(true)
    }
  },
  destroyed() {
    this.riser && this.riser.disconnect()
    this.ro && this.ro.disconnect()
    this.contentRo && this.contentRo.disconnect()
    this.onScroll && this.el.removeEventListener("scroll", this.onScroll)
    this.onAfterSend && window.removeEventListener("ed:after-send", this.onAfterSend)
    // The backstop re-pins outlive a fast navigation otherwise, and would scroll a feed
    // that belongs to another conversation by then.
    ;(this._stickTimers || []).forEach(clearTimeout)
  },
  // Inside the short window a send glues the feed to the bottom (#519).
  sticky() { return performance.now() < (this.stickUntil || 0) },
  toBottom(smooth) {
    const motion =
      smooth && !window.matchMedia("(prefers-reduced-motion: reduce)").matches
        ? "smooth"
        : "auto"
    this.el.scrollTo({ top: this.el.scrollHeight, behavior: motion })
  },
  // Tell the .InstantNav hook the real stream for this conversation is now in the
  // DOM, so it can fade its instant-navigation skeleton. Fired whenever we (re)pin
  // to a conversation — a fresh mount (list→chat) or a switch (chat→chat).
  announceShown() {
    const id = this.el.dataset.conversationId
    if (id) window.dispatchEvent(new CustomEvent("ed:conv-shown", { detail: { id } }))
  }
}
