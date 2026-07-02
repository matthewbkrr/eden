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

test("forward the selection: carry many from a DM, drop into a room (#multiselect)", async ({
  alice,
  seed,
}, testInfo) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const f1 = `fwd-1 ${testInfo.project.name} ${Date.now()}`
  const f2 = `fwd-2 ${testInfo.project.name} ${Date.now()}`
  await send(alice, f1)
  await send(alice, f2)

  // Select both, then Forward from the bar → the carry plaque shows a count; select mode exits.
  const menu = await openMenu(alice, alice.locator(".ed-bubble", { hasText: f1 }).first())
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await alice.locator(".ed-msg", { hasText: f2 }).first().locator(".ed-select-hit").click()
  await expect(alice.locator(".ed-selbar__count")).toContainText("2")
  await alice.locator(".ed-selbar button", { hasText: "Forward" }).click()
  await expect(alice.locator(".ed-selbar")).toHaveCount(0)
  await expect(alice.locator(".ed-reply-bar--forward")).toBeVisible()
  await expect(alice.locator(".ed-reply-bar--forward")).toContainText("2")

  // Cross to a room via the rail (remount) — the plaque survives (sessionStorage re-hydrate).
  await alice.locator(`.ed-rail a[href*="/channels/${seed.channel_id}"]`).first().click()
  await expect(alice).toHaveURL(new RegExp(`/channels/${seed.channel_id}`))
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await expect(alice.locator(".ed-reply-bar--forward")).toBeVisible()

  // Send drops both into the room, in order.
  await alice.locator("#composer").evaluate((form) => form.requestSubmit())
  await expect(alice.locator("#messages .ed-flat", { hasText: f1 })).toBeVisible({ timeout: 10_000 })
  await expect(alice.locator("#messages .ed-flat", { hasText: f2 })).toBeVisible({ timeout: 10_000 })
  await expect(alice.locator(".ed-reply-bar--forward")).toHaveCount(0)
})

test("Escape in the delete dialog closes only the dialog, keeping the selection (#multiselect)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const a = `keep-sel-a ${Date.now()}`
  const b = `keep-sel-b ${Date.now()}`
  await send(alice, a)
  await send(alice, b)

  const menu = await openMenu(alice, alice.locator(".ed-bubble", { hasText: a }).first())
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await alice.locator(".ed-msg", { hasText: b }).first().locator(".ed-select-hit").click()
  await expect(alice.locator(".ed-selbar__count")).toContainText("2")

  // Open the confirm sheet, then Escape → only the dialog closes; the selection survives.
  await alice.locator(".ed-selbar button", { hasText: "Delete" }).click()
  await expect(alice.locator("#dlg-delete")).toBeVisible()
  await alice.keyboard.press("Escape")
  await expect(alice.locator("#dlg-delete")).toHaveCount(0)
  await expect(alice.locator(".ed-selbar")).toBeVisible()
  await expect(alice.locator(".ed-selbar__count")).toContainText("2")
})

test("deselecting the last message exits select mode; aria-pressed reflects state (#multiselect)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const m = `solo-sel ${Date.now()}`
  await send(alice, m)

  const menu = await openMenu(alice, alice.locator(".ed-bubble", { hasText: m }).first())
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  const row = alice.locator(".ed-msg", { hasText: m }).first()
  // a11y: the selected row's overlay reports aria-pressed=true.
  await expect(row.locator(".ed-select-hit")).toHaveAttribute("aria-pressed", "true")

  // Deselect the only selection → the mode auto-exits (no dead bar).
  await row.locator(".ed-select-hit").click()
  await expect(alice.locator(".ed-selbar")).toHaveCount(0)
  await expect(alice.locator("#composer")).toBeVisible()
})

