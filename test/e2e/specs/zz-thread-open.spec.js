// Opening the thread panel (#521 tail).
//
// `<aside :if={@thread_root && @selected}>` — the panel does not exist until the server answers,
// and before it answers it runs `list_thread`, a WRITE (`mark_thread_read`), `thread_follow_state`,
// `mark_compact` and a stream reset. On mobile that is a full-screen transition with no frame at
// all; on desktop a column that appears late.
const { test, expect } = require("../helpers/fixtures")

const LATENCY = 500
const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

test("the thread panel shows something before the server answers", async ({
  alice,
  seed,
}, testInfo) => {
  test.setTimeout(120_000)
  await alice.setViewportSize({ width: 1280, height: 880 })

  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(800)

  const opener = await alice.evaluate(() => {
    const btn = document.querySelector('#messages [phx-click="open_thread"]')
    return btn ? btn.getAttribute("phx-value-id") : null
  })
  expect(opener, "no thread to open on this stand").not.toBeNull()

  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  // Through the control's own click, not a pushed event: the placeholder is painted by the capture
  // click handler, so a programmatic push measures the server and nothing else. The control is a
  // hover-revealed quick action on desktop, and `.click()` reaches it regardless.
  const appeared = await alice.evaluate(async () => {
    const t0 = performance.now()
    let at = null
    const tick = () => {
      // Either the real panel or the placeholder standing in for it — the question is whether the
      // tap put ANYTHING on screen.
      if (at === null && document.querySelector(".ed-thread, .ed-thread-skel")) {
        at = performance.now() - t0
      }
      if (at === null && performance.now() - t0 < 2000) requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
    document.querySelector('#messages [phx-click="open_thread"]').click()
    await new Promise((r) => setTimeout(r, 1400))
    return at
  })

  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  const line = `thread panel appeared after ${appeared === null ? "never" : Math.round(appeared) + "ms"} (socket at ${LATENCY}ms)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(appeared, `${line} — the panel never came up`).not.toBeNull()
  expect(appeared, `${line} — nothing was on screen until the server answered`).toBeLessThan(
    LATENCY / 2,
  )

  // ...and the placeholder has to get out of the way. A shimmer that outlives the panel it stood
  // in for is worse than the wait it replaced.
  await expect(alice.locator(".ed-thread")).toBeVisible({ timeout: 10_000 })
  await alice.waitForTimeout(500)
  await expect(
    alice.locator(".ed-thread-skel"),
    "the placeholder stayed on screen under the real panel",
  ).toHaveCount(0)
})

// The threads LIST shares the same panel class and the same placeholder, so it has to dismiss it
// too — raised in review as a suspicion; checked here rather than argued (#567 review).
test("the threads list also clears the placeholder", async ({ alice, seed }) => {
  test.setTimeout(120_000)
  await alice.setViewportSize({ width: 1280, height: 880 })

  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(800)

  const has = await alice.evaluate(() => !!document.querySelector('[phx-click="open_threads"]'))
  test.skip(!has, "no threads-list control on this stand")

  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)
  const early = await alice.evaluate(() => {
    document.querySelector('[phx-click="open_threads"]').click()
    return !!document.querySelector(".ed-thread-skel")
  })
  expect(early, "the threads list opened with nothing on screen").toBe(true)

  await expect(alice.locator(".ed-thread")).toBeVisible({ timeout: 10_000 })
  await alice.waitForTimeout(500)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  await expect(
    alice.locator(".ed-thread-skel"),
    "the placeholder stayed under the threads list",
  ).toHaveCount(0)
})
