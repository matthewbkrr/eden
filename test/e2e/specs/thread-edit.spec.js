// #164 F3: editing a THREAD reply must use the thread composer (banner + pre-fill in
// #reply-composer), never the main composer — and show "edited" after save.
const { test, expect, openMenu } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

test("editing a thread reply uses the thread composer, not the main one (#164)", async ({
  alice,
  seed,
}, testInfo) => {
  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  // A root message, then open its thread and post a reply.
  const rootText = `root ${testInfo.project.name} ${Date.now()}`
  await alice.locator("#composer-body").fill(rootText)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const rootRow = alice.locator("#messages .ed-flat", { hasText: rootText }).first()
  await expect(rootRow).toBeVisible()

  const menu = await openMenu(alice, rootRow)
  await menu.getByText("Reply in thread", { exact: true }).click()
  await expect(alice.locator("#reply-composer")).toBeVisible()
  const reply = `reply ${Date.now()}`
  await alice.locator("#reply-body").fill(reply)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
  const replyRow = alice.locator("#thread-replies .ed-flat", { hasText: reply }).first()
  await expect(replyRow).toBeVisible({ timeout: 12_000 })

  // Edit the reply → the banner + pre-fill land in the THREAD composer; the main one is untouched.
  const rmenu = await openMenu(alice, replyRow)
  await rmenu.locator(".ed-menu__item", { hasText: "Edit" }).click()
  await expect(alice.locator("#reply-composer .ed-reply-bar--edit")).toBeVisible()
  await expect(alice.locator("#reply-body")).toHaveValue(reply)
  await expect(alice.locator("#composer .ed-reply-bar--edit")).toHaveCount(0)

  // Change + save → the reply updates in place in the panel and gains the "edited" marker.
  const fixed = `${reply} EDITED`
  await alice.locator("#reply-body").fill(fixed)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
  await expect(alice.locator("#thread-replies .ed-flat", { hasText: fixed })).toBeVisible({
    timeout: 12_000,
  })
  await expect(alice.locator("#reply-composer .ed-reply-bar--edit")).toHaveCount(0)
  await expect(alice.locator("#thread-replies .ed-edited").first()).toBeVisible()
  expect(alice.__diag.pageErrors).toEqual([])
})

// #164 text→media parity in threads: editing a text reply + attaching media converts it
// into a media reply (the reply input's text becomes the caption), like the main composer.
test("editing a text thread reply + attaching media converts it to media (#164)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  await alice.locator("#composer-body").fill(`root ${Date.now()}`)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const rootRow = alice.locator("#messages .ed-flat").last()
  const menu = await openMenu(alice, rootRow)
  await menu.getByText("Reply in thread", { exact: true }).click()
  await expect(alice.locator("#reply-composer")).toBeVisible()
  const reply = `reply ${Date.now()}`
  await alice.locator("#reply-body").fill(reply)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
  const replyRow = alice.locator("#thread-replies .ed-flat", { hasText: reply }).first()
  await expect(replyRow).toBeVisible({ timeout: 12_000 })

  // Edit the reply, attach a photo, save → it becomes a media reply (photo + caption + edited).
  const rmenu = await openMenu(alice, replyRow)
  await rmenu.locator(".ed-menu__item", { hasText: "Edit" }).click()
  await expect(alice.locator("#reply-composer .ed-reply-bar--edit")).toBeVisible()
  await alice.locator('#reply-composer input[type="file"]').setInputFiles(fix("sample1.png"))
  await expect(alice.locator("#reply-composer [data-upload-preview]")).toBeVisible()
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())

  const converted = alice.locator("#thread-replies .ed-flat", { hasText: reply }).first()
  await expect(converted.locator("img").first()).toBeVisible({ timeout: 12_000 })
  await expect(alice.locator("#thread-replies .ed-edited").first()).toBeVisible()
  await expect(alice.locator("#reply-composer .ed-reply-bar--edit")).toHaveCount(0)
})
