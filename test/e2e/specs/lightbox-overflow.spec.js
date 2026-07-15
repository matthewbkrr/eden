// #380/R187 — the Lightbox / VideoExpand overlays are singletons on <body>, outside the LiveView
// root, and lock body scroll (overflow:hidden) while open. A server-driven navigation tears down
// the owning hook WITHOUT firing its Esc/backdrop close(), which would leave the overlay visible and
// the page scroll-locked. A global phx:page-loading-start guard closes any open overlay on nav.
const { test, expect } = require("../helpers/fixtures")

// Trigger a live navigation while the overlay is open. The open lightbox covers the sidebar, so a
// normal (visibility-enforced) click can't reach the link — dispatch the click programmatically on
// the sidebar patch-link (LiveView delegates link clicks on document, so this still navigates and
// fires phx:page-loading-start, the guard's trigger). The socket/page stay alive (a live nav).
async function navToWhileOverlayOpen(page, convId) {
  await page.evaluate(
    (id) => document.querySelector(`#conversations a[href="/app/c/${id}"]`)?.click(),
    convId,
  )
  await page.waitForFunction(
    (id) => document.querySelector("#composer")?.dataset.conversationId === String(id),
    convId,
  )
}

test("navigating with the lightbox open unlocks body scroll (#380/R187)", async ({ alice, seed }) => {
  // The seed DM carries a photo, so a lightbox is one click away.
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  const photo = alice.locator("#messages .ed-photo").last()
  await expect(photo).toBeVisible({ timeout: 12_000 })
  await photo.scrollIntoViewIfNeeded()
  // The in-message Lightbox defers its open ~250ms (double-click-to-react disambiguation).
  await photo.click()
  await expect(alice.locator("#ed-lightbox.ed-lightbox--open")).toHaveCount(1, { timeout: 4_000 })
  expect(await alice.evaluate(() => document.body.style.overflow)).toBe("hidden")

  // Live-navigate to another chat with the overlay still open.
  await navToWhileOverlayOpen(alice, seed.group_id)

  // The nav guard closed the overlay → it's no longer open and body scroll is unlocked.
  await expect(alice.locator("#ed-lightbox.ed-lightbox--open")).toHaveCount(0)
  expect(await alice.evaluate(() => document.body.style.overflow)).toBe("")
  expect(alice.__diag.pageErrors).toEqual([])
})
