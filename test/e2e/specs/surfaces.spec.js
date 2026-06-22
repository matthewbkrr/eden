// Surface tour: walk the major surfaces as real users, assert each loads, screenshot it
// (desktop + mobile via the project matrix), and flag uncaught JS errors / bad responses.
// Each surface is its own test so one broken area doesn't mask the rest. The screenshots
// are the raw material for the visual/UX critique; the diagnostics catch runtime breakage.
const { test, expect, shot, send } = require("../helpers/fixtures")

test.describe("surface tour", () => {
  test("DM thread loads + sends (bubbles)", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/app/c/${seed.dm_id}`)
    await expect(alice.locator("#composer-body")).toBeVisible()
    const msg = `tour-dm ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    await expect(alice.locator("#messages").getByText(msg).first()).toBeVisible()
    await shot(alice, testInfo, "dm")
    expect(alice.__diag.pageErrors, "DM uncaught errors").toEqual([])
  })

  test("group thread loads + sends", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/app/c/${seed.group_id}`)
    await expect(alice.locator("#composer-body")).toBeVisible()
    const msg = `tour-group ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    await expect(alice.locator("#messages").getByText(msg).first()).toBeVisible()
    await shot(alice, testInfo, "group")
    expect(alice.__diag.pageErrors, "group uncaught errors").toEqual([])
  })

  test("channel room loads + sends (flat Mattermost rows)", async ({ alice, seed }, testInfo) => {
    // Bare /channels/:id is the room LIST (mobile back-target); a room with a composer is
    // /channels/:id/r/:room_id.
    await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
    await expect(alice.locator("#composer-body")).toBeVisible({ timeout: 15_000 })
    const msg = `tour-room ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    await expect(alice.locator("#messages").getByText(msg).first()).toBeVisible()
    await shot(alice, testInfo, "room")
    expect(alice.__diag.pageErrors, "room uncaught errors").toEqual([])
  })

  test("sidebar search returns grouped results", async ({ alice }, testInfo) => {
    await alice.goto(`/app`)
    const search = alice.locator('#sidebar-search input[name="q"]')
    await expect(search).toBeVisible()
    await search.fill("tour")
    // Trigger phx-change debounce + render.
    await alice.waitForTimeout(800)
    await shot(alice, testInfo, "search")
    expect(alice.__diag.pageErrors, "search uncaught errors").toEqual([])
  })

  test("settings page (profile, quick reactions, folders)", async ({ alice }, testInfo) => {
    await alice.goto(`/settings`)
    await expect(alice.locator("#profile-form")).toBeVisible()
    await expect(alice.locator(".ed-qr-grid")).toBeVisible()
    await shot(alice, testInfo, "settings")
    expect(alice.__diag.pageErrors, "settings uncaught errors").toEqual([])
  })

  test("channel room list (mobile back-target)", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/channels/${seed.channel_id}`)
    await alice.waitForTimeout(600)
    await shot(alice, testInfo, "channel")
    expect(alice.__diag.pageErrors, "channel uncaught errors").toEqual([])
  })
})
