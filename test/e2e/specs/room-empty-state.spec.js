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

  // Land in the new room. Wait for the modal to go first and click the ROOM ROW, not "the first
  // element containing this text" — the modal carries the name in its own input, so a bare
  // getByText could pick that and never navigate (#588).
  await expect(modal).toBeHidden()
  // The LINK inside the row, not the row: `.ed-room-wrap` is a wrapper div that carries the
  // context-menu hook, and clicking it navigates nowhere. `getByText(name).first()` was worse
  // still — the modal holds the same text in its own input (#588).
  await alice.locator(".ed-room-wrap", { hasText: name }).first().locator("a.ed-room").click()
  // ATTACHED, not visible: an empty room's `#messages` holds nothing and therefore has no box, so
  // waiting for it to be *visible* waits forever in exactly the state this test is about (#588).
  // The empty-state below is the thing that must actually be on screen.
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
