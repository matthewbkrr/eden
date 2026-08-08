// The app asks in its own clothes (#518).
//
// In a WKWebView `window.confirm` is a SYSTEM alert titled with the origin — the loudest tell that
// this is a web page and not an app. Seventeen `data-confirm` attributes went through LiveView's
// call to it, plus two direct calls of our own.
const { test, expect, send, openMenu } = require("../helpers/fixtures")

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

// Any system dialog would hang the test rather than fail it (nothing dismisses it), so the page is
// told to report one instead of showing it.
const trapNative = (page) =>
  page.evaluate(() => {
    window.__native = []
    window.confirm = (t) => {
      window.__native.push(`confirm:${t}`)
      return false
    }
    window.alert = (t) => window.__native.push(`alert:${t}`)
  })

test("a destructive action asks in the app's own dialog, not the system one", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  const body = `ask-me ${Date.now()}`
  await send(alice, body)
  await trapNative(alice)

  const menu = await openMenu(alice, alice.locator(".ed-bubble", { hasText: body }).first())
  await menu.locator(".ed-menu__item", { hasText: "Delete for everyone" }).click()

  const ask = alice.locator(".ed-ask")
  await expect(ask, "the app's dialog did not appear").toBeVisible({ timeout: 5000 })
  expect(
    await alice.evaluate(() => window.__native),
    "a system dialog was used",
  ).toEqual([])

  // Cancel means cancel: the message is still there.
  await ask.locator("[data-cancel]").last().click()
  await expect(ask).toHaveCount(0)
  await expect(alice.locator(".ed-bubble", { hasText: body })).toBeVisible()

  // ...and confirming actually goes through to the server.
  const menu2 = await openMenu(alice, alice.locator(".ed-bubble", { hasText: body }).first())
  await menu2.locator(".ed-menu__item", { hasText: "Delete for everyone" }).click()
  await alice.locator(".ed-ask [data-ok]").click()
  await expect(alice.locator(".ed-bubble", { hasText: body })).toHaveCount(0, { timeout: 10_000 })
})

test("Escape cancels, and the keyboard cannot leave the dialog", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)
  await trapNative(alice)

  // Braces on purpose: an arrow that RETURNS the promise makes page.evaluate wait for it, and it
  // only settles when this test presses Escape — a deadlock the first version of this file hit.
  await alice.evaluate(() => {
    window.__edConfirm("Delete this?").then((v) => (window.__answer = v))
  })
  await expect(alice.locator(".ed-ask")).toBeVisible()

  // Tab round-trips inside the card rather than walking out into the chat behind it.
  const inside = []
  for (let i = 0; i < 4; i++) {
    await alice.keyboard.press("Tab")
    inside.push(await alice.evaluate(() => !!document.activeElement?.closest(".ed-ask")))
  }
  expect(inside, `focus left the dialog: ${inside}`).toEqual([true, true, true, true])

  await alice.keyboard.press("Escape")
  await expect(alice.locator(".ed-ask")).toHaveCount(0)
  expect(await alice.evaluate(() => window.__answer), "Escape did not answer no").toBe(false)
})

// The seventeen server-rendered ones go through LiveView's own path, which calls window.confirm
// directly — the interceptor has to take the click before LiveView sees it.
test("a data-confirm button never reaches the system dialog", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)
  await trapNative(alice)

  // The sidebar's chat menu carries a real one ("Delete chat"), and the click is cancelled below,
  // so nothing is actually deleted.
  const row = alice.locator("#conversations .ed-convo-wrap").first()
  const menu = await openMenu(alice, row)
  // :visible — the menu carries both the group and the direct variants, hidden by data-needs until
  // it is filled for a row.
  const item = menu.locator("[data-confirm]:visible").first()
  await expect(item, "the chat menu no longer has a data-confirm item").toBeVisible({
    timeout: 10_000,
  })

  await item.click()
  await expect(alice.locator(".ed-ask"), "the app's dialog did not appear").toBeVisible({
    timeout: 5000,
  })
  expect(await alice.evaluate(() => window.__native), "a system dialog was used").toEqual([])
  await alice.locator(".ed-ask [data-cancel]").last().click()
  await expect(alice.locator(".ed-ask")).toHaveCount(0)
})
