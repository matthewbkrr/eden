// Wave 4 — resilience on a flaky connection (the core PRODUCT.md promise). Playwright's
// setOffline/route don't tear down an already-upgraded Phoenix WebSocket, so we drive the
// real disconnect/reconnect via the LiveSocket API — exactly the path the SendQueue's
// offline-queue + flush-on-reconnect logic (#95/#142) handles.
const { test, expect, shot } = require("../helpers/fixtures")

async function submit(page, msg) {
  await page.fill("#composer-body", msg)
  await page.locator("#composer").evaluate((f) => f.requestSubmit())
}

test.describe("resilience", () => {
  test("a message composed while disconnected is queued and delivers on reconnect", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())

    // Drop alice's socket (a flaky link).
    await alice.evaluate(() => window.liveSocket.disconnect())
    await alice.waitForFunction(() => !window.liveSocket?.isConnected(), null, { timeout: 10_000 })

    const msg = `offline ${testInfo.project.name} ${Date.now()}`
    await submit(alice, msg)
    // The SendQueue keeps it as an optimistic node while disconnected (not lost).
    await expect(alice.locator("#pending-messages").getByText(msg)).toBeVisible({ timeout: 8_000 })
    await shot(alice, testInfo, "offline-queued")

    // Reconnect → the queue flushes → the peer receives it, and alice's optimistic swaps.
    await alice.evaluate(() => window.liveSocket.connect())
    await alice.waitForFunction(() => window.liveSocket?.isConnected(), null, { timeout: 15_000 })
    await expect(bob.locator("#messages").getByText(msg).first()).toBeVisible({ timeout: 15_000 })
    await shot(alice, testInfo, "offline-delivered")
    expect(bob.__diag.pageErrors).toEqual([])
  })

  test("messages queued during a drop survive and arrive in order", async ({ alice, bob, seed }, testInfo) => {
    const dm = `/app/c/${seed.dm_id}`
    await alice.goto(dm)
    await bob.goto(dm)
    await alice.waitForFunction(() => window.liveSocket?.isConnected())

    await alice.evaluate(() => window.liveSocket.disconnect())
    await alice.waitForFunction(() => !window.liveSocket?.isConnected(), null, { timeout: 10_000 })

    const stamp = Date.now()
    const a = `burst-a ${testInfo.project.name} ${stamp}`
    const b = `burst-b ${testInfo.project.name} ${stamp}`
    await submit(alice, a)
    await submit(alice, b)

    await alice.evaluate(() => window.liveSocket.connect())
    await alice.waitForFunction(() => window.liveSocket?.isConnected(), null, { timeout: 15_000 })
    await expect(bob.locator("#messages").getByText(a).first()).toBeVisible({ timeout: 15_000 })
    await expect(bob.locator("#messages").getByText(b).first()).toBeVisible({ timeout: 15_000 })
    expect(bob.__diag.pageErrors).toEqual([])
  })
})
