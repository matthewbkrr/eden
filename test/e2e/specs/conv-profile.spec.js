// #136 — the conversation profile panel: tapping a 1:1 or group chat header opens a
// Telegram-style panel (peer/group card + a per-dialog media gallery with Photo/Video/
// Files/Audio tabs). A photo opens the shared lightbox; Esc closes ONLY the lightbox.
// Groups also show their member list inline; tapping a member opens their popover.
const { test, expect } = require("../helpers/fixtures")

test("the DM header opens the profile panel with a media gallery (#136)", async ({
  alice,
  seed,
}) => {
  // The seed plants one photo in the DM, so the gallery is deterministic on every engine.
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  // Open the expanded profile from the chat header.
  await alice.locator("[data-profile-trigger]").first().click()
  const panel = alice.locator(".ed-profile")
  await expect(panel).toBeVisible()
  await expect(panel.locator(".ed-gallery-tab")).toHaveCount(4)
  // Photo is the default tab and its grid shows the photo we seeded.
  await expect(panel.locator(".ed-gallery-tab--on")).toHaveText("Photo")
  await expect(panel.locator(".ed-gallery-grid .ed-gallery-tile").first()).toBeVisible()
  // The .GalleryMonths hook inserts a local-TZ month divider above the grid.
  await expect(panel.locator(".ed-gallery-month").first()).toBeVisible()
  // The sliding underline indicator is positioned under the active tab.
  await expect
    .poll(() => alice.locator("#gallery-indicator").evaluate((e) => parseInt(e.style.width)))
    .toBeGreaterThan(0)

  // ←/→ keyboard navigation moves the active tab (APG tabs).
  await panel.locator(".ed-gallery-tab--on").focus()
  await alice.keyboard.press("ArrowRight")
  await expect(panel.locator(".ed-gallery-tab--on")).toHaveText("Video")
  await alice.keyboard.press("ArrowLeft")
  await expect(panel.locator(".ed-gallery-tab--on")).toHaveText("Photo")

  // Switch to Files → photo grid gone (the file list / empty state takes over).
  await panel.locator(".ed-gallery-tab", { hasText: "Files" }).click()
  await expect(panel.locator(".ed-gallery-grid")).toHaveCount(0)

  // Back to Photo → click a tile → the shared lightbox opens.
  await panel.locator(".ed-gallery-tab", { hasText: "Photo" }).click()
  await panel.locator(".ed-gallery-grid .ed-gallery-tile").first().click()
  await expect(alice.locator(".ed-lightbox--open")).toBeVisible()

  // Esc closes ONLY the lightbox — the panel stays open (no window-Esc handler on it).
  await alice.keyboard.press("Escape")
  await expect(alice.locator(".ed-lightbox--open")).toHaveCount(0)
  await expect(panel).toBeVisible()
})

test("the group header opens the panel with a member list + gallery (#136)", async ({
  alice,
  seed,
}) => {
  await alice.goto(`/app/c/${seed.group_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  await alice.locator("[data-profile-trigger]").first().click()
  const panel = alice.locator(".ed-profile")
  await expect(panel).toBeVisible()
  // Group card + member rows (3 seed members, "(you)" on alice) + the gallery tabs.
  await expect(panel.locator(".ed-member-row")).toHaveCount(3)
  await expect(panel.locator(".ed-member-row__name").first()).toContainText("(you)")
  await expect(panel.locator(".ed-gallery-tab")).toHaveCount(4)

  // Tapping a member opens their profile popover over the panel.
  await panel.locator(".ed-member-row").nth(1).click()
  await expect(alice.locator(".ed-popover")).toBeVisible()
})
