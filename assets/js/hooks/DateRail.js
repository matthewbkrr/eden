// Date separators + a sticky day chip (#83), grouped in the viewer's LOCAL
// timezone from each row's data-ts (UTC unix seconds). Client-side so it groups
// by the local day and survives streamed inserts + "load older" — reconcile()
// re-derives the inline separators after every stream patch. Labels come from
// Intl(locale) + the gettext Today/Yesterday passed as data-* (gettext is
// unreachable in the hook).
export default {
  mounted() {
    this.scroller = this.el.closest("#message-scroll") || this.el.parentElement
    this.locale = this.el.dataset.locale || undefined
    this.today = this.el.dataset.today || "Today"
    this.yesterday = this.el.dataset.yesterday || "Yesterday"
    // The floating chip is server-rendered (#date-chip) so a re-render can't drop
    // it — we only read/update it here, never inject it.
    this.chip = this.scroller.querySelector("#date-chip")
    // The chip is a scroll-only affordance. A LiveView re-render (e.g. typing
    // in the composer fires phx-change) reflows the streamed list and nudges
    // scrollTop by a sub-pixel amount, emitting a "scroll" with no real motion —
    // that flashed the chip on every keystroke (#134). Anchor the last position
    // and ignore movement under a few px (well below a line), so only a genuine
    // scroll updates the chip; the wobble (≤1px, nets to zero) is filtered out.
    this._chipAnchor = this.scroller.scrollTop
    // #150: the chip is a USER-scroll affordance only. Programmatic scrolls move the
    // list too — scroll-to-bottom on send / new message, jump-to-message, the
    // load-older restore, the mount scroll — and must NOT flash the day pill. Track a
    // short "user is scrolling" window opened by wheel / touch-drag / scroll keys and
    // kept alive by the scroll events they produce (trackpad & flick momentum fire no
    // further input events but keep scrolling); a scroll outside it is programmatic.
    this._userScrollUntil = 0
    const scrollKeys = new Set([
      "PageUp", "PageDown", "ArrowUp", "ArrowDown", "Home", "End", " ", "Spacebar"
    ])
    this._markUser = () => { this._userScrollUntil = Date.now() + 150 }
    this._onUserKey = (e) => { if (scrollKeys.has(e.key)) this._markUser() }
    this.scroller.addEventListener("wheel", this._markUser, { passive: true })
    this.scroller.addEventListener("touchmove", this._markUser, { passive: true })
    this.scroller.addEventListener("keydown", this._onUserKey)
    this.onScroll = () => {
      if (this._raf) return
      this._raf = requestAnimationFrame(() => {
        this._raf = null
        const top = this.scroller.scrollTop
        if (Math.abs(top - this._chipAnchor) < 4) return
        this._chipAnchor = top
        // Programmatic scroll (no recent user intent) → re-anchor but don't reveal.
        if (Date.now() >= this._userScrollUntil) return
        // Momentum keeps firing scroll with no input events — extend the window so the
        // chip stays through the glide, then lapses ~150ms after motion stops.
        this._userScrollUntil = Date.now() + 150
        this.updateChip(top)
      })
    }
    this.scroller.addEventListener("scroll", this.onScroll, { passive: true })
    this.reconcile()
    this.scheduleMidnight()
    // Every LiveView patch makes morphdom drop our injected separators; the
    // hook's updated() only re-adds them a frame later, so the 22px gap is
    // painted and the list visibly twitches (worse in browsers with weak scroll
    // anchoring, e.g. Firefox) (#104). This observer re-derives them in the SAME
    // microtask the drop happens in — before the browser reflows/paints — so
    // scrollHeight never visibly changes.
    this.mo = new MutationObserver((records) => {
      // A wholesale arrival — opening a chat, switching to another, pulling in history —
      // must not play every reaction reveal at once (#565 review). One row landing is an
      // event and animates; two or more at once is a render and does not.
      //
      // Only MESSAGE rows count: this observer's own separators land in the same container
      // (that is what `reconcile()` does), and counting them would call a single arrival
      // a batch. The threshold was 3 to dodge exactly that, which was a guess covering a
      // miscount rather than a rule (#565 review).
      const rows = records.reduce(
        (n, r) =>
          n +
          [...r.addedNodes].filter(
            (x) => x.nodeType === 1 && x.matches(".ed-msg, .ed-flat")
          ).length,
        0
      )
      if (rows > 1) {
        this.el.classList.add("ed-feed--bulk")
        this._unbulk()
      }
      this.reconcile()
    })
    this.mo.observe(this.el, { childList: true })
    // The first render arrives with the class already on it (see the template) — take it
    // off once the frame it belongs to has been painted.
    this._unbulk()
    // The cached boundary positions (#519) are only as good as the layout they were taken
    // from. Rows arriving is one signal and `reconcile()` covers it, but a photo decoding
    // changes heights without touching the child list — and the feed would then label the
    // wrong day. The container's own size changes in both cases.
    // Local time for every <time> in the feed, from ONE hook (#557). A `phx-hook` on each
    // one meant 450 hook instances on a 462-row feed — 450 `mounted()` calls every time the
    // chat opens, which is what made the switch script-bound. The work per label is
    // identical; only the bookkeeping is gone.
    //
    // rAF-coalesced and marked with `data-lt`, so a burst of patches is one pass and an
    // already-formatted label is skipped. morphdom strips the marker when it rewrites a
    // row, which is exactly right: the row goes back to the server's UTC text and this
    // formats it again.
    this.fmtTimes()
    this.timeMo = new MutationObserver(() => {
      if (this._tRaf) return
      this._tRaf = requestAnimationFrame(() => {
        this._tRaf = null
        this.fmtTimes()
      })
    })
    this.timeMo.observe(this.el, { childList: true, subtree: true })
    this._invalidate = () => {
      this._geo = null
      // A chip already on screen would otherwise keep naming the day it was computed for
      // until the next scroll event — and a photo decoding above it moves every boundary
      // under it (#556 review). Only while it is visible, which is only during a scroll.
      if (this.chip && this.chip.classList.contains("is-visible")) this.updateChip()
    }
    this.ro = new ResizeObserver(this._invalidate)
    this.ro.observe(this.el)
    window.addEventListener("resize", this._invalidate)
  },
  updated() { this._geo = null; this.reconcile(); this.fmtTimes(); this._unbulk() },
  // Let the paint that carries the batch happen, THEN allow motion again. Two frames, not
  // a timer: a timer is a guess about when a paint happened, and on a throttled or
  // backgrounded page it can fire first — which would let the whole screen animate on load,
  // the exact thing this suppresses (#565 review). The first callback runs before the
  // paint, the second after it.
  _unbulk() {
    if (this._bulkR) cancelAnimationFrame(this._bulkR)
    this._bulkR = requestAnimationFrame(() => {
      this._bulkR = requestAnimationFrame(() => {
        this._bulkR = 0
        this.el.classList.remove("ed-feed--bulk")
      })
    })
  },
  destroyed() {
    if (this.scroller) {
      this.onScroll && this.scroller.removeEventListener("scroll", this.onScroll)
      this._markUser && this.scroller.removeEventListener("wheel", this._markUser)
      this._markUser && this.scroller.removeEventListener("touchmove", this._markUser)
      this._onUserKey && this.scroller.removeEventListener("keydown", this._onUserKey)
    }
    this.mo && this.mo.disconnect()
    if (this._bulkR) cancelAnimationFrame(this._bulkR)
    this.timeMo && this.timeMo.disconnect()
    this._tRaf && cancelAnimationFrame(this._tRaf)
    this.ro && this.ro.disconnect()
    this._invalidate && window.removeEventListener("resize", this._invalidate)
    this._raf && cancelAnimationFrame(this._raf)
    clearTimeout(this._fade)
    clearTimeout(this._midnight)
  },
  // Re-derive the labels at local midnight so a tab left open across it doesn't
  // keep an old "Today"/"Yesterday" (the day key is unchanged, so force a relabel).
  scheduleMidnight() {
    const now = new Date()
    const next = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 0, 0, 5)
    this._midnight = setTimeout(() => {
      this._sig = null
      this.reconcile()
      this.updateChip()
      this.scheduleMidnight()
    }, next - now)
  },
  fmtTimes() { window.__edFmtTimes(this.el) },
  // Local-day key (browser TZ): a row's day-change boundary + Today/Yesterday.
  dayKeyOf(d) { return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate() },
  dayLabel(ts) {
    if (!Number.isFinite(ts)) return ""
    const d = new Date(ts * 1000)
    const now = new Date()
    if (this.dayKeyOf(d) === this.dayKeyOf(now)) return this.today
    const y = new Date(now)
    y.setDate(y.getDate() - 1)
    if (this.dayKeyOf(d) === this.dayKeyOf(y)) return this.yesterday
    // Reuse the formatter instead of building one per call (#519). This runs on every
    // scroll tick — measured at 30 constructions for 30 wheel ticks — and constructing an
    // Intl.DateTimeFormat is one of the most expensive calls in ICU. There are exactly two
    // shapes (this year / another year), so two cached instances cover every label.
    // The locale is part of the key (#535 review): it rides a dataset attribute, so a
    // patch can change it under a live hook, and a cache keyed only by shape would keep
    // formatting in the language the person just left.
    const sameYear = d.getFullYear() === now.getFullYear()
    const key = `${this.locale}|${sameYear ? "short" : "full"}`
    this._fmt = this._fmt || {}

    this._fmt[key] =
      this._fmt[key] ||
      new Intl.DateTimeFormat(
        this.locale,
        sameYear
          ? { day: "numeric", month: "long" }
          : { day: "numeric", month: "long", year: "numeric" }
      )

    return this._fmt[key].format(d)
  },
  rows() { return [...this.el.children].filter((c) => c.dataset && c.dataset.ts) },
  // Re-derive the boundary rows (first row of each local day; a non-finite ts is
  // skipped, never crashing Intl). Skip the DOM remove+reinsert when the day
  // structure is unchanged — most patches (a reaction toggle, read tick,
  // thumbnail swap, a same-day message) don't move a boundary, so they no-op.
  reconcile() {
    const desired = []
    let prev = null
    for (const row of this.rows()) {
      const k = this.dayKeyOf(new Date(Number(row.dataset.ts) * 1000))
      if (Number.isFinite(k) && k !== prev) { desired.push(row); prev = k }
    }
    const existing = this.el.querySelectorAll(":scope > .ed-date-sep")
    const sig = desired.map((r) => r.id).join("|")
    // Skip the DOM churn only when the day structure is unchanged AND every
    // separator is still sitting immediately before its row. A stream patch can
    // drop the injected nodes (append), and a stream RESET (switching
    // conversations) drops the message rows but leaves the phx-update="ignore"
    // separators and re-adds the rows after them — detaching every separator to
    // one end. A structure-only check would treat that as unchanged and leave them
    // piled up, so verify their positions too.
    const inPlace =
      existing.length === desired.length &&
      desired.every((row) => {
        const prev = row.previousElementSibling
        return prev && prev.id === "ds-" + row.id
      })
    if (sig === this._sig && inPlace) return
    this._sig = sig
    // Suspend the observer around our own edits so re-adding doesn't re-enter
    // reconcile in a loop.
    this.mo && this.mo.disconnect()
    existing.forEach((s) => s.remove())
    for (const row of desired) {
      const sep = document.createElement("div")
      sep.className = "ed-date-sep"
      // id + phx-update="ignore" so LiveView's stream patcher treats the separator
      // as a managed node it must leave alone, instead of a phantom child it strips
      // on every patch. The strip was shrinking scrollHeight and clamping a bottom-
      // pinned scroll up by the separators' height (#104).
      sep.id = "ds-" + row.id
      sep.setAttribute("phx-update", "ignore")
      const span = document.createElement("span")
      span.textContent = this.dayLabel(Number(row.dataset.ts))
      sep.appendChild(span)
      this.el.insertBefore(sep, row)
    }
    this.mo && this.mo.observe(this.el, { childList: true })
  },
  // Track the topmost visible row's day in the floating chip; fade when idle. The
  // rows are vertically ordered, so binary-search the first one still in view
  // (O(log n) rect reads) instead of scanning every row each scroll frame.
  // Where the day boundaries sit, in the scroller's own content coordinates (#519).
  //
  // The chip used to answer by measuring: a rect for the scroller, one per separator, and
  // a binary search over the rows costing ~8 more — every frame, for the whole length of a
  // momentum glide. Measured on a 565-row feed: 1021 `getBoundingClientRect` calls for
  // thirty wheel ticks, each one a forced layout flush.
  //
  // None of that has to happen per frame, and most of it never has to happen at all: the
  // label is the day of the last boundary ABOVE the viewport, and there are as many
  // boundaries as there are days on screen — a handful, not hundreds. Measure those once,
  // then a frame is a comparison against a cached number.
  buildGeo() {
    const sTop = this.scroller.getBoundingClientRect().top
    const scrolled = this.scroller.scrollTop
    const at = (el) => {
      const r = el.getBoundingClientRect()
      return { top: r.top - sTop + scrolled, bottom: r.bottom - sTop + scrolled }
    }
    const seps = [...this.el.querySelectorAll(":scope > .ed-date-sep")].map((el) => {
      // The day a separator introduces is carried by the row after it, not by itself.
      let n = el.nextElementSibling
      while (n && !(n.dataset && n.dataset.ts)) n = n.nextElementSibling
      return { ...at(el), ts: n ? Number(n.dataset.ts) : NaN }
    })
    const first = this.el.querySelector(":scope > [data-ts]")
    this._geo = {
      chipH: this.chip ? this.chip.offsetHeight : 0,
      seps,
      // Above the first separator the feed is still one day: the oldest row's.
      firstTs: first ? Number(first.dataset.ts) : NaN
    }
  },
  updateChip(scrolled) {
    if (!this.chip) return
    if (scrolled === undefined) scrolled = this.scroller.scrollTop
    if (!this._geo) this.buildGeo()
    const geo = this._geo
    if (!Number.isFinite(geo.firstTs) && !geo.seps.length) {
      this.chip.classList.remove("is-visible")
      return
    }
    // If an inline separator sits in the floating chip's band at the top, let it
    // BE the label and keep the chip hidden — otherwise both render the same pill
    // stacked at a day boundary (the reported duplicate).
    const band = scrolled + geo.chipH + 6
    for (const sep of geo.seps) {
      if (sep.bottom > scrolled && sep.top < band) {
        this.chip.classList.remove("is-visible")
        clearTimeout(this._fade)
        return
      }
    }
    const top = scrolled + 4
    let ts = geo.firstTs
    for (const sep of geo.seps) {
      if (sep.top > top) break
      // A separator whose following row carries no timestamp (an optimistic node, a
      // placeholder) has no day to offer — keep the last one that did rather than
      // blanking the chip (#556 review).
      if (Number.isFinite(sep.ts)) ts = sep.ts
    }
    const label = this.dayLabel(ts)
    if (!label) { this.chip.classList.remove("is-visible"); return }
    this.chip.textContent = label
    this.chip.classList.add("is-visible")
    clearTimeout(this._fade)
    this._fade = setTimeout(() => this.chip.classList.remove("is-visible"), 1400)
  },
}
