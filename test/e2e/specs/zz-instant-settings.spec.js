// Instant app <-> settings hops (#445 wave 2): the cross-LiveView navigate (full
// remount) must answer on-screen in one frame. Proven the wave-1 way: everything
// asserted while the socket transport is stalled — the server cannot have answered.
const { test, expect } = require("../helpers/fixtures")

// __edInstantNavReady is ChatLive's beacon — it doesn't exist on settings pages, so
// the generic wait is socket-only; chat pages get the stricter variant.
async function connected(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 10_000,
  })
  const path = new URL(page.url()).pathname
  if (!/^\/(app\/)?settings(\/|$)/.test(path) && /^\/(app|channels)(\/|$)/.test(path)) {
    await page.waitForFunction(() => window.__edInstantNavReady, null, { timeout: 10_000 })
  }
}

const stall = (page) =>
  page.evaluate(() => {
    window.__edOrigSend = window.liveSocket.socket.conn.send.bind(window.liveSocket.socket.conn)
    window.liveSocket.socket.conn.send = () => {}
  })

const unstall = (page) =>
  page.evaluate(() => {
    window.liveSocket.socket.conn.send = window.__edOrigSend
    window.liveSocket.socket.conn.close()
  })

const skipMobile = (testInfo) =>
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough — pure client behavior")

test("cold hop: the neutral shell paints while the server is mute", async ({ alice }, testInfo) => {
  skipMobile(testInfo)
  const page = alice
  await page.goto("/app")
  await connected(page)
  await stall(page)
  await page.locator('a[href="/app/settings"]').first().click()
  await expect(page.locator(".ed-page-skel")).toBeVisible()
  await unstall(page)
  await expect(page).toHaveURL(/\/app\/settings$/, { timeout: 20_000 })
  await expect(page.locator(".ed-page-skel")).toHaveCount(0, { timeout: 10_000 })
})

test("warm hop to settings: the cover is the cached settings page itself", async ({
  alice,
}, testInfo) => {
  skipMobile(testInfo)
  const page = alice
  await page.goto("/app")
  await connected(page)
  // Live round-trip warms the settings stash (loading-stop) — no full loads involved.
  await page.locator('a[href="/app/settings"]').first().click()
  await expect(page).toHaveURL(/\/app\/settings$/, { timeout: 20_000 })
  await connected(page)
  await page.locator('a[href="/app"]').first().click()
  await expect(page).toHaveURL(/\/app$/, { timeout: 20_000 })
  await connected(page)

  await stall(page)
  await page.locator('a[href="/app/settings"]').first().click()
  const cover = page.locator(".ed-page-skel")
  await expect(cover).toBeVisible()
  await expect(cover.locator(".ed-settings-nav")).toBeVisible()
  await unstall(page)
  await expect(page).toHaveURL(/\/app\/settings$/, { timeout: 20_000 })
  await expect(cover).toHaveCount(0, { timeout: 10_000 })
})

test("warm hop back to the app: the cover is the cached chat shell, rail and all", async ({
  alice,
}, testInfo) => {
  skipMobile(testInfo)
  const page = alice
  await page.goto("/app")
  await connected(page)
  // The way out stashes the /app render at click time (live hop, window survives).
  await page.locator('a[href="/app/settings"]').first().click()
  await expect(page).toHaveURL(/\/app\/settings$/, { timeout: 20_000 })
  await connected(page)

  await stall(page)
  await page.locator('a[href="/app"]').first().click()
  const cover = page.locator(".ed-page-skel")
  await expect(cover).toBeVisible()
  await expect(cover.locator(".ed-rail")).toBeVisible()
  await unstall(page)
  await expect(page).toHaveURL(/\/app$/, { timeout: 20_000 })
  await expect(cover).toHaveCount(0, { timeout: 10_000 })
})
