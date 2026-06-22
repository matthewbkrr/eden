// Wave 2 — structure: folders, groups, presence propagation, profiles. Multi-user where
// the point is realtime. Folder create/delete cleans up after itself.
const { test, expect, shot, send } = require("../helpers/fixtures")

test.describe("structure", () => {
  test("create a folder, see it as a sidebar tab, then delete it", async ({ alice }, testInfo) => {
    await alice.goto(`/settings`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const name = `Audit ${Date.now()}`
    const form = alice.locator('form[phx-submit="create_folder"]')
    await form.locator('input[name="name"]').fill(name)
    const add = form.locator('button[type="submit"]')
    await expect(add).toBeEnabled() // enabled once phx-change syncs @new_folder
    await add.click()

    // Appears in the settings list — the name lives in a (styled) rename input, so match
    // by input value, not text content.
    const row = alice.locator("#folder-list li").filter({ has: alice.locator(`input[value="${name}"]`) })
    await expect(row).toBeVisible()
    await shot(alice, testInfo, "folder-created")

    // And as a tab back in the sidebar (tabs render the name as text).
    await alice.goto(`/app`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await expect(alice.locator("#folder-tabs", { hasText: name })).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "folder-tab")

    // Clean up — delete it (data-confirm; the fixture auto-accepts).
    await alice.goto(`/settings`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const row2 = alice.locator("#folder-list li").filter({ has: alice.locator(`input[value="${name}"]`) })
    await expect(row2).toBeVisible({ timeout: 12_000 })
    await row2.getByLabel("Delete folder").click()
    await expect(row2).toHaveCount(0, { timeout: 12_000 })
    expect(alice.__diag.pageErrors).toEqual([])
  })

  test("group message reaches another member live", async ({ alice, bob, seed }, testInfo) => {
    const group = `/app/c/${seed.group_id}`
    await alice.goto(group)
    await bob.goto(group)
    const msg = `group ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    await expect(alice.locator("#messages").getByText(msg).first()).toBeVisible()
    await expect(bob.locator("#messages").getByText(msg).first()).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "group")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("a status change propagates to the peer's header live", async ({ alice, bob, seed }, testInfo) => {
    // alice must be connected to an app page to register presence (her fixture page starts
    // blank); put her in the same DM so bob sees her online to start.
    await alice.goto(`/app/c/${seed.dm_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await bob.goto(`/app/c/${seed.dm_id}`)
    const peerHeader = bob.locator("[data-profile-trigger]")
    // alice is connected → bob sees her online.
    await expect(peerHeader).toContainText(/online/i, { timeout: 12_000 })
    await shot(bob, testInfo, "presence-online")

    // alice sets a non-active status; bob's view of her updates without a reload.
    await alice.goto(`/settings`)
    await alice.locator(".ed-seg__btn", { hasText: "Away" }).click()
    await expect(peerHeader).not.toContainText(/online/i, { timeout: 12_000 })
    await shot(bob, testInfo, "presence-changed")

    // reset
    await alice.locator(".ed-seg__btn", { hasText: "Active" }).click()
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("peer profile opens from the DM header", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/app/c/${seed.dm_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.locator("[data-profile-trigger]").click()
    await alice.waitForTimeout(600)
    await shot(alice, testInfo, "profile")
    expect(alice.__diag.pageErrors).toEqual([])
  })
})
