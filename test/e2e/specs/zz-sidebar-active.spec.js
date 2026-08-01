// Who owns the sidebar row's appearance (#514, part of epic #506).
//
// Opening a chat used to re-stream the WHOLE sidebar server-side for two visual facts: which row
// carries the active wash, and that the opened chat has no unread left. Measured on a nine-chat
// list that was ~7 of the 26 queries a navigation costs — and it arrived a round-trip late, so the
// list the hook had already repainted flickered back.
//
// Both facts are known at tap time, so `.InstantNav` owns them now. That is only safe if it
// actually does them, which no server-rendered test can see: this is the whole reason the ExUnit
// test for the highlight had to shrink to "a fresh load marks the right row".
const { test, expect } = require("../helpers/fixtures")

const ready = async (page) => {
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await page.locator(".ed-convo-wrap").first().waitFor()
}

test("tapping a chat moves the wash and clears that row's badge", async ({ alice, bob, seed }) => {
  // An unread badge to clear: bob writes while alice is on the list.
  await alice.goto("/app")
  await ready(alice)

  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())
  await bob.locator("#composer-body").click()
  await bob.keyboard.type(`badge-${Date.now()}`)
  await bob.keyboard.press("Enter")

  const row = alice.locator(`.ed-convo-wrap[data-id="${seed.dm_id}"]`)
  const link = row.locator("a.ed-convo")

  await expect(row.locator(".ed-badge")).toBeVisible({ timeout: 15_000 })
  await expect(link).not.toHaveClass(/ed-convo--active/)

  await link.click()

  // Read ONCE, with no auto-retry. `expect(...).toHaveClass()` polls for seconds, and the server
  // re-streams this row for its own reasons within that window — so the retrying form passed with
  // the hook's work deleted, twice, and proved nothing. What has to be true is that the row is
  // already correct when the click returns, before any round-trip.
  const immediate = await alice.evaluate((id) => {
    const w = document.querySelector(`.ed-convo-wrap[data-id="${id}"]`)
    return {
      active: !!w.querySelector("a.ed-convo.ed-convo--active"),
      badges: w.querySelectorAll(".ed-badge").length,
      washed: document.querySelectorAll("a.ed-convo--active").length,
    }
  }, String(seed.dm_id))

  expect(immediate.active, "the tapped row is not washed until the server answers").toBe(true)
  expect(immediate.badges, "the unread badge survives the tap until the server answers").toBe(0)
  // Moving the wash means removing it from wherever it was.
  expect(immediate.washed, "more than one row is washed").toBe(1)
})

test("a reload still marks the open chat, so the wash is not only client-side", async ({
  alice,
  seed,
}) => {
  // The server keeps the truth: this is what makes losing the per-navigation re-stream safe.
  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)

  await expect(
    alice.locator(`.ed-convo-wrap[data-id="${seed.dm_id}"] a.ed-convo`),
  ).toHaveClass(/ed-convo--active/)
  await expect(alice.locator("a.ed-convo--active")).toHaveCount(1)
})
