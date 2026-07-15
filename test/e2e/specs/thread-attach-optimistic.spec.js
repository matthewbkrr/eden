// Thread attachments must match the main composer (#348): attaching opens the SAME compose
// lightbox (media grid + caption + send), and sending renders the SAME optimistic rows (progress
// ring on media, .ed-file--sending card on files) in #thread-pending, swapped out by the riser
// when each real reply streams in.
//
// The optimistic node is short-lived on localhost (the upload finishes fast), so we record
// #thread-pending additions with a MutationObserver installed BEFORE Send rather than racing
// to assert a live-in-DOM node.
const { test, expect, openMenu } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

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
            hasMediaRing: !!n.querySelector(".ed-media-sending, .ed-media-sending__ring"),
            hasFileCard: !!n.querySelector(".ed-file--sending"),
            name: (n.querySelector(".ed-file__name") || {}).textContent || "",
          })
        }
    })
    window.__optimObs.observe(pending, { childList: true })
  })
}
const readSeen = (alice) => alice.evaluate(() => window.__optimSeen || [])

test("attaching in a thread opens the compose lightbox, not a cramped tray (#348)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")
  await openThread(alice, seed, "lightbox")
  await alice.locator('#reply-composer input[type="file"]').setInputFiles([fix("sample1.png"), fix("sample2.png")])
  // The SAME lightbox the main composer uses (media grid + caption + send) — not .ed-thread-tray.
  await expect(alice.locator("#reply-composer [data-upload-preview]")).toBeVisible()
  await expect(alice.locator("#reply-composer .ed-thread-tray")).toHaveCount(0)
  await expect(alice.locator("#reply-composer .ed-compose__tile")).toHaveCount(2)
  // Its caption field is scoped so it never collides with the main composer's.
  await expect(alice.locator("#reply-composer #thread-compose-caption")).toBeVisible()

  // A per-tile ✕ targets :thread_attachment (not :attachment) — one removed → one left.
  await alice.locator("#reply-composer .ed-compose__remove").first().click()
  await expect(alice.locator("#reply-composer .ed-compose__tile")).toHaveCount(1)
  // Escape (cancel_all_uploads) must clear :thread_attachment too, dismissing the lightbox.
  await alice.keyboard.press("Escape")
  await expect(alice.locator("#reply-composer [data-upload-preview]")).toHaveCount(0)
  expect(alice.__diag.pageErrors).toEqual([])
})

test("sending an album in a thread shows optimistic media with a ring (#348)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")
  await openThread(alice, seed, "album")

  await alice.locator('#reply-composer input[type="file"]').setInputFiles([fix("sample1.png"), fix("sample2.png")])
  await expect(alice.locator("#reply-composer [data-upload-preview]")).toBeVisible()

  await watchPending(alice)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())

  await expect(alice.locator("#thread-replies .ed-album").first()).toBeVisible({ timeout: 15_000 })
  const seen = await readSeen(alice)
  const album = seen.find((s) => s.hasImg && s.hasMediaRing)
  expect(album, `optimistic album with ring seen (got ${JSON.stringify(seen)})`).toBeTruthy()

  // The lightbox cleared and the optimistic node was swapped out (riser) — #thread-pending is empty.
  await expect(alice.locator("#reply-composer [data-upload-preview]")).toHaveCount(0)
  await expect(alice.locator("#thread-pending [data-client-id]")).toHaveCount(0, { timeout: 12_000 })
  expect(alice.__diag.pageErrors).toEqual([])
})

test("sending a file in a thread shows an optimistic sending card (#348)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")
  await openThread(alice, seed, "file")

  await alice.locator('#reply-composer input[type="file"]').setInputFiles(fix("qa.txt"))
  await expect(alice.locator("#reply-composer [data-upload-preview]")).toBeVisible()

  await watchPending(alice)
  await alice.locator("#reply-composer").evaluate((f) => f.requestSubmit())

  await expect(alice.locator("#thread-replies .ed-file").first()).toBeVisible({ timeout: 15_000 })
  const seen = await readSeen(alice)
  const card = seen.find((s) => s.hasFileCard)
  expect(card, `optimistic file card seen (got ${JSON.stringify(seen)})`).toBeTruthy()
  expect(card.name).toContain("qa")

  await expect(alice.locator("#thread-pending [data-client-id]")).toHaveCount(0, { timeout: 12_000 })
  expect(alice.__diag.pageErrors).toEqual([])
})

// #380/R066: switching to another thread in the SAME room must not WIPE #thread-pending — an
// attachment send to the thread we're leaving is still uploading, and its optimistic node lives
// there. Every thread node is tagged data-thread-root, so updated() hides the other threads' nodes
// and shows this one's (mirroring the main pane's #144), instead of the old replaceChildren() blank.
test("switching threads hides an in-flight node instead of wiping it (#380/R066)", async ({
  alice,
  seed,
}) => {
  await alice.goto(room(seed))
  await alice.waitForFunction(() => window.liveSocket?.isConnected())

  const stamp = Date.now()
  const rootAText = `r066-A ${stamp}`
  const rootBText = `r066-B ${stamp}`
  for (const t of [rootAText, rootBText]) {
    await alice.locator("#composer-body").fill(t)
    await alice.locator("#composer").evaluate((f) => f.requestSubmit())
    await expect(alice.locator("#messages .ed-flat", { hasText: t }).first()).toBeVisible()
  }

  // Open a thread and return its root id. #reply-composer is already visible when a thread is open,
  // so a plain visibility wait wouldn't catch a switch — poll data-thread-root until it CHANGES.
  const currentRoot = () =>
    alice.evaluate(() => document.getElementById("reply-composer")?.dataset.threadRoot || "")
  const openThreadOn = async (text, prevRoot) => {
    const row = alice.locator("#messages .ed-flat", { hasText: text }).first()
    const menu = await openMenu(alice, row)
    await menu.getByText("Reply in thread", { exact: true }).click()
    await expect(alice.locator("#reply-composer")).toBeVisible()
    await expect.poll(currentRoot, { timeout: 12_000 }).not.toBe(String(prevRoot ?? ""))
    return currentRoot()
  }

  // Open thread A, then plant an in-flight optimistic node in #thread-pending tagged for it.
  const rootA = await openThreadOn(rootAText)
  await alice.evaluate((root) => {
    const n = document.createElement("div")
    n.className = "ed-flat"
    n.dataset.clientId = "fake-r066-inflight"
    n.dataset.threadRoot = String(root)
    n.textContent = "uploading in thread A…"
    document.getElementById("thread-pending").appendChild(n)
  }, rootA)
  const node = alice.locator('#thread-pending [data-client-id="fake-r066-inflight"]')
  await expect(node).toBeVisible()

  // Switch to thread B → the node is HIDDEN, not removed (the old replaceChildren() wiped it).
  const rootB = await openThreadOn(rootBText, rootA)
  expect(rootB).not.toBe(rootA)
  await expect(node).toHaveCount(1)
  await expect(node).toBeHidden()

  // Return to thread A → its in-flight node is shown again.
  await openThreadOn(rootAText, rootB)
  await expect(node).toBeVisible()
  expect(alice.__diag.pageErrors).toEqual([])
})
