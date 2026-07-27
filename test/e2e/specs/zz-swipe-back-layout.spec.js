// Swipe-back layout invariants (#439): during the slide-out the chat pane must be a
// FIXED full-width layer over a full-width list — never an in-flow flex sibling
// squeezing the list (the post-#458 regression: a :not() specificity bump let the
// dropzone's relative beat .ed-main-pop's fixed, and every swipe showed a narrow
// list beside a white void for a full RTT). The thread sheet must stay fixed too —
// the original #348 cascade bug this all started from.
const { test, expect } = require("../helpers/fixtures")

test("swipe-back slides a fixed full-width pane; the list never squeezes", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(!testInfo.project.name.startsWith("mobile"))
  const page = alice
  await page.goto(`/app/c/${seed.dm_id}`)
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  const touch = (type, x) =>
    page.dispatchEvent("body", type, {
      touches: type === "touchend" ? [] : [{ identifier: 1, clientX: x, clientY: 400 }],
      changedTouches: [{ identifier: 1, clientX: x, clientY: 400 }],
      targetTouches: type === "touchend" ? [] : [{ identifier: 1, clientX: x, clientY: 400 }],
    })
  await touch("touchstart", 8)
  for (const x of [40, 90, 150, 210]) {
    await touch("touchmove", x)
    await page.waitForTimeout(30)
  }
  await touch("touchend", 210)
  await page.waitForTimeout(60)

  const mid = await page.evaluate(() => {
    const main = document.getElementById("chat-dropzone")
    const aside = document.querySelector(".ed-root > aside")
    return {
      pos: getComputedStyle(main).position,
      mainW: Math.round(main.getBoundingClientRect().width),
      asideRight: Math.round(aside.getBoundingClientRect().right),
      iw: innerWidth,
    }
  })
  expect(mid.pos, "sliding pane is a fixed layer").toBe("fixed")
  expect(mid.mainW, "pane spans the viewport").toBeGreaterThanOrEqual(mid.iw - 5)
  expect(mid.asideRight, "list fills to the right edge beneath").toBeGreaterThanOrEqual(mid.iw - 5)

  await expect(page).toHaveURL(/\/app$/, { timeout: 15_000 })
})

test("the thread sheet still computes fixed on mobile", async ({ alice, seed }, testInfo) => {
  test.skip(!testInfo.project.name.startsWith("mobile"))
  const page = alice
  await page.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await page.locator('[phx-click="open_thread"]').first().tap()
  await page.waitForSelector(".ed-thread", { timeout: 10_000 })
  const th = await page.evaluate(() => {
    const el = document.querySelector(".ed-thread")
    const r = el.getBoundingClientRect()
    return { pos: getComputedStyle(el).position, top: Math.round(r.top), h: Math.round(r.height) }
  })
  expect(th.pos).toBe("fixed")
  expect(th.top).toBe(0)
  expect(th.h).toBeGreaterThanOrEqual(600)
})
