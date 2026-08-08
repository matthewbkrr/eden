// Hooks that only matter once someone interacts (#511).
//
// The chat bundle is 86 KB gzip against a 60 KB budget, and most of it is machinery nobody needs to
// SEE the chat: the photo viewer, the send/upload engine, the context menu, the emoji picker, the
// drag-and-drop zones. Those are loaded as separate chunks and pulled in right after the socket
// connects, so the boot bundle carries only what the first paint needs.
//
// Two things make that safe rather than clever:
//
//   * the wrapper QUEUES lifecycle calls that land before the chunk does, and replays them in
//     order once it arrives — a hook whose `mounted()` ran late still sees `mounted` first;
//   * the chunks are prefetched on idle straight after boot, so by the time a finger reaches a
//     photo the module is already in memory. Over a 160ms cross-border link, waiting for the
//     fetch AT the tap would have traded 23 KB of boot for a visibly late first interaction.
//
// A hook that must act on the very first frame (feed positioning, day chips, timestamps, instant
// navigation) stays in the boot bundle — see index.js.

const CALLBACKS = ["mounted", "beforeUpdate", "updated", "destroyed", "disconnected", "reconnected"]

// Every chunk this file knows how to fetch, so boot can warm them all in one pass.
const loaders = new Set()

export function lazyHook(load) {
  loaders.add(load)
  let mod = null
  let loading = null

  const ensure = () => {
    if (mod) return Promise.resolve(mod)
    if (!loading) {
      loading = load().then((m) => {
        mod = m.default
        return mod
      })
    }
    return loading
  }

  const hook = {}
  for (const cb of CALLBACKS) {
    hook[cb] = function (...args) {
      if (mod) return mod[cb]?.apply(this, args)
      // Not here yet: remember the call against THIS element and replay it in order. `destroyed`
      // for an element that never got its `mounted` replayed is dropped along with the queue —
      // there is nothing to tear down.
      this.__lazyQueue = this.__lazyQueue || []
      this.__lazyQueue.push([cb, args])
      if (cb === "destroyed") {
        this.__lazyGone = true
        return
      }
      ensure().then(() => {
        const queue = this.__lazyQueue
        this.__lazyQueue = null
        if (!queue || this.__lazyGone) return
        for (const [name, a] of queue) mod[name]?.apply(this, a)
      })
    }
  }
  return hook
}

/**
 * Warm every lazy chunk once the app is up. Idle time, so it never competes with the first paint
 * or the socket handshake; a browser without requestIdleCallback gets a plain timeout.
 */
export function warmLazyHooks() {
  const run = () => loaders.forEach((load) => load().catch(() => {}))
  if (typeof requestIdleCallback === "function") requestIdleCallback(run, { timeout: 3000 })
  else setTimeout(run, 1200)
}
