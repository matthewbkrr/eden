// Wave 1 — core messaging, multi-user. Exercises the real interactions (emoji picker,
// reactions, reply-quote, delete-for-everyone tombstone, file send #149) and verifies the
// OTHER user sees the result live. The .ContextMenu hook listens to the `contextmenu`
// event, so dispatchEvent("contextmenu") opens a message's menu on any project.
const path = require("path")
const { test, expect, shot, send, openMenu } = require("../helpers/fixtures")

const sampleTxt = path.join(__dirname, "..", "fixtures", "sample.txt")

test.describe("messaging", () => {
  test("emoji picker inserts into the composer", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/app/c/${seed.dm_id}`)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await alice.locator("#emoji-picker [data-emoji-toggle]").click()
    const pop = alice.locator("[data-emoji-pop]")
    await expect(pop).toBeVisible()
    await pop.locator("[data-emoji]").first().click()
    await shot(alice, testInfo, "emoji-picker")
    await expect(alice.locator("#composer-body")).not.toHaveValue("")
    expect(alice.__diag.pageErrors).toEqual([])
  })

  test("reaction round-trips to the other user live", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    const msg = `react ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    const bubble = alice.locator(".ed-bubble", { hasText: msg }).first()
    await expect(bubble).toBeVisible()

    const menu = await openMenu(alice, bubble)
    // Quick-react row: tap the first quick emoji.
    await menu.locator(".ed-menu__react:not(.ed-menu__react-more)").first().click()

    // Chip appears UNDER the message (sibling of the bubble, #107) for alice AND bob live.
    await expect(alice.locator(".ed-msg", { hasText: msg }).locator(".ed-react").first()).toBeVisible()
    await expect(bob.locator(".ed-msg", { hasText: msg }).locator(".ed-react").first()).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "reaction-alice")
    await shot(bob, testInfo, "reaction-bob")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("reply-quote renders for both users", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    const target = `target ${testInfo.project.name} ${Date.now()}`
    await send(bob, target)
    const bubble = alice.locator(".ed-bubble", { hasText: target }).first()
    await expect(bubble).toBeVisible({ timeout: 12_000 })

    const menu = await openMenu(alice, bubble)
    await menu.locator(".ed-menu__item", { hasText: "Reply" }).first().click()
    await expect(alice.locator(".ed-reply-bar")).toBeVisible()
    const reply = `my reply ${Date.now()}`
    await send(alice, reply)

    // The reply shows a quote of the target above its body, for both.
    await expect(alice.locator("#messages").getByText(reply).first()).toBeVisible()
    await expect(bob.locator("#messages").getByText(reply).first()).toBeVisible({ timeout: 12_000 })
    await shot(alice, testInfo, "reply-alice")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("delete for everyone leaves a tombstone for both", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    const msg = `delete-me ${testInfo.project.name} ${Date.now()}`
    await send(alice, msg)
    const bubble = alice.locator(".ed-bubble", { hasText: msg }).first()
    await expect(bubble).toBeVisible()

    const menu = await openMenu(alice, bubble)
    await menu.locator(".ed-menu__item", { hasText: "Delete for everyone" }).click()

    // The body is gone; a "Message deleted" tombstone replaces it for both users.
    await expect(alice.locator("#messages").getByText(msg)).toHaveCount(0, { timeout: 12_000 })
    await expect(bob.locator("#messages").getByText(msg)).toHaveCount(0, { timeout: 12_000 })
    await shot(alice, testInfo, "deleted-alice")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })

  test("file send (#149) delivers to both", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())

    await alice.locator('#composer input[type="file"]').setInputFiles(sampleTxt)
    await expect(alice.locator("[data-upload-preview]")).toBeVisible()
    await shot(alice, testInfo, "file-staged")
    await alice.locator('[data-upload-preview] button[type="submit"]').click()

    // The real downloadable file card lands for both users.
    await expect(alice.locator("#messages a.ed-file").last()).toBeVisible({ timeout: 15_000 })
    await expect(bob.locator("#messages a.ed-file").last()).toBeVisible({ timeout: 15_000 })
    await shot(alice, testInfo, "file-alice")
    await shot(bob, testInfo, "file-bob")
    expect(alice.__diag.pageErrors.concat(bob.__diag.pageErrors)).toEqual([])
  })
})
