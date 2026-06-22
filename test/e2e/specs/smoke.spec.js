// Smoke: proves the harness itself works end-to-end before the full audit —
// session reuse (storageState), two simultaneous users in one test, realtime
// delivery over PubSub, the composer, and screenshots, on whatever project runs it.
const { test, expect, shot } = require("../helpers/fixtures")

test.describe("smoke", () => {
  test("auth + composer present in a DM", async ({ alice, seed }, testInfo) => {
    await alice.goto(`/app/c/${seed.dm_id}`)
    await expect(alice.locator("#composer-body")).toBeVisible()
    await shot(alice, testInfo, "01-alice-dm-open")
    expect(alice.__diag.pageErrors, "alice uncaught errors").toEqual([])
  })

  test("alice sends a DM, bob receives it live", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    await expect(alice.locator("#composer-body")).toBeVisible()

    const msg = `smoke ${testInfo.project.name} ${Date.now()}`
    await alice.fill("#composer-body", msg)
    await alice.locator("#composer-body").press("Enter")

    // sender shows it, and the OTHER user receives it over the socket (no reload).
    // Scope to #messages — getByText alone also matches the hidden sidebar preview,
    // which on mobile (sidebar off-screen) is the wrong, hidden node.
    await expect(alice.locator("#messages").getByText(msg).first()).toBeVisible()
    await expect(bob.locator("#messages").getByText(msg).first()).toBeVisible({ timeout: 12_000 })

    await shot(alice, testInfo, "02-alice-sent")
    await shot(bob, testInfo, "03-bob-received")

    expect(alice.__diag.pageErrors, "alice uncaught errors").toEqual([])
    expect(bob.__diag.pageErrors, "bob uncaught errors").toEqual([])
  })
})
