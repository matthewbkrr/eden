// The hooks the boot bundle does not carry (#511, part of the #506 perf epic).
//
// Thirty-one of the app's forty-two hooks answer something that has not happened yet: a long-press,
// a photo tap, a drag, a paste, a video's play button. Their code still had to be parsed and
// executed before the socket could connect — 25 KB gzip (≈100 KB of source) of main-thread work
// on the one path that decides how long a cold start feels.
//
// They now live in a SECOND bundle (`js/lazy.js`, one request for all thirty-one) fetched right
// after the first frame. Until it arrives each name is registered as a placeholder — LiveView
// demands the hook at the instant the element mounts and has no notion of one arriving later — and
// the placeholder hands its instance over to the real hook as soon as the bundle lands.
//
// The split is by NEED, not by size: anything that paints, measures or positions at mount stays in
// the boot bundle (see `index.js`), because deferring those would trade a faster boot for a
// visible flicker, which is not a trade this epic is willing to make.
//
// The window this leaves is real and deliberately NOT papered over: a gesture that lands before the
// bundle does is not replayed, so a long-press in that first moment needs a second one. Capturing
// and re-dispatching it was considered and rejected — synthesized gestures are how this app got its
// ghost-menu races (#478/#479/#493), and buying back a sliver of one frame is not worth reopening
// that. The window is bounded by the fetch starting one frame after paint, and `zz-lazy-hooks`
// pins the behaviour on both sides of it rather than pretending it does not exist.

// Registered as placeholders, built into `js/lazy.js`. The two lists have to agree; the e2e spec
// asserts that they do, so a hook added to one and forgotten in the other fails a test rather
// than silently doing nothing in the browser.
export const DEFERRED = [
  "ContextMenu",
  "CopySelection",
  "CopyUrl",
  "DateRail",
  "DropZone",
  "EmojiPicker",
  "FocusTrap",
  "GalleryMonths",
  "GalleryTabs",
  "IdleTracker",
  "ImgPreview",
  "Lightbox",
  "Mentions",
  "NewConvGate",
  "NotifyPerm",
  "PasteUpload",
  "Popover",
  "ReactionGrid",
  "RoomSortable",
  "SearchBox",
  "SelectAllOnClick",
  "SelectOnFocus",
  "SelectSync",
  "SendQueue",
  "SidebarReorder",
  "Sortable",
  "SoundPreview",
  "ThemeSegA11y",
  "ThreadSendQueue",
  "VideoExpand",
  "VideoPreview",
]

let loading = null
let waiters = []

// One fetch for all of them. `script`, not `import()`: the bundles are built as IIFEs by the one
// esbuild profile, and the app's CSP is `script-src 'self' 'nonce-…'` — a same-origin src is
// allowed by `'self'` without needing the nonce handed to client code.
function loadAll() {
  if (loading) return loading

  loading = new Promise((resolve) => {
    const src = document.documentElement.dataset.lazyJs
    if (!src) return resolve({})

    const tag = document.createElement("script")
    tag.src = src
    tag.onload = () => resolve(window.__edenLazyHooks || {})
    // A failed fetch must not wedge the page: resolve empty (the interactive extras stay absent
    // rather than the app hanging on a promise) and let the next trigger try again.
    tag.onerror = () => {
      loading = null
      resolve({})
    }
    document.head.appendChild(tag)
  })

  loading.then((registry) => {
    const pending = waiters
    waiters = []
    pending.forEach((resolve) => resolve(registry))
  })

  return loading
}

// Waiting is not asking. A placeholder that called `loadAll()` itself would start the fetch the
// moment ITS element mounted — and something deferred is in the initial DOM of every page, so the
// request would go out during LiveView's startup, which is exactly the window this change exists
// to keep clear (#578 review). The triggers below own WHEN; a placeholder only says it is waiting.
function whenLoaded() {
  return loading || new Promise((resolve) => waiters.push(resolve))
}

// What LiveView mounts while the bundle is still in flight.
//
// LiveView copies a hook object's own keys onto the ViewHook instance and then calls
// `this.mounted()` / `this.updated()` on it, so assigning the real hook onto the same instance is
// a complete handover: `el`, `pushEvent`, `handleEvent` and the rest belong to ViewHook itself and
// are left untouched, while every method the hook defines on itself arrives at once.
function placeholder(name) {
  return {
    // What a test (and a console) can tell a placeholder by: once the bundle lands, no name in
    // `liveSocket.hooks` should still carry this.
    __lazyPlaceholder: name,
    mounted() {
      this.__queued = []
      this.__gone = false

      whenLoaded().then((registry) => {
        const real = registry[name]
        // Destroyed while the bundle was in flight: mounting now would attach listeners to a node
        // that is no longer in the document, and nothing would ever take them off again.
        if (!real || this.__gone) return

        // Taken BEFORE the assign. A hook with no `mounted` of its own leaves this placeholder's
        // in place, and calling it again would re-enter the handover — an endless microtask loop
        // rather than a hook (#578 review).
        const start = real.mounted
        Object.assign(this, real)
        start?.call(this)
        // Whatever LiveView called in the meantime, in the order it happened.
        for (const cb of this.__queued) this[cb]?.()
        this.__queued = null
      })
    },
    // Each of these survives the handover only when the real hook does NOT define it — then the
    // queue is already null and the push is a no-op.
    beforeUpdate() {
      this.__queued?.push("beforeUpdate")
    },
    updated() {
      this.__queued?.push("updated")
    },
    disconnected() {
      this.__queued?.push("disconnected")
    },
    reconnected() {
      this.__queued?.push("reconnected")
    },
    destroyed() {
      this.__gone = true
    },
  }
}

/** The placeholder for every deferred hook, ready to be registered with the eager ones. */
export function deferredHooks() {
  return Object.fromEntries(DEFERRED.map((name) => [name, placeholder(name)]))
}

/**
 * Arm the fetch and swap the placeholders out when it lands (#511).
 *
 * `map` is the object LiveView was handed, so overwriting its entries means every element that
 * mounts after the bundle arrives gets the real hook directly, with no promise in the way.
 *
 * Right after the first frame — NOT at idle. Idle was the first cut and it was wrong: on a quiet
 * machine it fires in tens of milliseconds, but it is a promise about the main thread, not about
 * time, and the e2e suite caught the gap it leaves (an emoji picker that ignores the first click,
 * a send with no optimistic bubble). Interaction-only does not mean late: a person can press
 * something 300 ms after the page appears.
 *
 * What the split is actually worth is unchanged by this. The boot bundle still parses and executes
 * alone, and the socket still connects, before a byte of this one is asked for; it just stops
 * being 28 KB gzip of work sitting in front of the connection. The gesture triggers stay as the
 * floor for a browser where the frame callback never runs (a tab that opens in the background).
 */
export function armDeferredHooks(map) {
  const fetchNow = () =>
    loadAll().then((registry) => {
      Object.assign(map, registry)
    })

  requestAnimationFrame(() => setTimeout(fetchNow, 0))

  for (const type of ["pointerdown", "touchstart", "keydown", "focusin"]) {
    window.addEventListener(type, fetchNow, {
      capture: true,
      once: true,
      passive: true,
    })
  }
}
