// Wave 6 — corporate extended: room creation, channel members, invite link + redemption.
const { test, expect, shot } = require("../helpers/fixtures")

test.describe("corporate-ext", () => {
  test("an admin creates a new room", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/channels/${seed.channel_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.locator(".ed-room--new").click()
    const modal = alice.locator("#room-modal")
    await expect(modal).toBeVisible()
    const name = `room-${Date.now()}`
    await modal.locator('input[name="room[name]"]').fill(name)
    await modal.locator('button[type="submit"]').click()
    // The room appears (alice lands in it / it's listed).
    await expect(alice.getByText(name).first()).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "new-room")
    expect(alice.__diag.pageErrors).toEqual([])
  })

  test("the channel members list opens", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/channels/${seed.channel_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.locator('button[aria-label="Channel menu"]').click()
    await alice.getByRole("menuitem", { name: "Members", exact: true }).click()
    await expect(alice.locator('[role="dialog"]', { hasText: "Members" })).toBeVisible()
    await shot(alice, testInfo, "members")
    expect(alice.__diag.pageErrors).toEqual([])
  })

  test("an admin generates an invite link and another user redeems it", async ({ alice, carol, seed }, testInfo) => {
    await alice.goto(`/channels/${seed.channel_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.locator('button[aria-label="Channel menu"]').click()
    await alice.getByRole("menuitem", { name: "Invite link" }).click()

    const modal = alice.locator('[role="dialog"]')
    await modal.locator('button[phx-click="create_invite"]').click()
    const link = modal.locator('input[readonly]')
    await expect(link).toBeVisible({ timeout: 8_000 })
    const url = await link.inputValue()
    expect(url).toContain("/channels/join/")
    await shot(alice, testInfo, "invite-link")

    // Carol redeems → joins the channel and lands on its room list (the general room shows).
    await carol.goto(url)
    await carol.waitForURL(/\/channels\//, { timeout: 15_000 })
    await expect(carol.getByText(/general/i).first()).toBeVisible({ timeout: 15_000 })
    await shot(carol, testInfo, "invite-redeemed")
    expect(alice.__diag.pageErrors.concat(carol.__diag.pageErrors)).toEqual([])
  })
})
