// Wave 5b — extended messaging: forward, mute, move-to-folder.
const { test, expect, shot, send, openMenu } = require("../helpers/fixtures")

const dm = (seed) => `/app/c/${seed.dm_id}`
const group = (seed) => `/app/c/${seed.group_id}`
const convoRow = (page, id) => page.locator(`a.ed-convo[href$="/app/c/${id}"]`).first()

test.describe("messaging-ext", () => {
  test("forward a message into the group", async ({ alice, bob, seed }, testInfo) => {
    await alice.goto(dm(seed))
    const msg = `forward-me ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    const bubble = alice.locator(".ed-bubble", { hasText: msg }).first()
    await expect(bubble).toBeVisible()

    const menu = await openMenu(alice, bubble)
    await menu.locator(".ed-menu__item", { hasText: "Forward" }).click()
    // Forward picker → choose the group.
    await alice.locator(`button[phx-click="forward"][phx-value-target="${seed.group_id}"]`).click()

    // The forwarded copy lands in the group (bob, a member, sees it live too).
    await bob.goto(group(seed))
    await alice.goto(group(seed))
    await expect(alice.locator("#messages").getByText(msg).first()).toBeVisible({ timeout: 12_000 })
    await expect(bob.locator("#messages").getByText(msg).first()).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "forwarded")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("mute then unmute a conversation toggles the muted indicator", async ({ alice, seed }, testInfo) => {
    await alice.goto("/app")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const row = convoRow(alice, seed.dm_id)
    await expect(row).toBeVisible()

    const menu = await openMenu(alice, row)
    await menu.locator(".ed-menu__item", { hasText: "Mute" }).click()
    await expect(convoRow(alice, seed.dm_id).locator(".ed-convo__muted")).toBeVisible({ timeout: 8_000 })
    await shot(alice, testInfo, "muted")

    // Unmute (cleanup).
    const menu2 = await openMenu(alice, convoRow(alice, seed.dm_id))
    await menu2.locator(".ed-menu__item", { hasText: "Unmute" }).click()
    await expect(convoRow(alice, seed.dm_id).locator(".ed-convo__muted")).toHaveCount(0, { timeout: 8_000 })
    expect(alice.__diag.pageErrors).toEqual([])
  })

  test("move a chat into a folder, then back out", async ({ alice, seed }, testInfo) => {
    // Make a folder.
    await alice.goto("/settings")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const name = `Move ${Date.now()}`
    const form = alice.locator('form[phx-submit="create_folder"]')
    await form.locator('input[name="name"]').fill(name)
    const add = form.locator('button[type="submit"]')
    await expect(add).toBeEnabled()
    await add.click()
    const folderRow = alice.locator("#folder-list li").filter({ has: alice.locator(`input[value="${name}"]`) })
    await expect(folderRow).toBeVisible()

    // Move the DM into it via the sidebar context menu.
    await alice.goto("/app")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const menu = await openMenu(alice, convoRow(alice, seed.dm_id))
    await menu.locator(".ed-menu__item", { hasText: "Move to folder" }).click()
    const modal = alice.locator('[role="dialog"]', { hasText: name })
    await expect(modal).toBeVisible()
    await modal.locator("button", { hasText: name }).click() // toggle the folder on
    await shot(alice, testInfo, "move-to-folder")

    // Clean up — delete the folder (the grouping; the chat stays).
    await alice.goto("/settings")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const row2 = alice.locator("#folder-list li").filter({ has: alice.locator(`input[value="${name}"]`) })
    await row2.getByLabel("Delete folder").click()
    await expect(row2).toHaveCount(0, { timeout: 10_000 })
    expect(alice.__diag.pageErrors).toEqual([])
  })
})
