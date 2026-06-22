// Wave 3 — corporate layer: rooms (flat Mattermost layout), threads, channels. Multi-user
// over the general room (every channel member auto-joins it).
const { test, expect, shot, send, openMenu } = require("../helpers/fixtures")

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

test.describe("corporate", () => {
  test("room message reaches another member live", async ({ alice, bob, seed }, testInfo) => {
    await alice.goto(room(seed))
    await bob.goto(room(seed))
    const msg = `room ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    await expect(alice.locator("#messages").getByText(msg).first()).toBeVisible()
    await expect(bob.locator("#messages").getByText(msg).first()).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "room")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("thread reply shows in the panel and bumps the root footer for both", async ({ alice, bob, seed }, testInfo) => {
    await alice.goto(room(seed))
    await bob.goto(room(seed))

    const rootText = `thread-root ${testInfo.project.name} ${Date.now()}`
    await send(alice, rootText)
    const rootRow = alice.locator("#messages .ed-flat", { hasText: rootText }).first()
    await expect(rootRow).toBeVisible()

    // Open the thread (rooms-only "Reply in thread") and reply in the panel.
    const menu = await openMenu(alice, rootRow)
    await menu.getByText("Reply in thread", { exact: true }).click()
    await expect(alice.locator("#reply-composer")).toBeVisible()
    const reply = `thread-reply ${Date.now()}`
    await alice.locator("#reply-body").fill(reply)
    await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())
    await expect(alice.locator("#thread-replies").getByText(reply).first()).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "thread-panel")

    // The root in the main stream now carries a thread footer for both users.
    await expect(alice.locator("#messages .ed-flat", { hasText: rootText }).locator(".ed-thread-footer")).toBeVisible({ timeout: 12_000 })
    await expect(bob.locator("#messages .ed-flat", { hasText: rootText }).locator(".ed-thread-footer")).toBeVisible({ timeout: 12_000 })
    await shot(bob, testInfo, "thread-footer-bob")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("channel create opens from the rail", async ({ alice }, testInfo) => {
    await alice.goto("/app")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.locator(".ed-rail__btn--new").click()
    await alice.waitForTimeout(500)
    await shot(alice, testInfo, "channel-create-modal")
    expect(alice.__diag.pageErrors).toEqual([])
  })
})
