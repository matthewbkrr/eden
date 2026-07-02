// Carry-and-drop forward: carry a message (plaque on the composer), navigate ANYWHERE
// (survives remount via sessionStorage), and Send drops it — into a chat, a room, or a thread.
const { test, expect, send, openMenu } = require("../helpers/fixtures")

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

test("carry from a DM, cross to a room via the rail, drop it there (#forward)", async ({
  alice,
  seed,
}, testInfo) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const text = `carry ${testInfo.project.name} ${Date.now()}`
  await send(alice, text)

  // Forward → the message is carried (plaque appears).
  const bubble = alice.locator(".ed-bubble", { hasText: text }).first()
  const menu = await openMenu(alice, bubble)
  await menu.locator(".ed-menu__item", { hasText: "Forward" }).click()
  await expect(alice.locator(".ed-reply-bar--forward")).toBeVisible()

  // Cross to the channel via the rail (a live_navigate → REMOUNT). The plaque must survive
  // (re-hydrated from sessionStorage by the .ForwardCarry hook).
  await alice.locator(`.ed-rail a[href*="/channels/${seed.channel_id}"]`).first().click()
  await expect(alice).toHaveURL(new RegExp(`/channels/${seed.channel_id}`))
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await expect(alice.locator(".ed-reply-bar--forward")).toBeVisible()

  // Send drops it into the room.
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  await expect(alice.locator("#messages .ed-flat", { hasText: text })).toBeVisible({
    timeout: 10_000,
  })
  await expect(alice.locator(".ed-reply-bar--forward")).toHaveCount(0)
})

test("forward a message INTO a specific thread (#forward)", async ({ alice, seed }, testInfo) => {
  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  // A room root + open its thread.
  const rootText = `troot ${Date.now()}`
  await send(alice, rootText)
  const rootRow = alice.locator("#messages .ed-flat", { hasText: rootText }).first()
  const rmenu = await openMenu(alice, rootRow)
  await rmenu.getByText("Reply in thread", { exact: true }).click()
  await expect(alice.locator("#reply-composer")).toBeVisible()

  // Another room message to carry.
  const carry = `into-thread ${Date.now()}`
  await send(alice, carry)
  const carryRow = alice.locator("#messages .ed-flat", { hasText: carry }).first()
  const cmenu = await openMenu(alice, carryRow)
  await cmenu.locator(".ed-menu__item", { hasText: "Forward" }).click()
  await expect(alice.locator("#reply-composer .ed-reply-bar--forward")).toBeVisible()

  // Send from the THREAD composer → forwards into the thread (a reply).
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
  await expect(alice.locator("#thread-replies .ed-flat", { hasText: carry })).toBeVisible({
    timeout: 12_000,
  })
})

// Regression (#stream-append): in a MULTI-DAY room (DateRail separators present), a new
// message/forward must land at the BOTTOM of the stream — not merely exist in the DOM.
// A non-stream child inside #messages used to poison LiveView's append anchoring, landing
// appends at the TOP (off-screen → "only shows after refresh"), incl. after a reload.
const lastRowId = (page) => page.evaluate(() => {
  const rows = [...document.querySelectorAll('#messages [id^="messages-"]')]
  return rows.length ? rows[rows.length - 1].id : null
})

test("sends + forwards land at the BOTTOM of a multi-day room, incl. after reload (#forward)", async ({
  alice,
  seed,
}) => {
  const room = `/channels/${seed.channel_id}/r/${seed.general_room_id}`
  const check = async (label) => {
    const msg = `${label} ${Date.now()}`
    await send(alice, msg)
    const row = alice.locator("#messages .ed-flat", { hasText: msg }).first()
    await expect(row).toBeVisible({ timeout: 10000 })
    expect(await row.getAttribute("id"), `${label}: send must be the last row`).toBe(await lastRowId(alice))
    const beforeFwd = await lastRowId(alice)
    const menu = await openMenu(alice, row)
    await menu.locator(".ed-menu__item", { hasText: "Forward" }).click()
    await expect(alice.locator(".ed-reply-bar--forward").first()).toBeVisible()
    await alice.locator("#composer").evaluate((f) => f.requestSubmit())
    await expect
      .poll(async () => (await lastRowId(alice)) !== beforeFwd, { timeout: 8000 })
      .toBe(true)
    const last = await lastRowId(alice)
    expect(
      await alice.evaluate((id) => !!document.getElementById(id)?.querySelector(".ed-forwarded"), last),
      `${label}: forwarded copy must be the last row`,
    ).toBe(true)
  }
  await alice.goto(room)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForTimeout(800)
  await check("MOUNT-1")
  await alice.reload()
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForTimeout(800)
  await check("MOUNT-2")
})

// Regression: picking up a forward must NOT resurrect the last-sent text in the composer.
// The hook send path cleared the input client-side only; the stale @composer assign then
// got patched back into the (unfocused) textarea when the carry plaque re-rendered the form.
// Also: a successful drop shows NO flash (the copy lands visibly at the bottom).
test("forward pickup keeps the composer empty and drop shows no success flash (#forward)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const msg = `stale-input ${Date.now()}`
  await send(alice, msg)
  const bubble = alice.locator(".ed-bubble", { hasText: msg }).first()
  await expect(bubble).toBeVisible()

  // Pick up the forward → the plaque re-renders the form; the input must stay EMPTY.
  const menu = await openMenu(alice, bubble)
  await menu.locator(".ed-menu__item", { hasText: "Forward" }).click()
  await expect(alice.locator(".ed-reply-bar--forward").first()).toBeVisible()
  await expect(alice.locator("#composer-body")).toHaveValue("")

  // Drop it → lands at the bottom, and NO success flash appears.
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  await expect(alice.locator(".ed-bubble", { hasText: msg })).toHaveCount(2, { timeout: 8000 })
  await expect(alice.locator("#flash-info, .ed-flash--info, [role=alert]:has-text('Forwarded')")).toHaveCount(0)
  await expect(alice.locator("#composer-body")).toHaveValue("")
})
