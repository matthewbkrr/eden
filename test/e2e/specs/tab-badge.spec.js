const { test, expect, send } = require("../helpers/fixtures")

// #216: total unread (DMs/groups + unmuted channels) is reflected in the browser tab —
// a "(N) " prefix on document.title and a red dot drawn onto the favicon — so a backgrounded
// tab shows there's something waiting. Driven by #tab-badge's data-count (recomputed server-side
// on every unread change) and the .TabBadge hook.
const count = (page) =>
  page.evaluate(() => parseInt(document.querySelector("#tab-badge")?.dataset.count || "0", 10))

test("the browser tab gets a (N) title prefix + a favicon badge on unread (#216)", async ({
  alice,
  bob,
  seed,
}) => {
  // Alice on the chat list, NOT viewing the alice–bob DM, so a new message there counts as unread.
  await alice.goto("/app")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForSelector("#tab-badge", { state: "attached" })
  const before = await count(alice)

  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())
  await send(bob, `tab ${Date.now()}`)

  // The count rises, the title gains a "(N) " prefix, and the favicon becomes a generated
  // (badged) data URL instead of the static /favicon.ico.
  await expect.poll(() => count(alice), { timeout: 8000 }).toBeGreaterThan(before)
  await expect.poll(() => alice.evaluate(() => /^\(\d+\)\s/.test(document.title))).toBe(true)
  expect(
    await alice.evaluate(() => document.querySelector("link[rel~='icon']").href.startsWith("data:image"))
  ).toBe(true)

  const peak = await count(alice)

  // Reading the DM drops the count (and, if it reaches 0, the prefix would clear).
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await expect.poll(() => count(alice), { timeout: 8000 }).toBeLessThan(peak)
})