test("shift-click selects the whole range (#multiselect)", async ({ alice, seed }) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const base = Date.now()
  const texts = [0, 1, 2, 3].map((i) => `range-${i} ${base}`)
  for (const t of texts) await send(alice, t)

  // Enter select on the first, then shift-click the last → all four selected.
  const menu = await openMenu(alice, alice.locator(".ed-bubble", { hasText: texts[0] }).first())
  await menu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await expect(alice.locator(".ed-selbar__count")).toContainText("1")

  await alice
    .locator(".ed-msg", { hasText: texts[3] })
    .first()
    .locator(".ed-select-hit")
    .click({ modifiers: ["Shift"] })

  await expect(alice.locator(".ed-selbar__count")).toContainText("4")
  for (const t of texts) {
    await expect(alice.locator(".ed-msg", { hasText: t }).first()).toHaveClass(/ed-msg--selected/)
  }
})

test("selecting in a thread opens select mode IN THE THREAD, not the room (#multiselect)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  // A root + open its thread + post a reply.
  const rootText = `sel-root ${Date.now()}`
  await send(alice, rootText)
  const rootRow = alice.locator("#messages .ed-flat", { hasText: rootText }).first()
  const rmenu = await openMenu(alice, rootRow)
  await rmenu.getByText("Reply in thread", { exact: true }).click()
  await expect(alice.locator("#reply-composer")).toBeVisible()
  const reply = `sel-reply ${Date.now()}`
  await alice.locator("#reply-body").fill(reply)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
  const replyRow = alice.locator("#thread-replies .ed-flat", { hasText: reply }).first()
  await expect(replyRow).toBeVisible({ timeout: 12_000 })

  // Select the reply → the bar appears; the THREAD container enters select mode, the ROOM does not.
  const smenu = await openMenu(alice, replyRow)
  await smenu.locator(".ed-menu__item", { hasText: "Select" }).click()
  await expect(alice.locator(".ed-selbar")).toBeVisible()
  await expect(alice.locator("#thread-replies")).toHaveClass(/ed-selecting/)
  await expect(alice.locator("#messages")).not.toHaveClass(/ed-selecting/)
  await expect(replyRow).toHaveClass(/ed-flat--selected/)
  // The bar sits in the thread panel (its container targets #thread-replies).
  await expect(alice.locator(".ed-selbar")).toHaveAttribute("data-container", "#thread-replies")

  // Escape exits.
  await alice.keyboard.press("Escape")
  await expect(alice.locator(".ed-selbar")).toHaveCount(0)
  await expect(alice.locator("#reply-composer")).toBeVisible()
})

test("forwarding from a thread carries into the room, not back into the thread (#multiselect)", async ({ alice, seed }) => {
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const root = `vf-root ${Date.now()}`
  await send(alice, root)
  const rmenu = await openMenu(alice, alice.locator("#messages .ed-flat", { hasText: root }).first())
  await rmenu.getByText("Reply in thread", { exact: true }).click()
  await expect(alice.locator("#reply-composer")).toBeVisible()
  const rep = `vf-reply ${Date.now()}`
  await alice.locator("#reply-body").fill(rep)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
  await expect(alice.locator("#thread-replies .ed-flat", { hasText: rep }).first()).toBeVisible({ timeout: 12000 })

  // Select in thread, Forward from the thread bar.
  const m = await openMenu(alice, alice.locator("#thread-replies .ed-flat", { hasText: rep }).first())
  await m.locator(".ed-menu__item", { hasText: "Select" }).click()
  await alice.locator('.ed-selbar button').filter({ hasText: "Forward" }).click().catch(async () => {
    await alice.locator('.ed-selbar button').nth(1).click()  // icon-only: Forward is the 2nd button
  })

  // The thread auto-closed → we're in the room, plaque on the main composer.
  await expect(alice.locator("#reply-composer")).toHaveCount(0)
  await expect(alice.locator("#composer [data-forward-active]")).toBeVisible()

  // Send in the room → the reply is forwarded as a top-level room message.
  const before = await alice.locator("#messages .ed-flat", { hasText: rep }).count()
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  await expect(alice.locator("#messages .ed-flat", { hasText: rep })).toHaveCount(before + 1, { timeout: 10000 })
  await expect(alice.locator(".ed-reply-bar--forward")).toHaveCount(0)
})
