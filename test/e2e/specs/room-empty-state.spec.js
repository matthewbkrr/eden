const { test, expect, send, ready } = require("../helpers/fixtures")

// #154: a freshly created room (no messages) shows an empty-state instead of a bare pane.
// It must disappear the moment the first message lands. `only:block` drives visibility off
// #messages being childless, so this asserts computed visibility, not just presence.
test("an empty room shows an empty-state that clears on the first message (#154)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/channels/${seed.channel_id}`)
  await ready(alice)

  // Create a brand-new (empty) room.
  await alice.locator(".ed-room--new").click()
  const modal = alice.locator("#room-modal")
  await expect(modal).toBeVisible()
  const name = `empty-${Date.now()}`
  await modal.locator('input[name="room[name]"]').fill(name)
  await modal.locator('button[type="submit"]').click()

  // Land in the new room.
  await alice.getByText(name).first().click()
  // ATTACHED, not visible: an empty room's `#messages` holds nothing and therefore has no box, so
  // waiting for it to be *visible* waits forever in exactly the state this test is about — this
  // one line is the whole failure (#588). An earlier attempt also rewrote the click above, on the
  // theory that `getByText` could match the modal's own input; that was wrong (Playwright matches
  // input values only for button/submit types) and it has been backed out — the click was never
  // the problem (#594 review).
  await alice.waitForSelector("#messages", { state: "attached", timeout: 12000 })

  // The empty-state is visible and the medallion/title render.
  const empty = alice.locator("#messages-empty")
  await expect(empty).toBeVisible({ timeout: 8000 })
  await expect(empty.locator(".ed-room-empty__title")).toHaveText("No messages yet")
  await expect(empty.locator(".ed-room-empty__medallion")).toBeVisible()
  // No message rows yet.
  await expect(alice.locator("#messages .ed-flat")).toHaveCount(0)

  // First message → the empty-state hides, the row appears.
  await send(alice, "first words")
  await expect(alice.locator("#messages .ed-flat", { hasText: "first words" })).toBeVisible({
    timeout: 10000,
  })
  await expect(empty).toBeHidden()
})
