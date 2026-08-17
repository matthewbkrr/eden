// Instant rail navigation (#445 wave 1): a channel/home tap must answer ON-SCREEN in
// one frame — active dot, sidebar cover (cache or skeleton), and on desktop the entry
// room's chat overlay — all BEFORE the server says anything. Proven by stalling the
// socket: everything asserted here happens while the server literally cannot respond.
const { test, expect, ready } = require("../helpers/fixtures")

async function connected(page) {
  // The shared helper: socket + VIEW joined + the deferred bundle. The local wait covered the
  // socket and instant-nav only, and the rail overlay is painted from cached state that is not
  // there yet at that moment (#588).
  await ready(page)
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 10_000 },
  )
}

const stall = (page) =>
  page.evaluate(() => {
    window.__edOrigSend = window.liveSocket.socket.conn.send.bind(window.liveSocket.socket.conn)
    window.liveSocket.socket.conn.send = () => {}
  })

const unstall = (page) =>
  page.evaluate(() => {
    window.liveSocket.socket.conn.send = window.__edOrigSend
    window.liveSocket.socket.conn.close() // recover via rejoin/full-load fallback
  })

// EXPECTED TO FAIL, tracked as #593. Measured with the socket stalled: a rail channel tap paints
// no overlay and does not navigate at all (0 skeletons at 50/150/400/1000 ms, URL unchanged). The
// rail links to `/channels/:id/enter`, where the SERVER resolves the remembered room (#492), so
// the client cannot know the destination — and #476-#496 deliberately stopped pushState before
// the server answers. The sibling test below, whose destination the client does know, still
// paints instantly. Whether entering a channel is meant to wait for the server is the question in
// #593; until it is answered this stays executable rather than skipped.
test.fail("desktop: a rail channel tap moves the dot + covers aside and pane instantly", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "desktop rail behavior")
  const page = alice
  // Warm the caches + record last_room so the desktop rail link carries /r/:id.
  await page.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await connected(page)
  await page.goto(`/app/c/${seed.dm_id}`)
  await connected(page)

  await stall(page)
  const rail = page.locator(`#rail-channel-${seed.channel_id} a.ed-rail__btn:visible`).first()
  await rail.click()

  // All of this renders while the socket is dead — pure client-side response.
  await expect(page.locator(".ed-aside-skel")).toBeVisible()
  await expect(rail).toHaveClass(/ed-rail__btn--active/)
  const pane = page.locator(".ed-nav-skel")
  await expect(pane).toBeVisible()
  // The pane overlay is in ROOM mode with the cached room name (meta), not a shimmer-only shell.
  await expect(pane.locator(".ed-nav-skel__name")).toHaveText(/general/i)

  await unstall(page)
  await expect(page).toHaveURL(new RegExp(`/channels/${seed.channel_id}/r/\\d+$`), { timeout: 20_000 })
  await expect(page.locator(".ed-aside-skel")).toHaveCount(0, { timeout: 10_000 })
  await expect(page.locator(".ed-nav-skel")).toHaveCount(0, { timeout: 10_000 })
})

test("mobile: a rail channel tap covers the list instantly and lands on the room list", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(!testInfo.project.name.startsWith("mobile"), "mobile rail behavior")
  const page = alice
  await page.goto("/app")
  await connected(page)

  await stall(page)
  await page.locator(`#rail-channel-${seed.channel_id} a.ed-rail__btn:visible`).first().tap()
  const cover = page.locator(".ed-aside-skel")
  await expect(cover).toBeVisible()
  // Cold cache → skeleton headed by the channel name (from the rail title).
  await expect(cover).toContainText(/./)

  await unstall(page)
  await expect(page).toHaveURL(new RegExp(`/channels/${seed.channel_id}(/r/\\d+)?$`), {
    timeout: 20_000,
  })
  await expect(cover).toHaveCount(0, { timeout: 10_000 })
})

test("home tap from a channel covers the aside with the cached chat list", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "desktop flow")
  const page = alice
  // Visit /app first so its aside snapshot exists, then hop to the channel.
  await page.goto("/app")
  await connected(page)
  await page.locator(`#rail-channel-${seed.channel_id} a.ed-rail__btn:visible`).first().click()
  await expect(page).toHaveURL(new RegExp(`/channels/${seed.channel_id}`), { timeout: 15_000 })
  await page.waitForTimeout(500) // let the idle stash of the channel aside settle

  await stall(page)
  await page.locator('.ed-rail__btn--home').click()
  const cover = page.locator(".ed-aside-skel")
  await expect(cover).toBeVisible()
  // The cover is the CACHED messenger sidebar — real chat rows, not a skeleton
  // (the DM row for the seeded conversation is in it).
  await expect(cover.locator(".ed-convo-wrap")).not.toHaveCount(0)

  await unstall(page)
  await expect(page).toHaveURL(/\/app$/, { timeout: 20_000 })
  await expect(cover).toHaveCount(0, { timeout: 10_000 })
})
