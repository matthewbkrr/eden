const { test, expect } = require("../helpers/fixtures")

// Regression: toggling the in-room search bar must NOT reset the message scroller to the
// top. The bar is a conditional sibling of #message-scroll; a bare `:if` made morphdom
// detach + re-insert the scroller, zeroing scrollTop (the chat jumped to the top on every
// open AND cancel). The fix wraps the bar in a stable always-present slot.
test("room search toggle preserves scroll position", async ({ alice, seed }) => {
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await alice.waitForSelector("#message-scroll", { timeout: 15000 })
  await alice.waitForTimeout(700)

  const top = () =>
    alice.evaluate(() => Math.round(document.getElementById("message-scroll").scrollTop))

  const start = await top()
  expect(start).toBeGreaterThan(100) // a long room loads scrolled to the bottom

  // Open search — the scroller must stay put (the bug zeroed it).
  await alice.locator('[phx-click="toggle_room_search"]').first().click()
  await alice.waitForTimeout(400)
  expect(await top()).toBeGreaterThan(100)

  // Cancel — also must stay put.
  await alice.locator('form.ed-search [phx-click="toggle_room_search"]').click()
  await alice.waitForTimeout(400)
  expect(await top()).toBeGreaterThan(100)
})
