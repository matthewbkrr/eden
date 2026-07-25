// UX smoothness matrix (#432 audit, phase 1): measures frame cadence + long tasks for the core
// flows on every engine, Chromium projects under 4x CPU throttle (slow-device stand-in). This
// spec REPORTS (console table + artifacts/ux-smoothness-<project>.json); budgets get asserted
// once the baseline is known — then it becomes jank-regression protection like any other test.
const fs = require("fs")
const path = require("path")
const { test, expect, send } = require("../helpers/fixtures")
const { startProbe, stopProbe, throttleCPU } = require("../helpers/perf_probe")

async function connected(page) {
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 10_000 },
  )
}

// Wheel-scroll when the engine supports it; JS fallback otherwise (mobile WebKit).
async function scrollBurst(page) {
  try {
    for (let i = 0; i < 6; i++) {
      await page.mouse.wheel(0, -400)
      await page.waitForTimeout(120)
    }
    for (let i = 0; i < 6; i++) {
      await page.mouse.wheel(0, 400)
      await page.waitForTimeout(120)
    }
  } catch (_e) {
    await page.evaluate(
      () =>
        new Promise((resolve) => {
          const el = document.getElementById("message-scroll")
          let step = 0
          const tick = () => {
            step++
            el.scrollBy(0, step <= 12 ? -180 : 180)
            if (step < 24) requestAnimationFrame(tick)
            else resolve()
          }
          tick()
        }),
    )
  }
}

test("smoothness matrix: core flows", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)
  const page = alice
  const rows = []
  const measure = async (name, act) => {
    await startProbe(page)
    await act()
    await page.waitForTimeout(400) // catch post-landing settle jank (fades, swaps)
    const m = await stopProbe(page)
    rows.push({ scenario: name, ...m })
  }

  await page.goto("/app")
  await connected(page)
  const throttled = await throttleCPU(page, 4)

  const dmSel = `#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`
  const groupSel = `#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`
  const mobile = testInfo.project.name.startsWith("mobile")

  // S1: first open (skeleton path — cold cache for this page load).
  await measure("open-chat", async () => {
    await page.locator(dmSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
  })

  // S2 (mobile): back over the revealed list. On mobile the sidebar is hidden while a chat
  // is open, so chat switching goes through the list — the cache-hit setup differs per form.
  if (mobile) {
    await measure("back-to-list", async () => {
      await page.locator("[data-nav-back]").click()
      await expect.poll(() => page.url(), { timeout: 10_000 }).toMatch(/\/app$/)
    })
    // Cache-hit setup: visit the group, come back to the list.
    await page.locator(groupSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`),
    ).toBeVisible()
    await page.locator("[data-nav-back]").click()
    await expect.poll(() => page.url(), { timeout: 10_000 }).toMatch(/\/app$/)
  } else {
    // Desktop: the sidebar stays visible — switch straight to the group.
    await page.locator(groupSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`),
    ).toBeVisible()
  }

  // S3: reopen the first chat — the cache-hit paint path.
  await measure("reopen-cached", async () => {
    await page.locator(dmSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
  })

  // S4: scrolling a long-ish chat (the dm accumulates test traffic).
  await measure("scroll-history", async () => {
    await scrollBurst(page)
  })

  // S5: optimistic text send.
  const marker = `ux-probe-${Date.now()}`
  await measure("send-text", async () => {
    await send(page, marker)
    await expect(page.locator(`#messages :text("${marker}")`)).toBeVisible()
  })

  // Report: console table + a JSON artifact per project.
  const report = { project: testInfo.project.name, throttled, rows }
  const dir = path.join(__dirname, "..", "artifacts")
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(
    path.join(dir, `ux-smoothness-${testInfo.project.name}.json`),
    JSON.stringify(report, null, 2),
  )
  console.log(`\n=== smoothness ${testInfo.project.name} (throttled=${throttled}) ===`)
  for (const r of rows) {
    console.log(
      `${r.scenario.padEnd(14)} frames=${String(r.total).padStart(3)} dropped=${String(r.dropped).padStart(3)} (${r.droppedPct}%) worst=${r.worst}ms long=${r.long}/${r.longWorst}ms`,
    )
  }
  // Sanity only for now (budgets come after the baseline run).
  for (const r of rows) expect(r.total, `${r.scenario} captured frames`).toBeGreaterThan(10)
})
