const { test, expect } = require("../helpers/fixtures")

// #195: opening a member's profile popover must not shift the layout. The popover's grouping
// wrapper was a flex child of .ed-root, so it added one more `gap` (0.625rem) to the row and
// pushed the profile panel ~10px sideways. display:contents takes the wrapper out of the flow.
test("opening a member popover doesn't shift the layout (#195)", async ({ alice, seed }) => {
  await alice.goto(`/app/c/${seed.group_id}`)
  await alice.locator("[data-profile-trigger]").first().click()
  await alice.waitForSelector("aside.ed-profile", { timeout: 10000 })
  await alice.waitForTimeout(500)

  const asideX = () =>
    alice.evaluate(() => Math.round(document.querySelector("aside.ed-profile").getBoundingClientRect().x))
  const before = await asideX()

  await alice.locator(".ed-member-row__main").nth(1).click()
  await alice.waitForSelector("#profile-popover", { timeout: 5000 })
  await alice.waitForTimeout(300)
  expect(await asideX()).toBe(before)
})
