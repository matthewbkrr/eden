// Thread attachments must show on-send feedback: attaching + sending files in a thread
// used to be silent — queue_start cancels the staged tray, so the picked files vanished
// and nothing showed until each reply streamed in. Now an optimistic "sending" row is
// minted in #thread-pending (keyed by the client_id its real reply carries), and the
// .ScrollBottom riser swaps it out when the reply lands.
//
// The optimistic node is short-lived on localhost (the upload finishes fast), so we record
// #thread-pending additions with a MutationObserver installed BEFORE Send rather than
// racing to assert a live-in-DOM node.
const { test, expect, openMenu } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

// Open a fresh thread off a new root and return the reply-composer locator context.
async function openThread(alice, seed, label) {
  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const rootText = `optim-root ${label} ${Date.now()}`
  await alice.locator("#composer-body").fill(rootText)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const rootRow = alice.locator("#messages .ed-flat", { hasText: rootText }).first()
  await expect(rootRow).toBeVisible()
  const menu = await openMenu(alice, rootRow)
  await menu.getByText("Reply in thread", { exact: true }).click()
  await expect(alice.locator("#reply-composer")).toBeVisible()
}

// Record every data-client-id node added to #thread-pending (with what it contains) so a
// fast swap can't hide the optimistic node from the assertion.
async function watchPending(alice) {
  await alice.evaluate(() => {
    window.__optimSeen = []
    const pending = document.getElementById("thread-pending")
    window.__optimObs = new MutationObserver((muts) => {
      for (const m of muts)
        for (const n of m.addedNodes) {
          if (n.nodeType !== 1 || !n.dataset || !n.dataset.clientId) continue
          window.__optimSeen.push({
            clientId: n.dataset.clientId,
            hasImg: !!n.querySelector("img"),
            hasSpinner: !!n.querySelector(".hero-arrow-path"),
            hasFileCard: !!n.querySelector(".ed-file--sending"),
            name: (n.querySelector(".ed-file__name") || {}).textContent || "",
          })
        }
    })
    window.__optimObs.observe(pending, { childList: true })
  })
}
const readSeen = (alice) => alice.evaluate(() => window.__optimSeen || [])

test("sending an album in a thread shows an optimistic sending node (#346)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await openThread(alice, seed, "album")

  // Attach two photos → the staging tray shows before send.
  await alice.locator('#reply-composer input[type="file"]').setInputFiles([fix("sample1.png"), fix("sample2.png")])
  await expect(alice.locator("#reply-composer .ed-thread-tray")).toBeVisible()
  await expect(alice.locator("#reply-composer .ed-thread-tray__item")).toHaveCount(2)

  await watchPending(alice)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())

  // The album reply streams into the thread; its optimistic twin was shown while it uploaded.
  await expect(alice.locator("#thread-replies .ed-album").first()).toBeVisible({ timeout: 15_000 })
  const seen = await readSeen(alice)
  const album = seen.find((s) => s.hasImg && s.hasSpinner)
  expect(album, `optimistic album node seen (got ${JSON.stringify(seen)})`).toBeTruthy()

  // The tray cleared and the optimistic node was swapped out (riser) — #thread-pending is empty.
  await expect(alice.locator("#reply-composer .ed-thread-tray")).toHaveCount(0)
  await expect(alice.locator("#thread-pending [data-client-id]")).toHaveCount(0, { timeout: 12_000 })
  expect(alice.__diag.pageErrors).toEqual([])
})

test("sending a file in a thread shows an optimistic sending card (#346)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await openThread(alice, seed, "file")

  await alice.locator('#reply-composer input[type="file"]').setInputFiles(fix("qa.txt"))
  await expect(alice.locator("#reply-composer .ed-thread-tray")).toBeVisible()

  await watchPending(alice)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())

  // The file reply lands; its optimistic sending card was shown (name + spinner, no ring).
  await expect(alice.locator("#thread-replies .ed-file").first()).toBeVisible({ timeout: 15_000 })
  const seen = await readSeen(alice)
  const card = seen.find((s) => s.hasFileCard && s.hasSpinner)
  expect(card, `optimistic file card seen (got ${JSON.stringify(seen)})`).toBeTruthy()
  expect(card.name).toContain("qa")

  await expect(alice.locator("#thread-pending [data-client-id]")).toHaveCount(0, { timeout: 12_000 })
  expect(alice.__diag.pageErrors).toEqual([])
})
