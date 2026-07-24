// Instant-navigation message cache (#427, phase 2): re-opening a chat paints its last-seen thread
// from cache INSTANTLY (in-memory for same-session revisits, IndexedDB across reloads), while the
// real stream loads and replaces it. The cache only ever feeds the display-only overlay, so it's
// never authoritative — the real stream always reconciles (no duplicate rows).
const { test, expect, shot } = require("../helpers/fixtures")

async function connected(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 10_000,
  })
}

test.describe("instant navigation cache", () => {
  test("same-session revisit paints the cached thread synchronously (no skeleton)", async ({
    alice,
    seed,
  }) => {
    const page = alice
    await page.goto("/app")
    await connected(page)

    const aSel = `#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`
    const bSel = `#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`

    // Open A → its real messages render → ed:conv-shown snapshots it into the cache.
    await page.locator(aSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    const realCount = await page.locator("#messages .ed-msg, #messages .ed-flat").count()
    expect(realCount, "A must have messages to cache").toBeGreaterThan(0)

    // Switch to B so A is no longer the active row.
    await page.locator(bSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`),
    ).toBeVisible()

    // Revisit A: the in-memory peek paints cached content with NO await — probe the overlay in the
    // same task as the click.
    const probe = await page.evaluate((sel) => {
      document.querySelector(sel).click()
      const ov = document.querySelector(".ed-nav-skel")
      return {
        overlayCount: document.querySelectorAll(".ed-nav-skel").length,
        cached: !!ov?.querySelector(".ed-nav-skel__body--cache"),
        realRows: ov ? ov.querySelectorAll(".ed-msg, .ed-flat").length : 0,
        skelBubbles: ov ? ov.querySelectorAll(".ed-nav-skel__bubble").length : 0,
      }
    }, aSel)
    expect(probe.overlayCount, "exactly one overlay (no stale fade left behind)").toBe(1)
    expect(probe.cached, "overlay body carries cached real rows, not skeleton").toBe(true)
    expect(probe.realRows).toBeGreaterThan(0)
    expect(probe.skelBubbles, "no skeleton bubbles when cache hits").toBe(0)

    // Reconciliation: real stream lands, overlay clears, #messages holds the real rows ONCE.
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    await expect.poll(() => page.locator(".ed-nav-skel").count()).toBe(0)
    expect(await page.locator("#messages .ed-msg, #messages .ed-flat").count()).toBe(realCount)
  })

  test("cross-reload revisit paints from IndexedDB", async ({ alice, seed }, testInfo) => {
    const page = alice
    // Open A on a fresh load → the snapshot persists to IndexedDB.
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await expect(page.locator("#messages .ed-msg, #messages .ed-flat").first()).toBeVisible()
    await page.waitForTimeout(400) // let the async IDB put settle

    // Full reload wipes the in-memory cache; the IDB snapshot survives. Slow the server so the IDB
    // fill wins the race and is observable before the real stream replaces it.
    await page.goto("/app")
    await connected(page)
    await page.evaluate(() => window.liveSocket.enableLatencySim(2500))

    await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).click()
    await expect(page.locator(".ed-nav-skel")).toBeVisible()
    // Skeleton first, then the async IDB read swaps in the cached rows.
    await expect(page.locator(".ed-nav-skel .ed-nav-skel__body--cache")).toBeVisible({
      timeout: 4_000,
    })
    expect(
      await page.locator(".ed-nav-skel .ed-msg, .ed-nav-skel .ed-flat").count(),
    ).toBeGreaterThan(0)
    await shot(page, testInfo, "cache-thread-from-idb")
    await page.evaluate(() => window.liveSocket.disableLatencySim())
  })
})
