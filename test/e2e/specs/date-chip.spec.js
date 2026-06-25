// #150: the floating day chip (#date-chip, the .DateRail hook) is a USER-scroll
// affordance only. A programmatic scroll (scroll-to-bottom on send, jump-to-message,
// the load-older restore, the mount scroll) moves the list but must NOT flash the chip;
// a real wheel / touch / key scroll must.
const { test, expect } = require("../helpers/fixtures")

test("the day chip ignores programmatic scrolls but shows on a user wheel (#150)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForTimeout(900)

  const chipVisible = () =>
    alice.evaluate(() => document.getElementById("date-chip")?.classList.contains("is-visible") ?? false)

  // Programmatic scroll (mirrors send / jump): the chip stays hidden.
  await alice.evaluate(() => {
    document.getElementById("message-scroll").scrollTop -= 1500
  })
  await alice.waitForTimeout(450)
  expect(await chipVisible()).toBe(false)

  // A genuine user wheel reveals it.
  await alice.locator("#message-scroll").hover()
  await alice.mouse.wheel(0, -1500)
  await alice.waitForTimeout(120)
  expect(await chipVisible()).toBe(true)
})
