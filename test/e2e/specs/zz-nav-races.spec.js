// Navigation races under real-world timing (#439 wave 4). These encode the DESIRED
// behavior — on the pre-fix code each is a reproducible failure, which is the proof:
//
//  1. Back → quickly tap another chat: the delayed back-patch (backFinish fires the
//     real click ~280-450ms AFTER the tap) lands AFTER the new chat's patch and
//     yanks the user to the list ("на 2-3 клике чат не открывается").
//  2. A stalled load (dead network / suspended socket — the WebView resumes from
//     background exactly like this): the 6s safety timer dropped the overlay and
//     dumped the user back on the list ("чат вылетает"), and the composer replica
//     was a <span> — nothing to type into while the chat loads.
const { test, expect } = require("../helpers/fixtures")

async function connected(page) {
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 10_000 },
  )
}

test.describe("mobile navigation races", () => {
  test.beforeEach(({}, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only behaviors")
  })

  test("back then quickly tapping another chat lands IN that chat, not on the list", async ({ alice, seed }) => {
    const page = alice
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)

    // Header back starts the slide choreography; the aside is revealed instantly.
    await page.locator("a[data-nav-back]").tap()
    // Mid-slide (~half of the 280ms slide-out) the left edge of the list is exposed —
    // exactly when a fast user taps the next chat.
    await page.waitForTimeout(140)
    await page
      .locator(`.ed-convo-wrap[data-id="${seed.group_id}"] a.ed-convo`)
      .tap({ position: { x: 16, y: 10 } })

    // Let the back-patch (if any) land too — the bug fires ~300ms later.
    await page.waitForTimeout(2500)
    await expect(page).toHaveURL(new RegExp(`/app/c/${seed.group_id}$`))
    // And the chat pane is actually the visible screen (not the list).
    const mainHidden = await page.evaluate(() =>
      document.getElementById("chat-dropzone").classList.contains("hidden"),
    )
    expect(mainHidden, "chat pane visible after the race").toBe(false)
  })

  test("a stalled load keeps the shell up (no 6s eject) and the replica input takes text", async ({
    alice,
    seed,
  }) => {
    const page = alice
    await page.goto("/app")
    await connected(page)

    // Stall the transport: frames go into the void, the connection object stays "open".
    // This is what a suspended/resumed WebView or a dead cross-border hop looks like.
    await page.evaluate(() => {
      window.__edOrigSend = window.liveSocket.socket.conn.send.bind(window.liveSocket.socket.conn)
      window.liveSocket.socket.conn.send = () => {}
    })

    await page.locator(`.ed-convo-wrap[data-id="${seed.dm_id}"] a.ed-convo`).tap()
    const overlay = page.locator(".ed-nav-skel")
    await expect(overlay).toBeVisible()

    // While the chat loads, the composer replica must be a real input you can type into.
    const replica = page.locator(".ed-nav-skel input.ed-nav-skel__ph")
    await expect(replica, "replica composer is a focusable input").toHaveCount(1)
    await replica.tap()
    await replica.fill("printed while loading")

    // Past the old 6s safety timer: the shell must still be up — dropping it revealed
    // the list and read as "чат вылетел".
    await page.waitForTimeout(6_600)
    await expect(overlay, "overlay survives a slow load past 6s").toBeVisible()
    expect(await replica.inputValue()).toBe("printed while loading")

    // Un-stall. The queued frames are gone, so LiveView recovers the pending navigation
    // with its FULL-LOAD fallback (window.location) — the document (and overlay) die.
    // The user must still land IN the tapped chat with the typed draft intact: the
    // replica stashes keystrokes in sessionStorage and conv-shown rehydrates them.
    await page.evaluate(() => {
      window.liveSocket.socket.conn.send = window.__edOrigSend
      window.liveSocket.socket.conn.close()
    })
    await expect(page.locator("#message-scroll")).toBeVisible({ timeout: 20_000 })
    await expect(page).toHaveURL(new RegExp(`/app/c/${seed.dm_id}$`))
    await expect(page.locator("#composer-body")).toHaveValue("printed while loading", { timeout: 10_000 })
  })
})
