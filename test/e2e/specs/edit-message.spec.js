const { test, expect, send, openMenu } = require("../helpers/fixtures")

// #164: an author edits their own message. The composer enters edit mode (banner + pre-fill),
// the saved row shows an "edited" marker, and the change reaches a peer who's viewing live.
test("an author edits their message; it shows 'edited' and reaches the peer live (#164)", async ({
  alice,
  bob,
  seed,
}) => {
  const stamp = Date.now()
  const original = `before ${stamp}`
  const fixed = `after ${stamp}`

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await send(alice, original)

  // Bob is viewing the same DM (so the edit must reach him live).
  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())
  await expect(bob.locator(".ed-bubble", { hasText: original })).toBeVisible({ timeout: 8000 })

  // Alice opens the message menu → Edit.
  const bubble = alice.locator(".ed-bubble", { hasText: original }).first()
  await expect(bubble).toBeVisible()
  const menu = await openMenu(alice, bubble)
  await menu.locator(".ed-menu__item", { hasText: "Edit" }).click()

  // Edit mode: the banner shows and the composer is pre-filled with the original.
  await expect(alice.locator(".ed-reply-bar--edit")).toBeVisible()
  await expect(alice.locator("#composer-body")).toHaveValue(original)

  // Replace the text and save.
  await alice.fill("#composer-body", fixed)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())

  // The row updates, gains the "edited" marker, and the edit banner clears.
  await expect(alice.locator(".ed-bubble", { hasText: fixed })).toBeVisible({ timeout: 8000 })
  await expect(alice.locator(".ed-bubble", { hasText: original })).toHaveCount(0)
  await expect(alice.locator(".ed-edited").first()).toBeVisible()
  await expect(alice.locator(".ed-reply-bar--edit")).toHaveCount(0)

  // Bob sees the edited text + marker live (he never reloaded).
  await expect(bob.locator(".ed-bubble", { hasText: fixed })).toBeVisible({ timeout: 8000 })
  await expect(bob.locator(".ed-edited").first()).toBeVisible()
})
