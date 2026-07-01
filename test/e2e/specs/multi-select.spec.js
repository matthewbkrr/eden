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

test("delete-for-everyone offered when all mine; tombstones them (#multiselect)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const a1 = `del-a1 ${Date.now()}`
  const a2 = `del-a2 ${Date.now()}`
  await send(alice, a1)
  await send(alice, a2)

  const menu = await openMenu(alice, alice.locator(".ed-bubble", { hasText: a1 }).first())
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await alice.locator(".ed-msg", { hasText: a2 }).first().locator(".ed-select-hit").click()
  await expect(alice.locator(".ed-selbar__count")).toContainText("2")

  // Delete → confirm sheet offers "for everyone" (both are mine).
  await alice.locator(".ed-selbar button", { hasText: "Delete" }).click()
  await expect(alice.locator("#dlg-delete")).toBeVisible()
  await alice.locator("#dlg-delete button", { hasText: "Delete for everyone" }).click()

  // Exits select mode; both originals are gone (tombstoned).
  await expect(alice.locator(".ed-selbar")).toHaveCount(0)
  await expect(alice.locator(".ed-bubble", { hasText: a1 })).toHaveCount(0, { timeout: 8000 })
  await expect(alice.locator(".ed-bubble", { hasText: a2 })).toHaveCount(0)
})

test("mixed selection offers only delete-for-me; removes them for me (#multiselect)", async ({
  alice,
  bob,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await bob.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await bob.waitForFunction(() => window.liveSocket?.isConnected())

  const mine = `mix-mine ${Date.now()}`
  const theirs = `mix-theirs ${Date.now()}`
  await send(alice, mine)
  await send(bob, theirs)
  await expect(alice.locator(".ed-bubble", { hasText: theirs })).toBeVisible({ timeout: 8000 })

  // Select one of mine + one of theirs.
  const menu = await openMenu(alice, alice.locator(".ed-bubble", { hasText: mine }).first())
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await alice.locator(".ed-msg", { hasText: theirs }).first().locator(".ed-select-hit").click()
  await expect(alice.locator(".ed-selbar__count")).toContainText("2")

  // Delete → only "for me" (a peer message is selected).
  await alice.locator(".ed-selbar button", { hasText: "Delete" }).click()
  await expect(alice.locator("#dlg-delete")).toBeVisible()
  await expect(alice.locator("#dlg-delete button", { hasText: "Delete for everyone" })).toHaveCount(0)
  await alice.locator("#dlg-delete button", { hasText: "Delete for me" }).click()

  // Both vanish for alice; bob still sees his own.
  await expect(alice.locator(".ed-selbar")).toHaveCount(0)
  await expect(alice.locator(".ed-bubble", { hasText: mine })).toHaveCount(0, { timeout: 8000 })
  await expect(alice.locator(".ed-bubble", { hasText: theirs })).toHaveCount(0)
  await expect(bob.locator(".ed-bubble", { hasText: theirs })).toBeVisible()
})
