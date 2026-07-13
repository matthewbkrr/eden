// #361/R103 — with the sequential send engine (:attachment_seq) there is NO "in queue" gating
// anymore: a second batch picked while the first is still uploading just re-opens the compose
// overlay and sends normally; the engine queues it behind the in-flight one, so both land as
// their OWN ordered messages. (This replaces the old #119 `.ed-queued` / `mediaInFlight`
// assertions, whose UI was removed with the concurrent engine.)
const { test, expect } = require("../helpers/fixtures")
const path = require("path")
const fix = (n) => path.join(__dirname, "..", "fixtures", n)

test("two batches picked back-to-back arrive as separate ordered messages (#361/R103)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/webkit|safari/i.test(testInfo.project.name), "WebKit transfers no upload bytes")

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const before = await alice.locator("#messages a.ed-file").count()

  // Send batch A.
  await alice.locator('#composer input[type="file"]').setInputFiles(fix("qa.txt"))
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await alice.locator('[data-upload-preview] button[type="submit"]').click()
  // The overlay closing means the send started (A is uploading on :attachment_seq).
  await expect(alice.locator("[data-upload-preview]")).toBeHidden()

  // Pick batch B right away — no "in queue" gating: the overlay just re-opens as a normal new
  // send (there is no `.ed-queued` element in the sequential engine).
  await alice.locator('#composer input[type="file"]').setInputFiles(fix("qb.txt"))
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await expect(alice.locator(".ed-queued")).toHaveCount(0)
  await alice.locator('[data-upload-preview] button[type="submit"]').click()

  // Both land as their OWN messages — B never merges into A — the engine sent them in order.
  await expect(alice.locator("#messages a.ed-file")).toHaveCount(before + 2, { timeout: 20000 })
})
