// Instant folder tabs (#445 wave 3): tapping a folder tab must flip the active state
// and slide the indicator oval AT the click — the old behavior waited for the server
// to re-render the class, so the tap read as dead for a round-trip. Proven the wave-1
// way: asserted while the socket transport is stalled.
const { test, expect } = require("../helpers/fixtures")

async function connected(page) {
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 10_000 },
  )
}

test("a folder tab answers the tap before the server does", async ({ alice, seed }, testInfo) => {
  const page = alice
  const mobile = testInfo.project.name.startsWith("mobile")
  await page.goto("/app")
  await connected(page)

  const work = page.locator(`#folder-tab-${seed.folder_id} button.ed-folder-tab`)
  const all = page.locator('button.ed-folder-tab[phx-value-id=""]')
  await expect(all).toHaveClass(/ed-folder-tab--active/)

  await page.evaluate(() => {
    window.__edOrigSend = window.liveSocket.socket.conn.send.bind(window.liveSocket.socket.conn)
    window.liveSocket.socket.conn.send = () => {}
  })

  if (mobile) {
    await work.tap()
  } else {
    await work.click()
  }
  // Both flips happen while the server cannot answer.
  await expect(work).toHaveClass(/ed-folder-tab--active/)
  await expect(all).not.toHaveClass(/ed-folder-tab--active/)
  await expect(work).toHaveAttribute("aria-pressed", "true")

  // Un-stall. The swallowed frame is GONE — an event lost in dead transport is not
  // replayed — so after the rejoin the SERVER truth (All Chats) must win again: the
  // optimistic layer never pins a lie (remount clears it; 10s cap backs that up).
  await page.evaluate(() => {
    window.liveSocket.socket.conn.send = window.__edOrigSend
    window.liveSocket.socket.conn.close()
  })
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 15_000,
  })
  await expect(all).toHaveClass(/ed-folder-tab--active/, { timeout: 10_000 })

  // And a LIVE click applies for real: same instant flip, then the ack keeps it and
  // the list filters — only the DM (in "Work") stays.
  if (mobile) {
    await work.tap()
  } else {
    await work.click()
  }
  await expect(work).toHaveClass(/ed-folder-tab--active/)
  await expect(page.locator(`.ed-convo-wrap[data-id="${seed.dm_id}"]`)).toBeVisible({
    timeout: 10_000,
  })
  await expect(page.locator(`.ed-convo-wrap[data-id="${seed.group_id}"]`)).toHaveCount(0)
})
