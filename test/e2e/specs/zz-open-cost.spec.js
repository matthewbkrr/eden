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
const { test, expect, openMenu } = require("../helpers/fixtures")

const openBigChat = async (page, seed) => {
  await page.goto("/app")
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).first().click()
  await page.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`).waitFor()
  await page.locator("#messages > *").first().waitFor()

  // At scale: the cost is per row, and a fresh feed holds fifty. Pull history until the feed
  // stops growing rather than for a fixed number of sleeps — a slow stand would otherwise measure
  // whatever happened to have loaded (#560 review).
  let seen = -1
  for (let i = 0; i < 12; i++) {
    const before = await page.locator("#messages > *").count()
    if (before === seen) break
    seen = before
    await page.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }))
    await page
      .waitForFunction(
        (n) => document.querySelectorAll("#messages > *").length > n,
        before,
        { timeout: 3000 },
      )
      .catch(() => {}) // the top of the history: nothing more to wait for
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
      // What the instant-nav cache has to serialise, parse and store: MsgCache.put silently
      // drops anything over 1 MB, so the feed's markup decides when a scrolled chat quietly
      // stops being cached at all. Measured with the cache's OWN instrument — `new Blob([html])
      // .size`, UTF-8 bytes — because `.length` would count UTF-16 code units and a Russian feed
      // is nearly two bytes per one of those (#570 review). Reported, not gated.
      bytes: new Blob([root.innerHTML]).size,
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
  const line = `${c.rows} rows: ${c.nodes} nodes (${perRow(c.nodes)}/row), ${Math.round(c.bytes / 1024)} KB of markup, ${c.hooked} hooked (${perRow(c.hooked)}/row) ${JSON.stringify(c.hooks)}, ${c.selection} selection nodes`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(c.rows, "the feed did not grow past one page, so this measures nothing").toBeGreaterThan(
    200,
  )

  // Measured before: 450 LocalTime instances, one per row — 450 `mounted()` calls every time the
  // chat opens. One delegating formatter does the same work.
  expect(c.hooks.LocalTime || 0, `${line} — a time hook per row is back`).toBe(0)

  // Measured before: 1300 of the feed's 9441 nodes were the selection overlay — two classed nodes
  // per row, four counting the check's icon — for a mode switched on rarely. The server cannot
  // render them on demand (stream rows don't re-render on a plain assign change, which is why
  // `.SelectSync` exists), so the hook that owns the mode builds them (#561).
  expect(c.selection, `${line} — the selection overlay is back in every row`).toBe(0)

  // ...and they exist when the mode is on, or this would pass on a feature that simply stopped
  // working. Through the server's own event: reaching the menu item would test the menu instead.
  const entered = await alice.evaluate(() => {
    const row = document.querySelector("#messages [id^=messages-]")
    const id = row && /-(\d+)$/.exec(row.id)
    if (!id) return null
    window.liveSocket.execJS(
      document.body,
      JSON.stringify([["push", { event: "enter_select", value: { id: id[1] } }]]),
    )
    return id[1]
  })
  expect(entered, "no row to enter selection mode from").not.toBeNull()
  await expect(alice.locator(".ed-selbar")).toBeVisible({ timeout: 10_000 })
  await alice.waitForTimeout(300)

  const inMode = await census(alice)
  const inLine = `in selection mode: ${inMode.selection} selection nodes over ${inMode.rows} rows`
  console.log(inLine)
  testInfo.annotations.push({ type: "measurement", description: inLine })
  expect(inMode.selection, `${inLine} — the mode has no overlays at all`).toBeGreaterThan(
    inMode.rows,
  )

  // Leaving takes them off the page rather than hiding them, or nothing was saved.
  await alice.keyboard.press("Escape")
  await expect(alice.locator(".ed-selbar")).toHaveCount(0, { timeout: 10_000 })
  await alice.waitForTimeout(200)
  const after = await census(alice)
  expect(after.selection, `${after.selection} selection nodes stayed behind after exit`).toBe(0)
})

