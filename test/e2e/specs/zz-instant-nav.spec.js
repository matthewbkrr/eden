// Instant-navigation skeleton (#instant-nav): tapping a sidebar chat must paint the
// target's shell + a shimmer skeleton in the SAME frame (client-side, no server round-trip),
// then fade it out once .ScrollBottom announces the real stream landed (ed:conv-shown).
//
// The overlay window is tiny on localhost, so instead of racing a screenshot we instrument
// the DOM: a MutationObserver records the overlay's add (with its painted name) and remove,
// and a listener counts ed:conv-shown. That proves the whole handshake deterministically.
const { test, expect, shot } = require("../helpers/fixtures")

async function instrument(page) {
  await page.evaluate(() => {
    window.__skel = { addedName: null, hasShimmer: false, full: false, removed: false, shown: 0 }
    const mo = new MutationObserver((muts) => {
      for (const m of muts) {
        for (const n of m.addedNodes) {
          if (n.nodeType === 1 && n.classList && n.classList.contains("ed-nav-skel")) {
            window.__skel.addedName = (n.querySelector(".ed-nav-skel__name")?.textContent || "").trim()
            window.__skel.hasShimmer = !!n.querySelector(".ed-skel-shimmer")
            window.__skel.full = n.classList.contains("ed-nav-skel--full")
          }
        }
        for (const n of m.removedNodes) {
          if (n.nodeType === 1 && n.classList && n.classList.contains("ed-nav-skel")) {
            window.__skel.removed = true
          }
        }
      }
    })
    mo.observe(document.body, { childList: true })
    window.addEventListener("ed:conv-shown", () => window.__skel.shown++)
  })
}

async function connected(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 10_000,
  })
}

test.describe("instant navigation skeleton", () => {
  test("DM tap: paints shell + skeleton, fades on real stream", async ({ alice, seed }, testInfo) => {
    const page = alice
    await page.goto("/app")
    await connected(page)
    await instrument(page)

    const dm = page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`)
    await expect(dm).toBeVisible()
    const name = (await dm.locator(".ed-convo__name").first().textContent()).trim()
    await dm.click()

    // The chat actually opened (real stream present for the target conversation).
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()

    const skel = await page.evaluate(() => window.__skel)
    expect(skel.addedName, "overlay painted the tapped row's real name").toBe(name)
    expect(skel.hasShimmer, "overlay carries a shimmer skeleton").toBe(true)
    expect(skel.shown, "ed:conv-shown fired once the real stream landed").toBeGreaterThan(0)

    // And it clears itself — no stranded overlay.
    await expect.poll(() => page.evaluate(() => window.__skel.removed)).toBe(true)
    await expect(page.locator(".ed-nav-skel")).toHaveCount(0)

    await shot(page, testInfo, "instant-nav-dm-opened")
  })

  test("room tap: overlay uses the room name + flat skeleton", async ({ alice, seed }, testInfo) => {
    const page = alice
    // Enter the channel first so the room list is in the sidebar, then tap the general room.
    await page.goto(`/channels/${seed.channel_id}`)
    await connected(page)
    await instrument(page)

    const room = page.locator(
      `a.ed-convo.ed-room[href$="/channels/${seed.channel_id}/r/${seed.general_room_id}"]`,
    )
    await expect(room).toBeVisible()
    const name = (await room.locator(".ed-convo__name").first().textContent()).trim()
    await room.click()

    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.general_room_id}"]`),
    ).toBeVisible()

    const skel = await page.evaluate(() => window.__skel)
    expect(skel.addedName).toBe(name)
    expect(skel.hasShimmer).toBe(true)
    expect(skel.shown).toBeGreaterThan(0)
    await expect.poll(() => page.evaluate(() => window.__skel.removed)).toBe(true)

    await shot(page, testInfo, "instant-nav-room-opened")
  })

  test("skeleton visual (light + dark)", async ({ alice, seed }, testInfo) => {
    const page = alice
    await page.goto("/app")
    await connected(page)
    const dm = page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`)
    await dm.waitFor()
    // Slow the socket round-trip so the real overlay lingers (real dismiss path, just delayed)
    // — long enough to screenshot both themes. No event hacks: this is exactly what a bad
    // connection does, and it's what makes the effect worth having.
    await page.evaluate(() => window.liveSocket.enableLatencySim(3000))
    await dm.click()
    await expect(page.locator(".ed-nav-skel")).toBeVisible()
    await shot(page, testInfo, "skeleton-light")
    await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"))
    await page.waitForTimeout(150)
    await expect(page.locator(".ed-nav-skel")).toBeVisible()
    await shot(page, testInfo, "skeleton-dark")
    await page.evaluate(() => window.liveSocket.disableLatencySim())
  })

  test("tapping the already-open chat paints no overlay", async ({ alice, seed }, testInfo) => {
    // On mobile the sidebar is hidden while a chat is open, so the active row can't be tapped.
    test.skip(testInfo.project.name.startsWith("mobile"), "sidebar hidden when a chat is open on mobile")
    const page = alice
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await instrument(page)

    // The open chat's row carries .ed-convo--active — a re-tap is a no-op, so no overlay.
    const active = page.locator(`#conversations a.ed-convo.ed-convo--active`)
    await expect(active).toBeVisible()
    await active.click()
    await page.waitForTimeout(400)

    expect(await page.evaluate(() => window.__skel.addedName)).toBeNull()
    await expect(page.locator(".ed-nav-skel")).toHaveCount(0)
  })
})
