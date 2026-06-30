const { test, expect, send } = require("../helpers/fixtures")

// #216: total unread (DMs/groups + unmuted channels) is reflected in the browser tab as a
// "(N) " prefix on document.title, so a backgrounded tab shows there's something waiting.
// Driven by #tab-badge's data-count (recomputed server-side on every unread change) and the
// .TabBadge hook. The favicon stays the STATIC brand icon (we don't rewrite it — dynamic
// favicon swaps are unreliable in Firefox), so the count lives only in the title.
const count = (page) =>
  page.evaluate(() => parseInt(document.querySelector("#tab-badge")?.dataset.count || "0", 10))

test("the browser tab gets a (N) title prefix on unread; the favicon stays the brand icon (#216)", async ({
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

  // The count rises and the title gains a "(N) " prefix...
  await expect.poll(() => count(alice), { timeout: 8000 }).toBeGreaterThan(before)
  await expect.poll(() => alice.evaluate(() => /^\(\d+\)\s/.test(document.title))).toBe(true)
  // ...while the favicon stays the static brand PNG (never rewritten to a data: URL).
  expect(
    await alice.evaluate(() => document.querySelector("link[rel~='icon']").href.includes("favicon"))
  ).toBe(true)
  expect(
    await alice.evaluate(() => document.querySelector("link[rel~='icon']").href.startsWith("data:"))
  ).toBe(false)

  const peak = await count(alice)

  // Reading the DM drops the count; the title prefix follows it down.
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await expect.poll(() => count(alice), { timeout: 8000 }).toBeLessThan(peak)
})
