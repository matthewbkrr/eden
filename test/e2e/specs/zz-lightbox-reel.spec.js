// The conversation reel (#466): the viewer pages the WHOLE dialog's media, shows a
// thumbnail strip, and its arrows live in wide hit zones so a near-miss pages
// instead of closing (audit finding).
const { test, expect } = require("../helpers/fixtures")

async function open(page, seed) {
  await page.goto(`/app/c/${seed.dm_id}`)
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await page.locator("#messages a.ed-photo").last().click()
  await page.waitForSelector("dialog#ed-lightbox[open]")
  // The first server page widens the reel past the album it opened from.
  await page.waitForFunction(() => document.getElementById("ed-lightbox").__anchored === true, null, {
    timeout: 8000,
  })
}

test("the reel spans the conversation, not just the album", async ({ alice, seed }, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await open(page, seed)
  const st = await page.evaluate(() => {
    const b = document.getElementById("ed-lightbox")
    return { items: b.__items().length, total: b.__total, count: document.querySelector(".ed-lightbox__count").textContent }
  })
  expect(st.items, "more than one album's worth of media").toBeGreaterThan(3)
  expect(st.total).toBeGreaterThanOrEqual(st.items)
  // The counter is an honest position in the whole conversation.
  expect(st.count.endsWith(` ${st.total}`), `counter ends with the total (${st.count})`).toBe(true)
  await page.keyboard.press("Escape")
})

test("the strip renders, marks the current photo and jumps on tap", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await open(page, seed)
  const strip = page.locator(".ed-lightbox__strip")
  await expect(strip).toBeVisible()
  await expect(page.locator(".ed-lightbox__thumb--on")).toHaveCount(1)

  const before = await page.evaluate(() => document.querySelector(".ed-lightbox__slide--cur img").src)
  const thumbs = page.locator(".ed-lightbox__thumb")
  await thumbs.first().click()
  await expect
    .poll(async () => page.evaluate(() => document.querySelector(".ed-lightbox__slide--cur img").src))
    .not.toBe(before)
  // The viewer stayed open — the strip is chrome, not backdrop.
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(1)
  await page.keyboard.press("Escape")
})

test("a near-miss beside the arrow pages instead of closing", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "desktop zones")
  const page = alice
  await open(page, seed)
  const before = await page.evaluate(() => document.querySelector(".ed-lightbox__slide--cur img").src)
  // Click inside the previous zone but NOT on the button itself.
  const zone = await page.locator(".ed-lightbox__zone--prev").boundingBox()
  await page.mouse.click(zone.x + 8, zone.y + 40)
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(1)
  await expect
    .poll(async () => page.evaluate(() => document.querySelector(".ed-lightbox__slide--cur img").src))
    .not.toBe(before)
  await page.keyboard.press("Escape")
})

test("touch: the track follows the finger and commits the neighbour", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(!testInfo.project.name.startsWith("mobile"), "touch carousel")
  const page = alice
  await open(page, seed)
  const touch = (type, x, y) =>
    page.dispatchEvent("#ed-lightbox", type, {
      touches: type === "touchend" ? [] : [{ identifier: 1, clientX: x, clientY: y }],
      changedTouches: [{ identifier: 1, clientX: x, clientY: y }],
      targetTouches: type === "touchend" ? [] : [{ identifier: 1, clientX: x, clientY: y }],
    })
  const src = () => page.evaluate(() => document.querySelector(".ed-lightbox__slide--cur img").src)
  const before = await src()

  // Drag toward the older end (the opened photo is the newest, so the other way
  // would only rubber-band).
  await touch("touchstart", 100, 400)
  const offsets = []
  for (const x of [130, 190, 250, 310]) {
    await touch("touchmove", x, 402)
    offsets.push(
      await page.evaluate(() => {
        const m = /translate3d\((-?\d+(?:\.\d+)?)px/.exec(
          document.querySelector(".ed-lightbox__track").style.transform,
        )
        return m ? Number(m[1]) : null
      }),
    )
  }
  // The track TRACKS the finger — each move leaves it further right than the last.
  expect(offsets.every((v, k) => k === 0 || v > offsets[k - 1]), `track follows: ${offsets}`).toBe(true)

  await touch("touchend", 310, 402)
  await expect.poll(async () => src()).not.toBe(before)
})

test("mobile: the strip is there, the desktop zones are not", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(!testInfo.project.name.startsWith("mobile"), "touch layout")
  const page = alice
  await open(page, seed)
  await expect(page.locator(".ed-lightbox__strip")).toBeVisible()
  const zoneShown = await page.evaluate(
    () => getComputedStyle(document.querySelector(".ed-lightbox__zone")).display,
  )
  expect(zoneShown, "zones would eat taps on a phone").toBe("none")
})
