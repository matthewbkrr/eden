// What opening a chat costs (#557, part of epic #506).
//
// The epic's remaining broken budget is "no main-thread task over 50ms while navigating", and the
// switch measured 100ms. Where that goes was not what the epic assumed:
//
//   * The profile's top entry, `visitNode <- captureSnapshot`, is Playwright's own DOM snapshotter.
//     It disappears with `--trace off`, so part of the original numbers measured the harness.
//   * Serialising the feed into the cache costs 12ms of it, not the bulk.
//   * `Performance.getMetrics` across the switch: script 98ms, style 33ms, layout 15ms. It is a
//     script problem, and the script is per-row: 462 rows carried 1075 hook instances.
//
// So this file counts what the feed is made of, not how long a frame took. A count is
// deterministic; a millisecond on a loaded stand is not.
const { test, expect } = require("../helpers/fixtures")

const openBigChat = async (page, seed) => {
  await page.goto("/app")
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).first().click()
  await page.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`).waitFor()
  await page.waitForTimeout(1200)
  // At scale: the cost is per row, and a fresh feed holds fifty.
  for (let i = 0; i < 8; i++) {
    await page.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }))
    await page.waitForTimeout(300)
  }
}

const census = (page) =>
  page.evaluate(() => {
    const root = document.getElementById("messages")
    const hooks = {}
    for (const n of root.querySelectorAll("[phx-hook]")) {
      const k = n.getAttribute("phx-hook").split(".").pop()
      hooks[k] = (hooks[k] || 0) + 1
    }
    return {
      rows: root.children.length,
      nodes: root.querySelectorAll("*").length,
      hooked: root.querySelectorAll("[phx-hook]").length,
      hooks,
      selection: root.querySelectorAll(".ed-select-hit, .ed-select-check").length,
    }
  })

test("the feed does not carry a hook and a selection widget per row", async ({
  alice,
  seed,
}, testInfo) => {
  test.setTimeout(120_000)
  await openBigChat(alice, seed)

  const c = await census(alice)
  const perRow = (n) => Math.round((n / c.rows) * 100) / 100
  const line = `${c.rows} rows: ${c.nodes} nodes (${perRow(c.nodes)}/row), ${c.hooked} hooked (${perRow(c.hooked)}/row) ${JSON.stringify(c.hooks)}, ${c.selection} selection nodes`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(c.rows, "the feed did not grow past one page, so this measures nothing").toBeGreaterThan(
    200,
  )

  // Measured before: 450 LocalTime instances, one per row — 450 `mounted()` calls every time the
  // chat opens. One delegating formatter does the same work.
  expect(c.hooks.LocalTime || 0, `${line} — a time hook per row is back`).toBe(0)

  // Measured before: 900 nodes of multi-select machinery in a feed nobody is selecting in.
  expect(c.selection, `${line} — selection widgets render outside selection mode`).toBe(0)
})

// The point of cutting them: the switch is script-bound, and the script is per row.
test("switching into a long chat stays under the script budget", async ({
  alice,
  seed,
}, testInfo) => {
  test.setTimeout(120_000)
  const cdp = await alice.context().newCDPSession(alice)
  await cdp.send("Performance.enable")
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 })

  await openBigChat(alice, seed)
  const rows = (await census(alice)).rows

  const grab = async () => {
    const { metrics } = await cdp.send("Performance.getMetrics")
    const m = Object.fromEntries(metrics.map((x) => [x.name, x.value]))
    return { script: m.ScriptDuration, layout: m.LayoutDuration, style: m.RecalcStyleDuration }
  }

  // Leave, then come back: the return is the expensive direction (the stream mounts again).
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).first().click()
  await alice.waitForTimeout(1500)

  const before = await grab()
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).first().click()
  await alice.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`).waitFor()
  await alice.waitForTimeout(2000)
  const after = await grab()

  const ms = (k) => Math.round((after[k] - before[k]) * 1000)
  const line = `switch into ${rows} rows at 4x CPU: script=${ms("script")}ms style=${ms("style")}ms layout=${ms("layout")}ms`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  // Measured before the cut: script 98ms. This is a wide bound, not a stopwatch — it separates
  // "per-row hooks are back" from "they are not" and nothing finer.
  expect(ms("script"), `${line} — the switch is doing per-row script work again`).toBeLessThan(75)
})
