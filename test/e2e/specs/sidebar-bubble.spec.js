const { test, expect, send } = require("../helpers/fixtures")

const order = (page) =>
  page.evaluate(() =>
    [...document.querySelectorAll("#conversations > [id^='conversations-']")].map((e) => e.id)
  )

// #194: sending in a chat that is NOT at the top of the sidebar bumps it to the top
// (stream_insert(at: 0) alone updates in place without repositioning, so it needs a
// delete + re-insert).
test("active chat bubbles to the top of the sidebar on send (#194)", async ({ alice }) => {
  await alice.goto("/app")
  await alice.waitForSelector("#conversations > [id^='conversations-']", { timeout: 15000 })
  await alice.waitForTimeout(500)

  const before = await order(alice)
  const target = before[1] // a chat NOT already at the top
  expect(target).toBeTruthy()

  await alice.locator("#" + target).click()
  await alice.waitForTimeout(400)
  await send(alice, "bubble to top")

  await expect.poll(async () => (await order(alice))[0], { timeout: 8000 }).toBe(target)
})

// #194: re-sending into the chat that is ALREADY at the top must NOT re-run the bump
// animation (it would delete+re-insert the row for no net move). The server keeps it in
// place; no row should pick up a transform.
test("re-sending into the top chat does not re-animate the list (#194)", async ({ alice }) => {
  await alice.goto("/app")
  await alice.waitForSelector("#conversations > [id^='conversations-']", { timeout: 15000 })
  await alice.waitForTimeout(500)

  const before = await order(alice)
  const target = before[1]
  await alice.locator("#" + target).click()
  await alice.waitForTimeout(400)
  await send(alice, "first") // bumps target to the top
  await expect.poll(async () => (await order(alice))[0], { timeout: 8000 }).toBe(target)
  await alice.waitForTimeout(700) // let the bump animation fully settle

  // Now target is on top; a second send must not move any row.
  await alice.evaluate(() => {
    window.__peak = 0
    window.__rec = setInterval(() => {
      document.querySelectorAll("#conversations > [id^='conversations-']").forEach((r) => {
        window.__peak = Math.max(window.__peak, Math.abs(new DOMMatrix(getComputedStyle(r).transform).m42))
      })
    }, 16)
  })
  await send(alice, "second")
  await alice.waitForTimeout(700)
  const peak = await alice.evaluate(() => {
    clearInterval(window.__rec)
    return window.__peak
  })
  expect(peak).toBeLessThan(1)
})
