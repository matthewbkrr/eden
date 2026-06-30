const { test, expect } = require("../helpers/fixtures")
const path = require("path")
const fix = (name) => path.join(__dirname, "..", "fixtures", name)

// #178: owner/admin set a group photo by clicking the big avatar in the profile panel
// (auto-uploads); members see the photo but get no upload affordance. The seed group
// (seed.group_id) is alice = owner, bob = member.
test("owner uploads a group photo by clicking the avatar; a member sees it but can't edit (#178)", async ({
  alice,
  bob,
  seed,
}) => {
  // Alice (owner) opens the group and its profile panel.
  await alice.goto(`/app/c/${seed.group_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.locator("[data-profile-trigger]").click()

  // The editable avatar affordance is present for the owner.
  const editable = alice.locator(".ed-avatar-edit")
  await expect(editable).toBeVisible()

  // Pick an image via the (sr-only) file input inside the affordance → auto-uploads + sets.
  await editable.locator("input[type='file']").setInputFiles(fix("sample1.png"))

  // The group avatar now renders as an image pointing at the members-only serving route.
  await expect(
    alice.locator(`.ed-avatar-edit img[src*='/conversations/${seed.group_id}/avatar']`)
  ).toBeVisible({ timeout: 8000 })
  // A "Remove photo" affordance appears once one is set.
  await expect(alice.getByRole("button", { name: /remove photo/i })).toBeVisible()

  // Bob (member) opens the same group panel: he sees the avatar image but NO edit affordance.
  await bob.goto(`/app/c/${seed.group_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())
  await bob.locator("[data-profile-trigger]").click()
  await expect(
    bob.locator(`img[src*='/conversations/${seed.group_id}/avatar']`).first()
  ).toBeVisible({ timeout: 8000 })
  await expect(bob.locator(".ed-avatar-edit")).toHaveCount(0)

  // Owner clears it — the affordance reverts to initials (Remove control round-trip + cleanup).
  await alice.getByRole("button", { name: /remove photo/i }).click()
  await expect(
    alice.locator(`.ed-avatar-edit img[src*='/conversations/${seed.group_id}/avatar']`)
  ).toHaveCount(0, { timeout: 8000 })
})
