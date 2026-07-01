// Multi-select (Telegram-style): menu "Select" enters the mode, tapping rows toggles them,
// the bottom bar shows the count, Copy assembles the text + exits, Escape exits.
const { test, expect, send, openMenu } = require("../helpers/fixtures")

test("select mode: enter, toggle rows, copy exits (#multiselect)", async ({ alice, seed }) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  const a = `sel-a ${Date.now()}`
  const b = `sel-b ${Date.now()}`
  await send(alice, a)
  await send(alice, b)

  // Enter select mode from the message menu (opened on the bubble = the ContextMenu host).
  const bubbleA = alice.locator(".ed-bubble", { hasText: a }).first()
  const rowA = alice.locator(".ed-msg", { hasText: a }).first()
  const menu = await openMenu(alice, bubbleA)
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await expect(alice.locator(".ed-selbar")).toBeVisible()
  await expect(rowA).toHaveClass(/ed-msg--selected/)
  await expect(alice.locator(".ed-selbar__count")).toContainText("1")

  // Tap the other row (the click-catcher toggles it) → 2 selected.
  const rowB = alice.locator(".ed-msg", { hasText: b }).first()
  await rowB.locator(".ed-select-hit").click()
  await expect(rowB).toHaveClass(/ed-msg--selected/)
  await expect(alice.locator(".ed-selbar__count")).toContainText("2")

  // Tap rowB again → deselects → back to 1.
  await rowB.locator(".ed-select-hit").click()
  await expect(rowB).not.toHaveClass(/ed-msg--selected/)
  await expect(alice.locator(".ed-selbar__count")).toContainText("1")

  // Copy → assembles client-side, pings server → exits select mode, composer returns.
  await alice.locator("#selbar-copy").click()
  await expect(alice.locator(".ed-selbar")).toHaveCount(0)
  await expect(alice.locator("#composer")).toBeVisible()
})

test("Escape exits select mode (#multiselect)", async ({ alice, seed }) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const m = `esc-sel ${Date.now()}`
  await send(alice, m)
  const bubble = alice.locator(".ed-bubble", { hasText: m }).first()
  const menu = await openMenu(alice, bubble)
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await expect(alice.locator(".ed-selbar")).toBeVisible()
  await alice.keyboard.press("Escape")
  await expect(alice.locator(".ed-selbar")).toHaveCount(0)
  await expect(alice.locator("#composer")).toBeVisible()
})
