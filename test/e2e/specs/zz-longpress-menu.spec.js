// What a long press leaves behind (#521 follow-up, user report from iOS).
//
// Two things went wrong on a real phone and neither shows up on a desktop stand unless you drive
// touch: the press that OPENS the menu kept selecting text — iOS put its own "Copy | Look Up |
// Translate" callout over our items with a menu label highlighted — and lifting that same finger
// landed a click on whatever item was now under it, firing an action nobody chose.
const { test, expect, openMenu } = require("../helpers/fixtures")

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

// The guard, stated as what it does rather than as the gesture that motivates it: a click that
// arrives with no press of its own on the menu is the tail of the gesture that OPENED the menu,
// and it must not choose anything. A press that starts on the menu still works.
//
// Driven directly, not through a synthetic long press: holding a CDP touch on this stand does not
// raise the menu (the app's own helper opens it with `contextmenu`), and a test that cannot get to
// the state it is about proves nothing.
test("a click with no press of its own does not choose a menu item", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const body = `lp-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-flat", { hasText: body }).first()
  await expect(row).toBeVisible()

  const menu = await openMenu(alice, row)
  const item = menu.locator("[role=menuitem]:visible").first()
  await expect(item).toBeVisible()

  // The tail of the opening gesture: a click with no pointerdown on the menu.
  await item.dispatchEvent("click", { bubbles: true })
  await alice.waitForTimeout(400)
  await expect(menu, "an item fired from a click that had no press behind it").toBeVisible()

  // A real press chooses, as it must — the guard is not "the menu stopped working".
  const label = (await item.textContent()).trim()
  await item.click()
  await expect(menu, `pressing "${label}" did nothing — the guard swallowed a real press`).toBeHidden(
    { timeout: 5000 },
  )
})

test("the menu is not selectable text", async ({ alice, seed }) => {
  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const select = await alice.evaluate(() => {
    const m = document.querySelector(".ed-menu")
    if (!m) return null
    const cs = getComputedStyle(m)
    return { user: cs.userSelect || cs.webkitUserSelect, callout: cs.webkitTouchCallout }
  })
  expect(select, "no menu in the DOM to check").not.toBeNull()
  expect(select.user, "the menu's own labels are selectable").toBe("none")
})
