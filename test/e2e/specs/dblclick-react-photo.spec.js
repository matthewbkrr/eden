const { test, expect } = require("../helpers/fixtures")

// #106: a photo in a message reacts on double-click (the user chose this over instant-open).
// The .Lightbox hook defers its open ~250ms inside a message so a double-click preempts it;
// a single click still opens (just after that short delay). A real 96x96 PNG so the tile has
// a clickable area (a 1x1 test image collapses the tile and coordinate clicks miss it).
const PNG96 =
  "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAApElEQVR4nO3QQQ0AIBDAsJOIHHSiCAd82aPJBCydtY8ezfeDeIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQIDCAQIECBCgcIAAAQIEKBwgQIAAAQoHCBAgQD+7vbyrWNjm1aQAAAAASUVORK5CYII="

const dropPng = (page, id) =>
  page.evaluate(
    ({ id, b64 }) => {
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
      const el = document.getElementById(id)
      for (const type of ["dragenter", "dragover", "drop"]) {
        const dt = new DataTransfer()
        dt.items.add(new File([bytes], "p.png", { type: "image/png" }))
        el.dispatchEvent(
          new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true })
        )
      }
    },
    { id, b64: PNG96 }
  )

test("dbl-click a photo reacts (lightbox stays closed); single-click opens it (#106)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForSelector("#chat-dropzone", { timeout: 15000 })
  await alice.waitForTimeout(500)

  await dropPng(alice, "chat-dropzone")
  await expect(alice.locator(".ed-compose__tile")).toHaveCount(1, { timeout: 8000 })
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())

  const photo = alice.locator("#messages .ed-photo").last()
  await expect(photo).toBeVisible({ timeout: 12000 })
  await alice.waitForTimeout(1000) // rise-in animation + thumbnail settle

  // Double-click the photo → reacts (one more chip), and the lightbox does NOT open.
  const before = await alice.locator("#messages .ed-react").count()
  await photo.dblclick()
  await expect(alice.locator("#messages .ed-react")).toHaveCount(before + 1, { timeout: 8000 })
  await expect(alice.locator("#ed-lightbox.ed-lightbox--open")).toHaveCount(0)

  // Single click (after the click-count resets) → the lightbox opens past the ~250ms delay.
  await alice.waitForTimeout(600)
  await photo.click()
  await expect(alice.locator("#ed-lightbox.ed-lightbox--open")).toHaveCount(1, { timeout: 4000 })
})
