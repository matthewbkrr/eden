const { test, expect, send, openMenu } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

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

// #164 PR-2: editing a MEDIA message opens the edit-media modal (not the composer banner).
// The author drops/keeps existing photos, adds new ones, and edits the caption; the replaced
// album + "edited" marker reach a peer viewing live.
test("an author edits a photo message via the media modal: adds a photo + caption (#164)", async ({
  alice,
  bob,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  const caption = `cap ${Date.now()}`

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  // Send a single photo.
  await alice.locator('#composer input[type="file"]').setInputFiles(fix("sample1.png"))
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await alice.locator('[data-upload-preview] button[type="submit"]').click()
  const bubble = alice.locator("#messages .ed-bubble").last()
  await expect(bubble.locator("img").first()).toBeVisible({ timeout: 10000 })

  // Bob views the same DM (so the edit must reach him live).
  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())
  await expect(bob.locator("#messages .ed-bubble img").first()).toBeVisible({ timeout: 10000 })

  // Alice opens the message menu → Edit → the MEDIA modal opens (not the text banner).
  const menu = await openMenu(alice, bubble)
  await menu.locator(".ed-menu__item", { hasText: "Edit" }).click()
  await expect(alice.locator("#dlg-edit-media")).toBeVisible()
  await expect(alice.locator(".ed-reply-bar--edit")).toHaveCount(0)
  // One kept tile (the existing photo); the dashed add tile is separate.
  await expect(alice.locator("#dlg-edit-media .ed-editmedia__tile")).toHaveCount(1)

  // Add a second photo + a caption, then Save.
  await alice.locator('#dlg-edit-media input[type="file"]').setInputFiles(fix("sample2.png"))
  await expect(alice.locator("#dlg-edit-media .ed-editmedia__tile")).toHaveCount(2)
  await alice.fill('#dlg-edit-media input[name="message[body]"]', caption)
  await alice.locator('#dlg-edit-media button[type="submit"]').click()

  // The modal closes; the message gains the caption + "edited" marker.
  await expect(alice.locator("#dlg-edit-media")).toHaveCount(0)
  await expect(alice.locator("#messages .ed-bubble", { hasText: caption })).toBeVisible({
    timeout: 10000,
  })
  await expect(alice.locator(".ed-edited").first()).toBeVisible()

  // Bob sees the caption + marker live (he never reloaded).
  await expect(bob.locator("#messages .ed-bubble", { hasText: caption })).toBeVisible({
    timeout: 10000,
  })
  await expect(bob.locator(".ed-edited").first()).toBeVisible()
})
