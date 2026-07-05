const { test, expect, send } = require("../helpers/fixtures")

// #106: double-clicking a message reacts with the viewer's configured emoji (defaults to
// the first quick reaction). Works in DM bubbles and flat room rows, toggles off on a second
// double-click, and round-trips live to the other user.
test.describe("double-click to react (#106)", () => {
  test("dbl-click reacts in a DM, round-trips live, and toggles off", async ({
    alice,
    bob,
    seed,
  }) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const msg = `dbl ${Date.now()}`
    await send(alice, msg)

    const row = alice.locator(".ed-msg", { hasText: msg }).first()
    await expect(row.locator(".ed-bubble")).toBeVisible()

    // Double-click the bubble → a reaction chip appears for alice AND bob.
    await row.locator(".ed-bubble").dblclick()
    await expect(row.locator(".ed-react")).toHaveCount(1, { timeout: 8000 })
    await expect(
      bob.locator(".ed-msg", { hasText: msg }).locator(".ed-react")
    ).toHaveCount(1, { timeout: 12000 })

    // No leftover text selection from the double-click (the handler clears it).
    expect(await alice.evaluate(() => (window.getSelection() || "").toString())).toBe("")

    // Double-click again → toggles the same emoji back off.
    await row.locator(".ed-bubble").dblclick()
    await expect(row.locator(".ed-react")).toHaveCount(0, { timeout: 8000 })
  })

  test("dbl-click reacts on a flat room row", async ({ alice, seed }) => {
    await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
    await alice.waitForSelector("#messages", { timeout: 15000 })
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const msg = `dblroom ${Date.now()}`
    await send(alice, msg)

    const row = alice.locator(".ed-flat", { hasText: msg }).first()
    await expect(row).toBeVisible()
    await row.locator(".ed-flat__body").dblclick()
    await expect(row.locator(".ed-react")).toHaveCount(1, { timeout: 8000 })
  })

  test("Settings picks which emoji the double-click reacts with", async ({ alice }, testInfo) => {
    await alice.goto("/settings/reactions")
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    const group = alice.locator('[role="radiogroup"]').first()
    await expect(group).toBeVisible()

    // Exactly one option is active; pick a different one and it moves.
    await expect(group.locator(".ed-qr--on")).toHaveCount(1)
    const active = await group.locator(".ed-qr--on").textContent()
    const other = group.locator(".ed-qr").filter({ hasNotText: active }).first()
    const wanted = await other.textContent()
    await other.click()

    await expect(group.locator(".ed-qr--on")).toHaveCount(1)
    await expect(group.locator(".ed-qr--on")).toHaveText(wanted)
    // Persists across a reload (stored in FolderPrefs).
    await alice.reload()
    await alice.waitForFunction(() => window.liveSocket?.isConnected())
    await expect(
      alice.locator('[role="radiogroup"]').first().locator(".ed-qr--on")
    ).toHaveText(wanted)
  })
})
