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
