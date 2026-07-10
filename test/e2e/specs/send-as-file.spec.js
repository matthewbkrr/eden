// #122 — "Send as file": a staged photo can be sent as an uncompressed downloadable
// document instead of a compressed inline image. The message renders as a file card whose
// leading glyph is a mini photo preview (the thumbnail), never an inline album tile.
const { test, expect } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

test("a staged photo sends as a document card with a thumbnail, not an inline image (#122)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  // Stage a photo → the overlay opens and offers the "Send as file" button (images only).
  await alice.locator('#composer input[name="attachment"]').setInputFiles(fix("big-photo.png"))
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await expect(alice.locator(".ed-compose__img")).toHaveAttribute("src", /^blob:/)
  const asFile = alice.locator("[data-send-as-file]")
  await expect(asFile).toBeVisible()

  // Send as file → a document card whose glyph is a photo thumbnail (not an inline image).
  await asFile.click()
  const card = alice.locator("#messages .ed-file--photo").last()
  await expect(card).toBeVisible({ timeout: 8000 })
  await expect(card.locator(".ed-file__thumb img")).toBeVisible()
  // The card is a downloadable document, not an inline album tile.
  await expect(card).toHaveAttribute("download", "")
  await expect(card.locator(".ed-album__tile")).toHaveCount(0)
})

// Regression guard: "Send as file" must NOT hijack the Enter key. It's a type="button"
// (not a submit button), so Enter in the caption does a normal compressed send — never an
// as-file document — even though the button sits before the airplane in the footer.
test("Enter in the caption does a normal send, never as-file (#122)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const docBefore = await alice.locator("#messages .ed-file--photo").count()

  await alice.locator('#composer input[name="attachment"]').setInputFiles(fix("big-photo.png"))
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await alice.locator("#compose-caption").fill("hi")
  await alice.locator("#compose-caption").press("Enter")

  // The send fires (overlay closes) and adds NO document card — it's a normal inline photo.
  await expect(alice.locator("[data-upload-preview]")).toBeHidden()
  await alice.waitForTimeout(1500)
  expect(await alice.locator("#messages .ed-file--photo").count()).toBe(docBefore)
})
