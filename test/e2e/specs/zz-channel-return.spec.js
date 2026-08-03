// Coming back to the messenger from a channel (#558).
//
// `#conversations` is a `phx-update="stream"` container, and channel mode does not render it. A
// stream is consumed by the render that receives it: once the container leaves the DOM the rows
// are gone, so returning to the messenger mounted it EMPTY — the person was met by "no chats yet"
// and a button to start one, with every conversation they have sitting untouched in the database.
//
// It looked intermittent because opening any chat repopulated the list.
const { test, expect } = require("../helpers/fixtures")

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

test("the chat list survives a trip through a channel", async ({ alice, seed }) => {
  test.setTimeout(120_000)
  const rows = alice.locator("#conversations .ed-convo-wrap")

  await alice.goto("/app")
  await ready(alice)
  const before = await rows.count()
  expect(before, "no chats to lose on this stand").toBeGreaterThan(0)

  // Into a channel and into a room, the way a finger does it: the rail, then the room list.
  await alice.locator(`.ed-rail a[href*="/channels/${seed.channel_id}"]`).first().click()
  await alice.waitForTimeout(800)
  await alice.locator(`.ed-room-wrap[data-id="${seed.general_room_id}"] a`).first().click()
  await alice.locator(`#message-scroll[data-conversation-id="${seed.general_room_id}"]`).waitFor()
  await alice.waitForTimeout(600)

  // ...and back to the messenger.
  await alice.locator('.ed-rail a[href^="/app"]').first().click()
  await alice.waitForTimeout(1200)

  const after = await rows.count()
  expect(after, `the chat list came back empty: ${before} rows before, ${after} after`).toBe(before)

  // And the empty state must not be on screen next to a full list.
  const emptyState = alice.locator("#conversations-empty, [data-empty-chats]")
  if (await emptyState.count()) {
    await expect(emptyState.first()).toBeHidden()
  }
})
