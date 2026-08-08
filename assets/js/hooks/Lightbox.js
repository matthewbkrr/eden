// In-app image viewer: click a photo to open it full-screen in a single
// shared overlay (close on backdrop click or Esc). When the tile belongs
// to an album (data-gallery), the overlay pages through that album's
// photos with on-screen arrows and ←/→. Cmd/Ctrl/Shift/middle click fall
// through to the normal "open original in a new tab".
// #106/#383/R186: inside a message a double-click reacts, but the FIRST click opens the
// lightbox immediately (no 250ms disambiguation lag) — a landing second click closes it so
// the react wins. Photos OUTSIDE a message row (the profile gallery) never react, so they
// just open on click.
// One global overlay nav-close guard, registered ONCE at bundle load: this colocated module's
// top-level runs when app.js imports it, regardless of whether a photo is on the page, so the
// listener is wired without a per-hook mounted() call (and without duplicating it in the
// VideoExpand script — #399 review). On any server-driven navigation, dismiss an open
// Lightbox/VideoExpand so a torn-down owning hook can't leave the overlay visible with
// body.overflow:hidden (scroll locked) on the next page (#380/R187). Both overlays are
// singletons on <body>, outside the LiveView root, so their Esc/backdrop close() never fires on
// navigation. The window flag makes a re-import (dev HMR) idempotent; the handler queries both
// overlays by id, so wiring it here once covers video too. No-op unless an overlay is open.
if (!window.__edOverlayNavGuard) {
  window.__edOverlayNavGuard = true
  window.addEventListener("phx:page-loading-start", () => {
    const lb = document.getElementById("ed-lightbox")
    if (lb && lb.open) lb.__close && lb.__close()
    const vm = document.getElementById("ed-video-modal")
    if (vm && vm.classList.contains("ed-video-modal--open")) vm.__close && vm.__close()
  })
}
export default {
  mounted() {
    const inMsg = !!this.el.closest(".ed-msg, .ed-flat")
    this.el.addEventListener("click", (e) => {
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return
      e.preventDefault()
      // Open the lightbox IMMEDIATELY on the first click — no 250ms wait (#383/R186). A
      // double-click (to react) arrives as a second click; the react is handled by
      // .ContextMenu, so here we just close the lightbox the first click opened — the react
      // wins. (A profile photo has no dbl-react, so it always opens on click.)
      if (inMsg && e.detail > 1) {
        const box = document.getElementById("ed-lightbox")
        if (box?.open) box.__close?.()
        return
      }
      this.openLightbox()
    })
  },
  openLightbox() {
    const gallery = this.el.dataset.gallery
    const tiles = gallery
      ? [...document.querySelectorAll(`[data-gallery="${gallery}"]`)]
      : [this.el]
    // The reel (#466): start with the album's own tiles so the viewer paints
    // instantly, then widen to the WHOLE conversation when the server page
    // lands (oldest→newest, matching the strip's reading order).
    let items = tiles.map((t) => ({
      id: Number((t.dataset.full || "").split("/").pop()),
      kind: "image",
      full: t.dataset.full,
      // The tile's own preview URL, from the server (#552). Reading `currentSrc` first made
      // the viewer's first frame depend on whether the tile had finished painting: a tap on
      // a photo that had just scrolled into view got `""`, fell through to the original, and
      // opened on a blank frame until several megabytes arrived.
      thumb:
        t.dataset.thumb ||
        t.querySelector("img")?.currentSrc ||
        t.querySelector("img")?.src ||
        t.dataset.full,
      msg: t.dataset.msg,
      who: t.dataset.who,
      at: t.dataset.at,
      link: t.dataset.link,
      mine: t.dataset.mine,
    }))
    let i = Math.max(0, tiles.indexOf(this.el))

    const box = this.box()
    // The box is a singleton shared by every tile hook — the one that opened it
    // owns the action pushes for as long as it's up (#465).
    box.__hook = this
    // ...and owns its own deferred work (#552). Every `items`/`i` below belongs to THIS
    // open; a reply or a settle timer from a previous one would repaint the box with the
    // previous photo. Close and reopen inside one round-trip and that is exactly what
    // happened — the reported "tapping a photo opens a different one". A monotonic stamp
    // makes stale continuations no-ops instead of racing the live ones.
    const gen = (box.__gen = (box.__gen || 0) + 1)
    const live = () => box.__gen === gen
    const count = box.querySelector(".ed-lightbox__count")
    const show = (n, dir) => {
      const prev = i
      // Modulo the REEL, not the album (#466): the reel widens to the whole
      // conversation after the first page, and wrapping against the album's
      // length threw the index back to the start on every paint — which then
      // re-triggered the older-page fetch until the entire dialog was loaded.
      i = (n + items.length) % items.length
      // Paging resets the zoom — carrying a 2.5x pan onto a different photo
      // would disorient (#469).
      box.__zoomReset()
      // A key/arrow/thumb move GLIDES the track (a finger drag has already
      // moved it and commits itself). The old micro-fade was invisible in
      // practice: it raced the decode-hide and only travelled 18px, so paging
      // read as a hard cut (user report).
      const slide =
        dir && prev !== i && !box.__dragging &&
        !matchMedia("(prefers-reduced-motion: reduce)").matches
      const paint = (k, it) => box.__paintSlot(k, it)
      const settle = () => {
        paint(0, items[i - 1])
        paint(1, items[i])
        paint(2, items[i + 1])
        box.__trackTo(0, false)
      }
      if (slide) {
        paint(1, items[prev])
        paint(dir > 0 ? 2 : 0, items[i])
        box.__trackTo(0, false)
        const w = box.__stageW()
        requestAnimationFrame(() => box.__trackTo(dir > 0 ? -w : w, true))
        setTimeout(() => live() && settle(), 280)
      } else {
        settle()
      }
      const it = items[i]
      box.__src = it.full
      // Position in the reel (audit P1): the phone pages by swipe with no
      // arrows — without this an album looks like a lone photo.
      // Position in the WHOLE conversation once the reel is anchored at its
      // newest end (the first page always is) — the reel loads lazily
      // backwards, so without the server's total this could only say "60 of
      // 60+". An album-only fallback counts locally. Hidden for a lone photo.
      const total = (box.__anchored && box.__total) || items.length
      const pos = box.__anchored && box.__total ? total - (items.length - 1 - i) : i + 1
      count.textContent = total > 1 ? `${pos} ${box.__of} ${total}` : ""
      // Chrome for THIS photo: who sent it and when, plus the action set the
      // menu offers (own messages add "delete for everyone").
      box.__meta = it
      box.__renderChrome()
      box.__renderStrip(i)
      // The neighbours are already fetched: slots 0 and 2 hold exactly items[i-1] and
      // items[i+1] and were painted three lines up. The extra `new Image()` pair here
      // requested the same two originals a second time (#552).
      // Approaching the older end pulls the next page in (the reel loads
      // lazily backwards, TG-style).
      if (i <= 2 && box.__more && !box.__loading) loadOlder()
    }
    box.__show = show
    box.__step = (d) => show(i + d, d)
    box.__goto = (n) => show(n, n > i ? 1 : -1)
    box.__items = () => items
    box.__index = () => i

    // Pull one page of older conversation media and PREPEND it (the API answers
    // newest-first; the reel reads oldest→newest).
    const loadOlder = () => {
      if (box.__loading || !box.__more) return
      box.__loading = true
      const before = items[0] && items[0].id
      this.pushEvent("lightbox_media", { before }, (reply) => {
        if (!live()) return
        box.__loading = false
        const page = (reply && reply.items) || []
        box.__more = !!(reply && reply.more)
        const known = new Set(items.map((x) => x.id))
        const older = page.filter((x) => !known.has(x.id)).reverse()
        if (!older.length) return
        items = older.concat(items)
        i += older.length
        box.__renderStrip(i)
        show(i)
      })
    }
    box.__loadOlder = loadOlder

    // The first page brings the newest slice of the conversation; the album the
    // viewer opened from sits inside it, so the reel is spliced AROUND the
    // current photo. Paging stays disabled until it lands — otherwise the very
    // first show() fires a fetch against a leftover cursor from the previous
    // open and two replies race to rewrite the reel (probe evidence).
    box.__more = false
    box.__loading = true
    box.__anchored = false
    box.__total = 0
    this.pushEvent("lightbox_media", {}, (reply) => {
      if (!live()) return
      box.__loading = false
      box.__more = !!(reply && reply.more)
      const page = ((reply && reply.items) || []).slice().reverse()
      const here = items[i] && items[i].id
      const at = page.length ? page.findIndex((x) => x.id === here) : -1
      // Opened photo older than this page → keep the album reel; older paging
      // still works from its own cursor.
      box.__total = reply && reply.total
      if (at === -1) return
      box.__anchored = true
      items = page
      i = at
      box.classList.toggle("ed-lightbox--gallery", items.length > 1)
      show(i)
    })
    // Reserve the strip's band NOW rather than when the reel lands (#552): a lone photo
    // opened the stage at full height and the server's reply then took 63px back, so the
    // photo visibly dropped a moment after it appeared. Anything sent in a conversation
    // can grow a reel, so assume one; the reply below takes the band back for the one
    // case that cannot (the profile gallery, which has no message behind it).
    box.classList.toggle("ed-lightbox--gallery", items.length > 1 || !!items[i]?.msg)
    show(i)

    // Native <dialog> (audit P1): showModal() brings the top layer, focus
    // trap, Esc (via cancel) and focus RETURN to the opening tile for free —
    // the old div overlay was a phantom for keyboard and screen readers.
    // Reopening during the 150ms close fade must CANCEL that close — its
    // delayed teardown would fire box.close() on the fresh view (#470 review).
    clearTimeout(box.__closeTimer)
    box.__closing = false
    box.classList.remove("ed-lightbox--out")
    if (!box.open) {
      box.showModal()
      // The native shell owns the status bar and cannot see into this dialog; the viewer
      // is a near-black scrim in either theme, so it says so and the bar follows (#518).
      window.dispatchEvent(new CustomEvent("ed:lightbox", { detail: { open: true } }))
    }
    // Take focus off the back arrow (#554). `showModal()` hands it to the first focusable
    // child, and WebKit counts that as focus-visible: on an iPhone the viewer opened with a
    // ring drawn around a control nobody had touched. The container is the right holder
    // anyway — a screen reader announces the modal, and Tab starts from the top of it.
    box.focus({ preventScroll: true })
    // The stage has a width only now that the dialog is in the top layer; the track was
    // positioned a moment ago against a fallback. Re-centre on the real measurement.
    box.__forgetW()
    box.__trackTo(0, false)
    // Start each open with a clean gesture flag — a stale `__swiped` from a
    // prior swipe would otherwise suppress the first tap (e.g. the X) (#96).
    box.__swiped = false
    box.__dismiss = false
    box.__dismissReset()
    document.body.style.overflow = "hidden"
    document.addEventListener("keydown", box.__onKey)
  },
  box() {
    let box = document.getElementById("ed-lightbox")
    if (box) return box

    // A native <dialog> (audit P1): top layer, focus trap, focus return and
    // Esc semantics come from the platform instead of hand-rolled listeners.
    box = document.createElement("dialog")
    box.id = "ed-lightbox"
    box.className = "ed-lightbox"
    // Heroicon chevrons (mini) sit dead-center in the round buttons —
    // the text ‹/› glyphs rendered off-center.
    const chevron = (d) =>
      `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="${d}" clip-rule="evenodd"/></svg>`
    const left = "M11.78 5.22a.75.75 0 0 1 0 1.06L8.06 10l3.72 3.72a.75.75 0 1 1-1.06 1.06l-4.25-4.25a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Z"
    const right = "M8.22 5.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L11.94 10 8.22 6.28a.75.75 0 0 1 0-1.06Z"
    const xmark = "M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z"
    // Localized labels from #message-scroll (gettext is unreachable here).
    const lbl = document.getElementById("message-scroll")?.dataset || {}
    box.__of = lbl.lbOf || "/"
    // openLightbox() lives in another scope than these labels — hand it the
    // one string show() needs for the frame's accessible name.
    box.__viewer = lbl.lbViewer || "Photo"
    // The dialog's accessible name — a screen reader announces the modal (audit P1).
    box.setAttribute("aria-label", lbl.lbViewer || "Photo")
    // Focusable so the dialog can hold its own focus (#554) — see the `focus()` next to
    // `showModal()`. `autofocus` on the dialog is specified to do this and is NOT honoured
    // here (measured: focus still landed on the back arrow), so the call is explicit.
    box.setAttribute("tabindex", "-1")
    const dots = "M10 6a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3Zm0 5.5a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3Zm0 5.5a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3Z"
    // TG-style chrome (#465): a back arrow + who/when + an actions menu, all in a
    // top bar that respects the safe area — the lone floating X sat under the notch
    // and read as an afterthought (user report + audit).
    box.innerHTML =
      '<div class="ed-lightbox__bar">' +
      `<button class="ed-lightbox__btn ed-lightbox__close" aria-label="${lbl.lbClose || "Close"}">${chevron(left)}</button>` +
      '<div class="ed-lightbox__title"><span class="ed-lightbox__who"></span>' +
      '<span class="ed-lightbox__when"></span></div>' +
      '<div class="ed-lightbox__count" aria-live="polite"></div>' +
      `<button class="ed-lightbox__btn ed-lightbox__more" aria-label="${lbl.lbMenu || "Actions"}" aria-haspopup="menu" aria-expanded="false">${chevron(dots)}</button>` +
      '</div>' +
      '<div class="ed-lightbox__menu" role="menu" hidden>' +
      `<button class="ed-lightbox__item" role="menuitem" data-act="show">${lbl.lbShow || "Show in chat"}</button>` +
      `<button class="ed-lightbox__item" role="menuitem" data-act="save">${lbl.lbSave || "Save"}</button>` +
      `<button class="ed-lightbox__item" role="menuitem" data-act="reply">${lbl.lbReply || "Reply"}</button>` +
      `<button class="ed-lightbox__item" role="menuitem" data-act="forward">${lbl.lbForward || "Forward"}</button>` +
      `<button class="ed-lightbox__item" role="menuitem" data-act="del-me">${lbl.lbDelMe || "Delete for me"}</button>` +
      `<button class="ed-lightbox__item ed-lightbox__item--danger" role="menuitem" data-act="del-all">${lbl.lbDelAll || "Delete for everyone"}</button>` +
      '</div>' +
      // Each arrow lives in a wide invisible zone (#466 audit): on a 1920px
      // screen the buttons hugged the viewport edges — a long mouse trip, and a
      // miss by a millimetre closed the viewer. The zone swallows those misses.
      `<div class="ed-lightbox__zone ed-lightbox__zone--prev"><button class="ed-lightbox__nav ed-lightbox__nav--prev" aria-label="${lbl.lbPrev || "Previous"}">${chevron(left)}</button></div>` +
      // A real carousel (#466): three slots — previous, current, next — on a
      // track that follows the finger. A lone <img> could only cross-fade, and
      // the fade competed with the decode-hide, so paging read as a hard cut.
      '<div class="ed-lightbox__stage"><div class="ed-lightbox__track">' +
      '<div class="ed-lightbox__slide"><img class="ed-lightbox__img" alt=""></div>' +
      '<div class="ed-lightbox__slide ed-lightbox__slide--cur"><img class="ed-lightbox__img" alt=""></div>' +
      '<div class="ed-lightbox__slide"><img class="ed-lightbox__img" alt=""></div>' +
      '</div></div>' +
      `<div class="ed-lightbox__zone ed-lightbox__zone--next"><button class="ed-lightbox__nav ed-lightbox__nav--next" aria-label="${lbl.lbNext || "Next"}">${chevron(right)}</button></div>` +
      '<div class="ed-lightbox__strip" role="tablist"></div>'
    const track = box.querySelector(".ed-lightbox__track")
    const slots = [...box.querySelectorAll(".ed-lightbox__slide")]
    const imgs = slots.map((sl) => sl.querySelector("img"))
    // The photo outranks its own filmstrip (#552). Re-windowing the strip queues up to 49
    // thumbnails at once, and the browser opens six connections: measured on this stand,
    // the preview of the photo being paged TO waited ~500ms behind them, which is most of
    // what "paging is not smooth" was. These are hints, ignored where unsupported.
    imgs.forEach((im) => (im.fetchPriority = "high"))
    // The centre slot is "the" photo: zoom, save and the a11y name all mean it.
    const img = imgs[1]
    box.__img = () => imgs[1]
    // Track offset in px; -W is "centre slot centred".
    // Measured once and remembered (#552). `trackTo` runs on every touchmove and writes
    // `transform` before reading this; reading `clientWidth` there forced a synchronous
    // layout per frame of the drag, which is the drag's own jank.
    let sw = 0
    const stageW = () => {
      if (sw) return sw
      // Only a real measurement is worth remembering. `show()` runs before `showModal()`,
      // and a closed <dialog> is display:none — so the first call here reads 0 and the
      // fallback would be cached forever, off by the scrollbar's width on every platform
      // that reserves one (#553 review). The viewer re-centres itself once it is open.
      const w = box.querySelector(".ed-lightbox__stage").clientWidth
      if (w) sw = w
      return w || window.innerWidth
    }
    box.__forgetW = () => (sw = 0)
    window.addEventListener("resize", () => (sw = 0))
    const trackTo = (dx, animate) => {
      track.style.transition =
        animate && !matchMedia("(prefers-reduced-motion: reduce)").matches
          ? "transform 0.26s var(--ed-ease)"
          : "none"
      track.style.transform = `translate3d(${-stageW() + dx}px,0,0)`
    }
    box.__trackTo = trackTo
    box.__stageW = stageW

    // Swipe to dismiss (#554). The stage carries the photo, the root carries the scrim's
    // alpha; both follow the finger, so letting go halfway puts everything back instead of
    // committing to a state the gesture never reached.
    const stage = box.querySelector(".ed-lightbox__stage")
    const root = document.documentElement
    // How far a finger must travel before the viewer lets go. Roughly a fifth of the
    // screen, which is where a flick ends and a drag begins.
    const DISMISS = () => Math.max(80, window.innerHeight * 0.18)
    const dimTo = (v) => root.style.setProperty("--ed-lb-fade", String(v))
    const dismissTo = (dy) => {
      // Shrink a little as it goes: the photo reads as receding rather than sliding off a
      // shelf. Clamped, so a long drag does not shrink it to nothing.
      const t = Math.min(1, Math.abs(dy) / (window.innerHeight * 0.6))
      stage.style.transform = `translate3d(0,${dy}px,0) scale(${1 - t * 0.18})`
      dimTo(1 - t * 0.75)
    }
    // A gesture can end without a touchend: a second finger arrives, or the system takes the
    // touch away (a notification, an edge swipe). Without this the photo stays where the
    // finger left it and the viewer is stuck half-dismissed.
    // One owner for the settle timer (#555 review). Each of these schedules the same
    // cleanup, and a gesture that starts inside the previous one's 280ms would otherwise be
    // stripped of `--dismissing` mid-drag — the chrome would stop fading halfway through.
    const settle = (fn, ms) => {
      clearTimeout(box.__dismissT)
      box.__dismissT = setTimeout(fn, ms)
    }
    const dismissDone = () =>
      box.classList.remove("ed-lightbox--dismissing", "ed-lightbox--settling")
    const dismissCancel = () => {
      if (!box.__dismiss) return
      box.__dismiss = false
      box.classList.add("ed-lightbox--settling")
      stage.style.transform = ""
      dimTo(1)
      settle(dismissDone, 280)
    }
    const dismissReset = () => {
      clearTimeout(box.__dismissT)
      stage.style.transform = ""
      dimTo(1)
      dismissDone()
    }
    box.__dismissReset = dismissReset
    // Paint one slot: its source, its accessible name, and the decode-hide that
    // keeps a half-loaded frame from flashing.
    // Paint the PREVIEW first, then upgrade (#552). The strip's thumbnail is already
    // decoded in cache, while the slide was loading the original — up to 8 MB of it,
    // across the border — behind `visibility: hidden`. So a page landed on an empty
    // frame and the photo appeared whenever the network was done: the "paging is not
    // smooth" report. The preview shares the original's aspect ratio and the slide sizes
    // by `object-fit`, so the upgrade swaps pixels without moving anything.
    const paintSlot = (k, it) => {
      const el = imgs[k]
      if (!it) {
        el.removeAttribute("src")
        el.style.visibility = "hidden"
        return
      }
      if (el.dataset.src === it.full) return
      el.dataset.src = it.full
      el.alt = it.who ? `${box.__viewer} — ${it.who}` : box.__viewer
      const pre = it.thumb && it.thumb !== it.full ? it.thumb : null
      if (pre) {
        el.src = pre
        el.style.visibility = "visible"
      } else {
        el.style.visibility = "hidden"
      }
      const full = new Image()
      full.decoding = "async"
      const swap = () => {
        // Paged away while this decoded: the slot belongs to another photo now.
        if (el.dataset.src !== it.full) return
        el.src = it.full
        el.style.visibility = "visible"
      }
      full.onload = swap
      // NOT swap: a failed original must leave the preview on screen. Swapping to it
      // replaced a perfectly good frame with a broken one — caught by the test that blocks
      // originals, and it is what a network blip would have done in production.
      full.onerror = () => {}
      full.src = it.full
      // Decode off the main thread where it is offered, so the swap itself never drops a
      // frame mid-swipe; `onload` above still covers browsers without it.
      if (full.decode) full.decode().then(swap, () => {})
    }
    box.__paintSlot = paintSlot
    const menu = box.querySelector(".ed-lightbox__menu")
    const more = box.querySelector(".ed-lightbox__more")

    // The strip (#466): the conversation's media as tappable thumbnails, the
    // current one lit and scrolled into view.
    const strip = box.querySelector(".ed-lightbox__strip")
    // A window, not the whole reel: a long conversation has hundreds of photos
    // and that many <img> nodes would cost more than the viewer itself.
    const STRIP_SPAN = 24
    // How close to an edge of the rendered window the active thumbnail may come before the
    // window slides. Recentering on EVERY step rebuilt 49 <img> nodes per page — during
    // the paging animation, which is where the jank was visible (#552).
    const STRIP_EDGE = 8
    box.__renderStrip = (idx) => {
      const items = box.__items ? box.__items() : []
      strip.hidden = items.length < 2
      if (strip.hidden) return
      const from = Math.max(0, idx - STRIP_SPAN)
      const win = items.slice(from, idx + STRIP_SPAN + 1)
      // Identity, not length (#552): the reel is REPLACED wholesale when the server's page
      // lands, and a replacement of the same length left the previous conversation's
      // thumbnails on screen — each one paging to the wrong photo. Ids settle that;
      // `childElementCount` alone could not.
      const reel = `${items.length}:${items[0].id}:${items[items.length - 1].id}`
      const lo = Number(strip.dataset.from)
      const hi = lo + strip.childElementCount - 1
      // Still comfortably inside the rendered window: move the marker, keep the nodes.
      const centred =
        strip.dataset.reel === reel &&
        strip.childElementCount > 0 &&
        (lo === 0 || idx - lo >= STRIP_EDGE) &&
        (hi >= items.length - 1 || hi - idx >= STRIP_EDGE)
      if (!centred) {
        strip.dataset.from = String(from)
        strip.dataset.reel = reel
        strip.replaceChildren(
          ...win.map((it, k) => {
            const n = from + k
            const b = document.createElement("button")
            b.className = "ed-lightbox__thumb"
            b.dataset.i = String(n)
            b.setAttribute("role", "tab")
            const im = document.createElement("img")
            im.alt = ""
            im.loading = "lazy"
            im.fetchPriority = "low"
            im.src = it.thumb
            // A thumbnail the worker hasn't produced yet 404s — fall back to the
            // original once, then leave the neutral tile rather than a broken glyph.
            im.onerror = () => {
              if (im.dataset.fellBack) return im.remove()
              im.dataset.fellBack = "1"
              im.src = it.full
            }
            b.appendChild(im)
            return b
          })
        )
      }
      ;[...strip.children].forEach((c) => {
        const on = Number(c.dataset.i) === idx
        c.classList.toggle("ed-lightbox__thumb--on", on)
        c.setAttribute("aria-selected", String(on))
        if (on) c.scrollIntoView({ block: "nearest", inline: "center" })
      })
    }

    // Chrome is data-driven: each shown photo pushes its own meta (#465).
    box.__renderChrome = () => {
      const m = box.__meta || {}
      box.querySelector(".ed-lightbox__who").textContent = m.who || ""
      const when = box.querySelector(".ed-lightbox__when")
      when.textContent = m.at ? fmtWhen(m.at) : ""
      // No message context (the profile gallery) → no actions to offer.
      more.hidden = !m.msg
      box.querySelector('[data-act="del-all"]').hidden = m.mine !== "1"
      closeMenu()
    }
    // The viewer's own locale/zone, like the date rail (gettext can't reach here).
    const fmtWhen = (iso) => {
      try {
        const d = new Date(iso)
        const loc = document.getElementById("message-scroll")?.dataset.locale || undefined
        return d.toLocaleString(loc, {
          day: "numeric",
          month: "short",
          hour: "2-digit",
          minute: "2-digit",
        })
      } catch (_e) {
        return ""
      }
    }
    const closeMenu = () => {
      menu.hidden = true
      more.setAttribute("aria-expanded", "false")
    }
    box.__closeMenu = closeMenu
    more.addEventListener("click", (e) => {
      e.stopPropagation()
      menu.hidden = !menu.hidden
      more.setAttribute("aria-expanded", String(!menu.hidden))
    })
    // async: the delete action asks in the app's own dialog, which resolves a promise (#518).
    menu.addEventListener("click", (e) => {
      const item = e.target.closest("[data-act]")
      if (!item) return
      e.stopPropagation()
      closeMenu()
      box.__act(item.dataset.act)
    })

    // ---- zoom (#469, audit P1): pinch / wheel / double-tap+dblclick, with pan.
    // Transforms only (translate+scale around the viewport center); page/close
    // swipes are gated on z === 1 so a zoomed drag pans instead of paging.
    let z = 1
    let px = 0
    let py = 0
    const applyZoom = (animate) => {
      img.style.transition =
        animate && !matchMedia("(prefers-reduced-motion: reduce)").matches
          ? "transform 0.18s var(--ed-ease)"
          : "none"
      img.style.transform = z > 1 ? `translate(${px}px, ${py}px) scale(${z})` : ""
      box.classList.toggle("ed-lightbox--zoomed", z > 1)
    }
    // The PHOTO's rendered size, not the element's. The slide now fills the stage and
    // `object-fit` fits the photo inside it (#552), so `offsetWidth` is the stage — panning
    // a portrait against that would drag it well past its own edge into empty backdrop.
    const shown = () => {
      const nw = img.naturalWidth || img.offsetWidth || 1
      const nh = img.naturalHeight || img.offsetHeight || 1
      const s = Math.min(img.offsetWidth / nw, img.offsetHeight / nh) || 1
      return { w: nw * s, h: nh * s }
    }
    // Is this point on the photo itself? The element fills the stage so that the preview and
    // the original occupy the same box (#552), which means `e.target` is the <img> across
    // the whole stage — including the letterboxing beside a portrait, where a tap has
    // always closed the viewer and must keep doing so.
    const overPhoto = (e) => {
      // Fit the photo inside the element's VISUAL rect, which already carries the zoom
      // transform and the pan — not inside `offsetWidth`, which is the untransformed
      // layout box. Deriving it from `shown()` (layout-based, as `clampPan` needs it)
      // measured the photo at 1x while the person was looking at it at 2.5x, so a click
      // on the enlarged photo outside its 1x footprint counted as backdrop and shut the
      // viewer (#553 review).
      const r = img.getBoundingClientRect()
      const nw = img.naturalWidth
      const nh = img.naturalHeight
      // Nothing decoded yet means there is no photo under the pointer, so the whole stage is
      // backdrop and a tap dismisses. Falling back to 1x1 instead made the hit region a
      // square the height of the stage, and a tap in the middle of a still-loading viewer
      // did nothing at all (#553 review).
      if (!nw || !nh) return false
      const s = Math.min(r.width / nw, r.height / nh) || 1
      return (
        Math.abs(e.clientX - (r.left + r.width / 2)) <= (nw * s) / 2 &&
        Math.abs(e.clientY - (r.top + r.height / 2)) <= (nh * s) / 2
      )
    }
    box.__overPhoto = overPhoto
    const clampPan = () => {
      const { w, h } = shown()
      const bx = Math.max(0, (w * z - window.innerWidth) / 2 + 24)
      const by = Math.max(0, (h * z - window.innerHeight) / 2 + 24)
      px = Math.min(bx, Math.max(-bx, px))
      py = Math.min(by, Math.max(-by, py))
    }
    // Zoom about a viewport point f: the pixel under it must not move.
    const zoomAt = (fx, fy, nz, animate) => {
      const cz = Math.min(4, Math.max(1, nz))
      const cx = window.innerWidth / 2
      const cy = window.innerHeight / 2
      px = fx - cx - ((fx - cx - px) * cz) / z
      py = fy - cy - ((fy - cy - py) * cz) / z
      z = cz
      if (z === 1) { px = 0; py = 0 }
      clampPan()
      applyZoom(animate)
    }
    const zoomReset = () => { z = 1; px = 0; py = 0; applyZoom(false) }
    box.__zoomReset = zoomReset
    const toggleZoom = (fx, fy) => zoomAt(fx, fy, z > 1 ? 1 : 2.5, true)
    img.addEventListener("dblclick", (e) => {
      if (!overPhoto(e)) return
      e.stopPropagation()
      toggleZoom(e.clientX, e.clientY)
    })
    // The cursor says which of the two the pointer is over. Without this the letterbox
    // beside a portrait offers zoom-in and then closes the viewer.
    box.addEventListener("pointermove", (e) => {
      if (box.__curT) return
      box.__curT = requestAnimationFrame(() => {
        box.__curT = 0
        box.classList.toggle("ed-lightbox--on-photo", overPhoto(e))
      })
    })
    box.addEventListener(
      "wheel",
      (e) => {
        // Trackpad/wheel zoom over the whole overlay (desktop). preventDefault
        // keeps the (inert) page behind from scrolling.
        e.preventDefault()
        zoomAt(e.clientX, e.clientY, z * Math.exp(-e.deltaY * 0.0022), false)
      },
      { passive: false }
    )

    // Menu actions (#465). Reply/Forward/Delete reuse the message context-menu's
    // own server events; "Show in chat" and "Save" are client-side.
    // async: the delete action asks in the app's own dialog, which resolves a promise (#518).
    box.__act = async (act) => {
      const m = box.__meta || {}
      const id = m.msg
      if (!id) return
      const push = (ev, payload) => box.__hook?.pushEvent(ev, payload)
      if (act === "show") {
        // The message is already in the stream behind the viewer — close and
        // land on it with the permalink highlight the jump flow uses.
        close()
        setTimeout(() => {
          const row = document.getElementById(`messages-${id}`)
          if (!row) return
          // "instant", not "auto", for anyone who asked for no motion: "auto" DELEGATES to
          // the container's computed `scroll-behavior`, so it only happens to be instant
          // while no scroller in this app sets `smooth` (#571 review). The two other
          // jump-to-a-message scrollers already skip the glide; this one alone did not.
          row.scrollIntoView({
            block: "center",
            behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches
              ? "instant"
              : "smooth",
          })
          row.classList.add("ed-msg--focus")
          // The token, not 1600: the flash is a 2200ms animation whose fade lives in its
          // last third, so stripping the class early switched the ring off by a frame
          // instead of letting it go out (#517).
          setTimeout(() => row.classList.remove("ed-msg--focus"), window.__edFocusHold())
        }, 180)
        return
      }
      if (act === "save") {
        // Native: the in-app viewer (SFSafariViewController) is where iOS offers
        // "Add to Photos" / the system share — the WebView itself can't write to
        // the photo library (#465; a one-tap native save needs Filesystem+Share,
        // filed as a follow-up). Browsers get the ordinary download.
        const url = box.__src
        const browser = window.Capacitor?.isNativePlatform?.()
          ? window.Capacitor.Plugins?.Browser
          : null
        if (browser?.open) {
          fetch(`${url}/link`, { headers: { accept: "application/json" } })
            .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
            .then(({ url: signed }) => browser.open({ url: location.origin + signed }))
            .catch(() => {})
        } else {
          const a = document.createElement("a")
          a.href = url
          a.download = ""
          document.body.appendChild(a)
          a.click()
          a.remove()
        }
        return
      }
      if (act === "reply") {
        close()
        push("reply", { id })
        return
      }
      if (act === "forward") {
        close()
        push("forward_prompt", { id, surface: "main" })
        return
      }
      if (act === "del-me") {
        close()
        push("delete_for_me", { id })
        return
      }
      if (act === "del-all") {
        if (!(await window.__edConfirm(lbl.lbDelConfirm || "Delete this message for everyone?")))
          return
        close()
        push("delete_for_both", { id })
      }
    }

    const close = (instant) => {
      if (box.__closing || !box.open) return
      box.__closing = true
      closeMenu()
      const fin = () => {
        box.classList.remove("ed-lightbox--out")
        box.__closing = false
        try { box.close() } catch (_e) { /* already closed */ }
        window.dispatchEvent(new CustomEvent("ed:lightbox", { detail: { open: false } }))
        document.body.style.overflow = ""
        document.removeEventListener("keydown", box.__onKey)
        zoomReset()
        // The next open must start from rest, wherever this one was dragged to.
        dismissReset()
      }
      // A 150ms fade out (audit P2: the instant display-flip cut the swipe-to-
      // close gesture off mid-motion); instant under reduced motion, and instant when a
      // dismiss gesture has already animated the photo out (#554) — fading a photo that
      // has left the screen only delays the dialog.
      if (instant || matchMedia("(prefers-reduced-motion: reduce)").matches) return fin()
      box.classList.add("ed-lightbox--out")
      box.__closeTimer = setTimeout(fin, 150)
    }
    // Expose close so the global nav guard (#380/R187) can dismiss the overlay when a
    // server-driven navigation tears down the owning hook without firing Esc/backdrop close.
    box.__close = close
    // Esc arrives as the dialog cancel event — reroute through the animated close.
    box.addEventListener("cancel", (e) => { e.preventDefault(); close() })
    box.__onKey = (e) => {
      if (e.key === "ArrowLeft") box.__step(-1)
      else if (e.key === "ArrowRight") box.__step(1)
    }
    box.addEventListener("click", (e) => {
      // A swipe ends in a synthetic click — ignore it so a page/close
      // gesture doesn't also fire the tap-to-close (#96).
      if (box.__swiped) {
        box.__swiped = false
        return
      }
      if (!menu.hidden && !e.target.closest(".ed-lightbox__menu")) return closeMenu()
      // The back arrow FIRST (#472 review): it lives inside the bar, so the
      // "clicks on the bar don't close the viewer" guard below was swallowing
      // the primary close affordance.
      if (e.target.closest(".ed-lightbox__close")) return close()
      if (e.target.closest(".ed-lightbox__bar")) return
      const thumb = e.target.closest(".ed-lightbox__thumb")
      if (thumb) {
        e.stopPropagation()
        return box.__goto(Number(thumb.dataset.i))
      }
      if (e.target.closest(".ed-lightbox__strip")) return
      const zone = e.target.closest(".ed-lightbox__zone")
      if (zone) {
        e.stopPropagation()
        // A click anywhere in the zone pages — a near-miss on the button is
        // still an intent to page, never an intent to close (#466 audit).
        return box.__step(zone.classList.contains("ed-lightbox__zone--next") ? 1 : -1)
      }
      if (!overPhoto(e)) {
        close()
      }
    })
    // Touch (#96 + #469): one finger swipes page/close at 1x and PANS when
    // zoomed; two fingers pinch-zoom (preventDefault owns the gesture, or iOS
    // pinches the page). Double-tap toggles 1x <-> 2.5x at the tap point.
    let tx = 0
    let ty = 0
    let multi = false
    let pinch = null
    let pan = null
    let lastTap = { t: 0, x: 0, y: 0 }
    const dist = (a, b) => Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY)
    box.addEventListener(
      "touchstart",
      (e) => {
        if (e.touches.length === 1) {
          tx = e.touches[0].clientX
          ty = e.touches[0].clientY
          box.__dragT0 = e.timeStamp
          multi = false
          pan = z > 1 ? { x: tx, y: ty, px, py } : null
        } else if (e.touches.length === 2) {
          multi = true
          pan = null
          const [a, b] = e.touches
          pinch = {
            d0: dist(a, b),
            mx: (a.clientX + b.clientX) / 2,
            my: (a.clientY + b.clientY) / 2,
            z0: z,
          }
        } else {
          multi = true
        }
        box.__swiped = false
      },
      { passive: true }
    )
    box.addEventListener(
      "touchmove",
      (e) => {
        if (e.touches.length === 2 && pinch) {
          dismissCancel()
          e.preventDefault()
          const [a, b] = e.touches
          zoomAt(pinch.mx, pinch.my, pinch.z0 * (dist(a, b) / pinch.d0), false)
        } else if (e.touches.length === 1 && pan) {
          e.preventDefault()
          px = pan.px + (e.touches[0].clientX - pan.x)
          py = pan.py + (e.touches[0].clientY - pan.y)
          clampPan()
          applyZoom(false)
        } else if (e.touches.length === 1 && !multi) {
          // Carousel drag (#466): at 1x a mostly-horizontal finger CARRIES the
          // track, so the neighbouring photos come in from the edges exactly
          // like a phone gallery. Vertical intent is left to swipe-to-close.
          const dx = e.touches[0].clientX - tx
          const dy = e.touches[0].clientY - ty
          if (!box.__dragging && !box.__dismiss && Math.abs(dx) > 12 && Math.abs(dx) > Math.abs(dy)) {
            box.__dragging = true
          }
          // The other axis dismisses (#554). Decided once, like the paging drag, so a
          // gesture never fights itself halfway through.
          if (!box.__dragging && !box.__dismiss && Math.abs(dy) > 12 && Math.abs(dy) >= Math.abs(dx)) {
            box.__dismiss = true
            clearTimeout(box.__dismissT)
            box.classList.add("ed-lightbox--dismissing")
            box.classList.remove("ed-lightbox--settling")
          }
          if (box.__dismiss) {
            e.preventDefault()
            dismissTo(dy)
            return
          }
          if (box.__dragging) {
            e.preventDefault()
            // Rubber-band at the reel's ends so it never drags into a void.
            const idx = box.__index ? box.__index() : 0
            const len = box.__items ? box.__items().length : 1
            const atEnd = (dx > 0 && idx === 0) || (dx < 0 && idx === len - 1)
            trackTo(atEnd ? dx * 0.3 : dx, false)
          }
        } else if (e.touches.length > 1) {
          multi = true
        }
      },
      { passive: false }
    )
    box.addEventListener("touchcancel", dismissCancel, { passive: true })
    box.addEventListener(
      "touchend",
      (e) => {
        // A pinch or a stray extra finger cancels a dismiss rather than committing it.
        if (multi || (pinch && e.touches.length < 2)) dismissCancel()
        if (pinch && e.touches.length < 2) {
          // Pinch released: snap a near-1x back to rest.
          if (z < 1.05) zoomReset()
          pinch = null
          if (e.touches.length === 0) multi = false
          box.__swiped = true // the gesture must not fall through to tap-to-close
          return
        }
        if (multi) {
          if (e.touches.length === 0) multi = false
          return
        }
        const t = e.changedTouches[0]
        if (!t) return
        const dx = t.clientX - tx
        const dy = t.clientY - ty
        const moved = Math.hypot(dx, dy)
        if (pan) {
          pan = null
          if (moved > 10) box.__swiped = true
          return // zoomed: drags pan, they never page/close
        }
        if (box.__dragging) {
          // Commit past a third of the stage (or on a flick), else spring home.
          box.__swiped = true
          const w = stageW()
          const fast =
            Math.abs(dx) / Math.max(1, e.timeStamp - (box.__dragT0 || e.timeStamp)) > 0.4
          const dir = dx < 0 ? 1 : -1
          const idx = box.__index ? box.__index() : 0
          const reel = box.__items ? box.__items() : []
          const target = idx + dir
          if ((Math.abs(dx) > w / 3 || fast) && reel[target]) {
            trackTo(dir > 0 ? -w : w, true)
            setTimeout(() => {
              box.__dragging = false
              box.__show(target)
            }, 270)
          } else {
            trackTo(0, true)
            setTimeout(() => (box.__dragging = false), 270)
          }
          return
        }
        if (box.__dismiss) {
          box.__dismiss = false
          box.__swiped = true
          const fast =
            Math.abs(dy) / Math.max(1, e.timeStamp - (box.__dragT0 || e.timeStamp)) > 0.5
          box.classList.add("ed-lightbox--settling")
          if (Math.abs(dy) > DISMISS() || fast) {
            // Committed: carry it the rest of the way off screen and take the scrim with
            // it, then close without the fade — the photo has already gone.
            const out = dy > 0 ? window.innerHeight : -window.innerHeight
            stage.style.transform = `translate3d(0,${out}px,0) scale(0.82)`
            dimTo(0)
            settle(() => close(true), 240)
          } else {
            // Not far enough: everything goes back exactly the way it came.
            stage.style.transform = ""
            dimTo(1)
            settle(dismissDone, 280)
          }
          return
        }
        if (moved < 10) {
          // Double-tap zoom (300ms window, near the same spot).
          const now = e.timeStamp
          if (now - lastTap.t < 300 && Math.hypot(t.clientX - lastTap.x, t.clientY - lastTap.y) < 40) {
            box.__swiped = true // suppress the synthetic click pair
            toggleZoom(t.clientX, t.clientY)
            lastTap = { t: 0, x: 0, y: 0 }
          } else {
            lastTap = { t: now, x: t.clientX, y: t.clientY }
          }
        }
      },
      { passive: true }
    )
    document.body.appendChild(box)
    return box
  },
}