// The point of cutting them: the switch is script-bound, and the script is per row.
test("reports what switching into a long chat costs", async ({
  alice,
  seed,
  browserName,
}, testInfo) => {
  test.setTimeout(120_000)
  // `Performance.getMetrics` and CPU throttling are CDP, so this one reports on Chromium only and
  // says so rather than quietly covering one engine while looking like it covers all of them.
  test.skip(browserName !== "chromium", "CDP metrics are Chromium-only")
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
  const line = `switch into ${rows} rows at 4x CPU: script=${ms("script")}ms style=${ms("style")}ms layout=${ms("layout")}ms (reported, not gated)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  // Reported, NOT asserted (#559 review). A millisecond budget under CPU throttling flakes on a
  // loaded machine whether or not the regression it guards against is present, and a threshold
  // that fails at random teaches people to ignore it. The gate is the census above — hook and
  // node counts are deterministic and move only when the code does. This number exists so the
  // effect of that census is visible in the log.
  expect(rows, "the feed did not grow past one page, so this measures nothing").toBeGreaterThan(200)
})

// Cheaper is only worth having if the time is still right. The server renders UTC into the tag and
// the client rewrites it in the viewer's zone; losing that would show everyone the wrong clock —
// silently, because a time always looks like a time.
test("every timestamp in the feed reads in the viewer's own zone", async ({ alice, seed }) => {
  test.setTimeout(120_000)
  await openBigChat(alice, seed)

  const check = () =>
    alice.evaluate(() => {
      // Arithmetic, NOT `toLocaleTimeString` (#560 review): computing the expectation the same way
      // the hook does would only prove the hook ran, and would agree with it even if it formatted
      // in the wrong zone. Shift the instant by the browser's own offset and read the UTC clock —
      // a different path to the same answer.
      const want = (iso) => {
        const t = Date.parse(iso)
        // The offset in effect ON THAT DATE, not the one in effect now (#560 review): in a zone
        // with daylight saving those differ by an hour, and a July message read in January would
        // be judged against the wrong clock.
        const d = new Date(t - new Date(t).getTimezoneOffset() * 60000)
        return d.getUTCHours() * 60 + d.getUTCMinutes()
      }
      // Compare the MINUTE, not the string: the locale decides 24-hour vs "02:37 PM", and the
      // question here is which instant is shown, not how it is punctuated.
      const got = (txt) => {
        const m = txt.match(/(\d{1,2}):(\d{2})\s*([AaPp][Mm])?/)
        if (!m) return null
        let h = Number(m[1])
        if (m[3]) h = (h % 12) + (/[Pp]/.test(m[3]) ? 12 : 0)
        return h * 60 + Number(m[2])
      }
      const times = [...document.querySelectorAll("#messages time[datetime]")]
      return {
        total: times.length,
        wrong: times
          .filter((t) => {
            const g = got(t.textContent.trim())
            // `null` means the label did not even look like a time — wrong by definition, and it
            // must not slip through by comparing equal to anything.
            return g === null || g !== want(t.getAttribute("datetime"))
          })
          .slice(0, 3)
          .map((t) => `${t.getAttribute("datetime")} -> "${t.textContent.trim()}"`),
      }
    })

  const onOpen = await check()
  expect(onOpen.total, "no timestamps on screen, so this measures nothing").toBeGreaterThan(50)
  // ...and the zones must actually differ, or "local" and "what the server rendered" are the same
  // string and nothing here can fail.
  const offset = await alice.evaluate(() => new Date().getTimezoneOffset())
  // A UTC stand cannot answer this question — "local" and "what the server rendered" are the same
  // string there. That is a missing precondition, not a failure (#560 review).
  test.skip(offset === 0, "this stand runs in UTC, so a UTC bug would read as correct")
  expect(onOpen.wrong, `timestamps left in the server's zone: ${onOpen.wrong}`).toEqual([])

  // A newly streamed row arrives through the MutationObserver path, not the mount path.
  await alice.locator("#composer-body").click()
  await alice.locator("#composer-body").fill(`tz-${Date.now()}`)
  await alice.keyboard.press("Enter")
  await alice.waitForTimeout(1500)

  const afterSend = await check()
  expect(afterSend.total).toBeGreaterThan(onOpen.total)
  expect(afterSend.wrong, `a just-sent row kept the server's zone: ${afterSend.wrong}`).toEqual([])
})

// The thread panel renders its ROOT message above the replies list, outside it. A formatter scoped
// to the list left that one timestamp in the server's zone — the kind of gap that hides in plain
// sight, because a wrong time still looks like a time (#560 review).
//
// Threads are a rooms-only feature, so this has to happen in a room; opening a group would skip.
test("the thread root's timestamp reads in the viewer's zone too", async ({ alice, seed }) => {
  test.setTimeout(120_000)
  test.skip(!seed.thread_reply_id, "no seeded thread on this stand")

  // A reply permalink opens the thread panel directly — no context menu, no gestures. The menu
  // route is what `thread-attach-optimistic` uses, and that spec is red on `main` for its own
  // reasons; borrowing it would make this test fail for something it is not about.
  await alice.goto(
    `/channels/${seed.channel_id}/r/${seed.general_room_id}/m/${seed.thread_reply_id}`,
  )
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.locator("#thread-body").waitFor({ timeout: 15_000 })
  await alice.waitForTimeout(800)

  // Same precondition as the feed check: in UTC "local" and "what the server rendered" are one
  // string, so the test would pass on a broken formatter (#560 review).
  const offset = await alice.evaluate(() => new Date().getTimezoneOffset())
  test.skip(offset === 0, "this stand runs in UTC, so a UTC bug would read as correct")

  const root = await alice.evaluate(() => {
    const t = document.querySelector("#thread-body time[datetime]")
    if (!t) return null
    const ms = Date.parse(t.getAttribute("datetime"))
    const local = new Date(ms - new Date(ms).getTimezoneOffset() * 60000)
    const m = t.textContent.trim().match(/(\d{1,2}):(\d{2})\s*([AaPp][Mm])?/)
    if (!m) return { shown: t.textContent.trim(), got: null, want: -1 }
    let h = Number(m[1])
    if (m[3]) h = (h % 12) + (/[Pp]/.test(m[3]) ? 12 : 0)
    return {
      shown: t.textContent.trim(),
      got: h * 60 + Number(m[2]),
      want: local.getUTCHours() * 60 + local.getUTCMinutes(),
    }
  })

  expect(root, "the thread panel has no timestamp to check").not.toBeNull()
  // Explicit: an unparsable label used to leave both sides null, and null === null passed while
  // the panel showed nothing at all (#560 review).
  expect(root.got, `the thread root's timestamp did not parse: "${root.shown}"`).not.toBeNull()
  expect(root.got, `the thread root shows "${root.shown}", which is the server's zone`).toBe(
    root.want,
  )
})
