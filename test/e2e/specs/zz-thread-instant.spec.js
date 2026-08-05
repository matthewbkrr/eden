// The thread panel's own latency (#521, part of epic #506).
//
// Closing it on DESKTOP goes straight through `phx-click`: the panel is `:if={@thread_root}` on the
// server, so it stays on screen until the diff comes back. Mobile already slides it away first —
// the intercept that does that is gated on `max-width: 767px`.
//
// As everywhere in this cluster, the socket is slowed deliberately: on this stand a round trip is
// a few milliseconds and everything looks instant.
const { test, expect } = require("../helpers/fixtures")

const LATENCY = 400

const openThread = async (page, seed) => {
  test.skip(!seed.thread_reply_id, "no seeded thread on this stand")
  // A reply permalink opens the panel directly — no gestures, no context menu.
  await page.goto(
    `/channels/${seed.channel_id}/r/${seed.general_room_id}/m/${seed.thread_reply_id}`,
  )
  await page.waitForFunction(() => window.liveSocket?.isConnected())
  await page.locator(".ed-thread").waitFor({ timeout: 15_000 })
  await page.waitForTimeout(600)
}

test("closing the thread panel on desktop answers the click", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)
  await alice.setViewportSize({ width: 1280, height: 880 })
  await openThread(alice, seed)

  // There are two close controls — one for each layout — and only one is on screen at a time.
  const closer = alice
    .locator('.ed-thread [phx-click="close_thread"]:visible, .ed-thread [phx-click="close_threads"]:visible')
    .first()
  await expect(closer).toBeVisible()

  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  // Watch the panel: how long until it stops being on screen?
  await alice.evaluate(() => {
    window.__gone = null
    window.__t0 = performance.now()
    const panel = document.querySelector(".ed-thread")
    const tick = () => {
      if (window.__gone !== null) return
      const p = document.querySelector(".ed-thread")
      const hidden = !p || p.hidden || getComputedStyle(p).display === "none" || !p.isConnected
      if (hidden) window.__gone = performance.now() - window.__t0
      else requestAnimationFrame(tick)
    }
    if (panel) requestAnimationFrame(tick)
  })

  await closer.click()
  await alice.waitForTimeout(LATENCY / 2)
  const gone = await alice.evaluate(() => window.__gone)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  const line = `thread close: panel left after ${gone === null ? "the round trip" : Math.round(gone) + "ms"} (socket at ${LATENCY}ms)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(gone, `${line} — the panel sat there for the whole round trip`).not.toBeNull()
  expect(gone, line).toBeLessThan(LATENCY / 2)
})

// The hazard of hiding a node the server owns: it has to come back. morphdom drops the inline
// style when it re-renders the panel, but that is a claim worth holding down.
test("a thread panel hidden on close comes back on the next open", async ({ alice, seed }) => {
  test.setTimeout(120_000)
  await alice.setViewportSize({ width: 1280, height: 880 })
  await openThread(alice, seed)

  const closer = alice
    .locator('.ed-thread [phx-click="close_thread"]:visible, .ed-thread [phx-click="close_threads"]:visible')
    .first()
  await closer.click()
  await expect(alice.locator(".ed-thread")).toHaveCount(0, { timeout: 10_000 })

  // Open it again the same way.
  await openThread(alice, seed)

  const state = await alice.evaluate(() => {
    const p = document.querySelector(".ed-thread")
    return p && { display: p.style.display, computed: getComputedStyle(p).display }
  })
  expect(state, "the panel did not come back").not.toBeNull()
  expect(state.display, "the close-time inline style survived the re-open").toBe("")
  expect(state.computed).not.toBe("none")
})
