// #119 — pick the next media batch WHILE one is uploading: it queues client-side (held off
// the shared :attachment config so it can't merge into the in-flight album), a hint shows
// how many wait, and it surfaces for sending once the in-flight send frees the config.
const { test, expect } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

test("a batch picked while another uploads queues, hints, surfaces, never merges (#119)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const before = await alice.locator("#messages a.ed-file").count()

  // Send batch A (a ~400KB file → a real upload window).
  await alice.locator('#composer input[type="file"]').setInputFiles(fix("qa.txt"))
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await alice.locator('[data-upload-preview] button[type="submit"]').click()
  // The overlay closing means onSubmit ran (A is now uploading, mediaInFlight set). Pick B
  // now — well within A's upload — so it hits the queue, not A's batch. (mediaInFlight is the
  // client-side truth set at Send, so this gate holds even before the server's round-trip —
  // which on a slow link lags by seconds.)
  await expect(alice.locator("[data-upload-preview]")).toBeHidden()
  await alice.locator('#composer input[type="file"]').setInputFiles(fix("qb.txt"))
  await expect(alice.locator(".ed-queued")).toBeVisible()
  await expect(alice.locator(".ed-queued")).toContainText("1")

  // A finishes → its SINGLE-file message lands (B did not merge, else A carries 2 files),
  // B surfaces in the compose overlay, and the hint clears.
  await expect(alice.locator("#messages a.ed-file")).toHaveCount(before + 1, { timeout: 15000 })
  await expect(alice.locator("[data-upload-preview]")).toBeVisible({ timeout: 10000 })
  await expect(alice.locator(".ed-queued")).toHaveCount(0)

  // Send B from its surfaced overlay → it lands as its OWN second message (strictly after A).
  await alice.locator('[data-upload-preview] button[type="submit"]').click()
  await expect(alice.locator("#messages a.ed-file")).toHaveCount(before + 2, { timeout: 15000 })
})

// NOTE: cancelling a surfaced queued batch must still surface the next one (the config-free
// edge fires on the overlay closing, not only on a send completing — no dead-end). That path
// needs TWO batches queued behind one upload, which requires an upload slow enough to span
// two picks — not reproducible on localhost without a large committed fixture, so it was
// verified manually (big file + Escape on the surfaced batch → the next surfaces). The
// freeing-edge trigger it relies on is exercised by the test above.
