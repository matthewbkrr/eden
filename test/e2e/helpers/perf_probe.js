// Smoothness probe (UX audit): measures frame cadence + long tasks inside the page while a
// scenario runs. A rAF loop records inter-frame deltas (a delta > 32ms = at least one dropped
// frame at 60Hz); PerformanceObserver(longtask) counts main-thread stalls > 50ms (Chromium —
// try/caught elsewhere). Use with CPU throttling (Chromium CDP) so jank that only bites slow
// devices shows up on the fast dev machine.
//
// Usage per scenario:
//   await throttleCPU(page, 4)         // Chromium projects only; no-op elsewhere
//   await startProbe(page)
//   ...perform the flow...
//   const m = await stopProbe(page)    // { total, dropped, droppedPct, worst, long, longWorst }

async function startProbe(page) {
  await page.evaluate(() => {
    const prev = window.__perfProbe
    if (prev) {
      prev.running = false
      prev.obs?.disconnect?.()
    }
    const p = (window.__perfProbe = { frames: [], long: [], running: true })
    let last = performance.now()
    const tick = (now) => {
      if (!p.running) return
      p.frames.push(now - last)
      last = now
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
    try {
      p.obs = new PerformanceObserver((list) => {
        for (const e of list.getEntries()) p.long.push(e.duration)
      })
      p.obs.observe({ entryTypes: ["longtask"] })
    } catch (_e) {
      /* longtask is Chromium-only; frame cadence still works everywhere */
    }
  })
}

async function stopProbe(page) {
  return page.evaluate(() => {
    const p = window.__perfProbe
    if (!p) return null
    p.running = false
    p.obs?.disconnect?.()
    // Drop the first delta: it spans probe installation, not a rendered frame.
    const frames = p.frames.slice(1)
    const dropped = frames.filter((d) => d > 32).length
    const worst = frames.length ? Math.max(...frames) : 0
    return {
      total: frames.length,
      dropped,
      droppedPct: frames.length ? Math.round((dropped / frames.length) * 100) : 0,
      worst: Math.round(worst),
      long: p.long.length,
      longWorst: p.long.length ? Math.round(Math.max(...p.long)) : 0,
    }
  })
}

// Chromium-only CPU throttling (CDP). Returns true when applied, false elsewhere — callers
// record the flag so unthrottled WebKit/Firefox numbers aren't compared against throttled ones.
async function throttleCPU(page, rate) {
  try {
    const session = await page.context().newCDPSession(page)
    await session.send("Emulation.setCPUThrottlingRate", { rate })
    return true
  } catch (_e) {
    return false
  }
}

module.exports = { startProbe, stopProbe, throttleCPU }
