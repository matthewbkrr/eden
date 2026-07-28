// Mobile navigation races — the STRESS harness for two intermittent field bugs the
// user has never been able to catch by hand (see #439/#432/#462 for the earlier,
// deterministic single-shot repros in zz-nav-races.spec.js):
//
//   (B) "wrong chat"   — rapid switching lands on a chat that was NOT the last one
//                        tapped (one never tapped, or one tapped earlier).
//   (A) "ghost menu"   — an edge-swipe back / header back + rapid switching pops the
//                        sidebar row's CONTEXT MENU as if it had been long-pressed.
//
// Both are timing bugs, so this file is a LOOP, not a scenario: N iterations sweeping
// a delay (0/30/60/120/250ms — deliberately landing mid-flight), rotating the back
// gesture (header button / edge swipe / system back), under a simulated RTT.
//
// The oracle for (B) is not "the URL I expected" but "the LAST a.ed-convo click the
// DOM actually saw" — recorded by a capture-phase listener installed before any hook.
// That is exactly the user's complaint ("I tapped X and got Y"), and it can't produce
// a false positive when a tap is swallowed by the sliding pane (those are counted
// separately as `swallowed`).
//
// The oracle for (A) is a MutationObserver on every [data-menu]'s `hidden` attribute:
// a menu that opens and is closed again by the next tap would be invisible to polling.
// Every synthesised touch here is < 250ms and/or moves > 10px, i.e. NEVER a legitimate
// long-press (450ms) — so any recorded menu is a bug, not the feature.
//
// Instrumentation (dumped on failure — the log is the point):
//   window.__navLog   every pushState / replaceState / popstate / a-click / test mark,
//                     with location.pathname + history.length + a ms timestamp.
//   window.__menuLog  every context-menu open (host id + path + t).
//   window.__touchLog every touchstart/end/cancel that reached `document` — a
//                     touchstart with no matching touchend is the smoking gun for a
//                     row that was morphed out from under a live gesture.
//
// Latency injection: `liveSocket.enableLatencySim(ms)` — the LiveView built-in the
// harness already uses (zz-instant-nav "skeleton visual", zz-instant-nav-cache). It
// delays the channel in BOTH directions, which is what widens these races: a patch's
// history.pushState only runs in the server-reply callback (live_socket.js
// pushHistoryPatch → historyPatch), so a whole RTT passes with no history entry for
// the chat the user is already looking at. NAV_LATENCY=0 disables it.
// (CDP Network.emulateNetworkConditions was rejected: it does not throttle an already
// open WebSocket's frames, so it cannot widen the LiveView round-trip.)
//
// Env knobs:
//   NAV_ITER=20         iterations per test
//   NAV_DELAYS=0,30,... the mid-flight delay sweep (ms), cycled per iteration
//   NAV_LATENCY=200     simulated RTT (ms), 0 to disable
//   NAV_NOISE=1         bob sends messages into the loop (live sidebar re-render /
//                       stream reorder under the finger) — the (A) amplifier
const { test, expect, send } = require("../helpers/fixtures")

const ITER = Number(process.env.NAV_ITER || 20)
const DELAYS = (process.env.NAV_DELAYS || "0,30,60,120,250").split(",").map(Number)
const LATENCY = Number(process.env.NAV_LATENCY === undefined ? 200 : process.env.NAV_LATENCY)
const NOISE = process.env.NAV_NOISE !== "0"
const SETTLE = 1200 + 4 * LATENCY

// ---------------------------------------------------------------- instrumentation

async function instrument(page) {
  // addInitScript, not evaluate: a stalled socket makes LiveView fall back to a FULL
  // page load, and the log has to survive that (it restarts, which the log records).
  await page.addInitScript(() => {
    const now = () => Math.round(performance.now())
    window.__navLog = []
    window.__menuLog = []
    window.__touchLog = []
    const rec = (type, extra) =>
      window.__navLog.push(
        Object.assign({ t: now(), type, path: location.pathname, len: history.length }, extra || {}),
      )
    window.__mark = (note) => rec("mark", { note })
    const ps = history.pushState.bind(history)
    history.pushState = function (s, ti, u) {
      const r = ps(s, ti, u)
      rec("pushState", { to: String(u) })
      return r
    }
    const rs = history.replaceState.bind(history)
    history.replaceState = function (s, ti, u) {
      const r = rs(s, ti, u)
      rec("replaceState", { to: String(u) })
      return r
    }
    addEventListener("popstate", () => rec("popstate"))
    // Capture phase on document, installed BEFORE any hook mounts, so it sees every
    // click even when .InstantNav / .ContextMenu stop propagation or preventDefault.
    document.addEventListener(
      "click",
      (e) => {
        const a = e.target.closest && e.target.closest("a")
        if (!a) return
        const wrap = a.closest(".ed-convo-wrap")
        rec("click", {
          kind: a.hasAttribute("data-nav-back")
            ? "back"
            : wrap
              ? "convo"
              : a.classList.contains("ed-rail__btn")
                ? "rail"
                : "other",
          to: wrap ? wrap.dataset.id : a.getAttribute("href"),
        })
      },
      true,
    )
    for (const type of ["touchstart", "touchend", "touchcancel"]) {
      document.addEventListener(
        type,
        (e) => {
          const el = e.target
          const wrap = el && el.closest && el.closest(".ed-convo-wrap")
          window.__touchLog.push({
            t: now(),
            type,
            row: wrap ? wrap.dataset.id : null,
            tag: el && el.tagName,
            connected: !!(el && el.isConnected),
          })
        },
        true,
      )
    }
    const start = () => {
      new MutationObserver((muts) => {
        for (const m of muts) {
          const el = m.target
          if (el.nodeType === 1 && el.hasAttribute("data-menu") && !el.hidden) {
            window.__menuLog.push({ t: now(), id: el.id, path: location.pathname })
            rec("MENU-OPEN", { to: el.id })
          }
        }
      }).observe(document.documentElement, {
        subtree: true,
        attributes: true,
        attributeFilter: ["hidden"],
      })
    }
    if (document.readyState === "loading") addEventListener("DOMContentLoaded", start)
    else start()
  })
}

async function connected(page) {
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  )
}

const mark = (page, note) => page.evaluate((n) => window.__mark && window.__mark(n), note)

async function state(page) {
  return page.evaluate(() => {
    const m =
      location.pathname.match(/^\/app\/c\/([^\/]+)$/) ||
      location.pathname.match(/^\/channels\/[^\/]+\/r\/([^\/]+)$/)
    const scroll = document.getElementById("message-scroll")
    const main = document.getElementById("chat-dropzone")
    const convoClicks = window.__navLog.filter((e) => e.type === "click" && e.kind === "convo")
    return {
      path: location.pathname,
      url: m ? m[1] : null,
      dom: scroll ? scroll.dataset.conversationId : null,
      overlay: document.querySelectorAll(".ed-nav-skel").length,
      mainHidden: main ? main.classList.contains("hidden") : null,
      len: history.length,
      lastConvoClick: convoClicks.length ? convoClicks[convoClicks.length - 1].to : null,
      convoClicks: convoClicks.length,
      menus: window.__menuLog.length,
    }
  })
}

async function dump(page, testInfo, name) {
  const logs = await page
    .evaluate(() => ({
      nav: window.__navLog || [],
      menu: window.__menuLog || [],
      touch: window.__touchLog || [],
    }))
    .catch(() => ({ nav: [], menu: [], touch: [] }))
  const lines = logs.nav.map(
    (e) =>
      `${String(e.t).padStart(7)}ms  ${e.type.padEnd(12)} len=${String(e.len).padEnd(3)} ${e.path}` +
      (e.to ? `  -> ${e.to}` : "") +
      (e.kind ? ` [${e.kind}]` : "") +
      (e.note ? `  # ${e.note}` : ""),
  )
  const touch = logs.touch.map(
    (e) => `${String(e.t).padStart(7)}ms  ${e.type.padEnd(11)} row=${e.row} <${e.tag}> connected=${e.connected}`,
  )
  const body =
    `=== __navLog (${logs.nav.length}) ===\n${lines.join("\n")}\n\n` +
    `=== __menuLog (${logs.menu.length}) ===\n${JSON.stringify(logs.menu, null, 1)}\n\n` +
    `=== __touchLog (${logs.touch.length}) ===\n${touch.join("\n")}\n`
  await testInfo.attach(name, { body, contentType: "text/plain" })
  return { body, ...logs }
}

// ------------------------------------------------------------------ touch driver
// Chromium (mobile-chrome / Pixel 7): CDP Input.dispatchTouchEvent — REAL touches, so
// the browser owns hit-testing and retargeting (a row morphed out from under the
// finger behaves exactly as it does on a phone). WebKit (mobile-safari) has no CDP:
// fall back to the synthetic TouchEvent dispatch the rest of the suite uses
// (zz-swipe-back-layout, zz-instant-nav) — note that a synthetic touchend is
// re-targeted by SELECTOR, which is more forgiving than a finger.
function touchDriver(page) {
  let s = null
  const pt = (x, y) => ({ identifier: 1, clientX: x, clientY: y, pageX: x, pageY: y })
  const synth = (sel, type, x, y) => {
    const empty = type === "touchend" || type === "touchcancel"
    return page
      .dispatchEvent(sel, type, {
        touches: empty ? [] : [pt(x, y)],
        changedTouches: [pt(x, y)],
        targetTouches: empty ? [] : [pt(x, y)],
        bubbles: true,
        cancelable: true,
      })
      .catch(() => {})
  }
  return {
    async init() {
      s = await page.context().newCDPSession(page).catch(() => null)
      return !!s
    },
    get real() {
      return !!s
    },
    down(x, y, sel = "body") {
      return s
        ? s.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] })
        : synth(sel, "touchstart", x, y)
    },
    move(x, y, sel = "body") {
      return s
        ? s.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y }] })
        : synth(sel, "touchmove", x, y)
    },
    up(x, y, sel = "body") {
      return s
        ? s.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
        : synth(sel, "touchend", x, y)
    },
    async tap(x, y, sel = "body") {
      await this.down(x, y, sel)
      await this.up(x, y, sel)
    },
  }
}

// The edge-swipe recognizer (.InstantNav onTouchStart/Move/End): one touch starting at
// clientX <= 24, armed at dx >= 8, committed on release past 35% of the width OR at
// > 0.35 px/ms. `sel` is where a SYNTHETIC start is dispatched — "body" for a plain
// edge swipe, a row selector for the "swipe starts on a chat row" case (which arms the
// row's long-press timer at the same time).
async function edgeSwipe(drv, page, { sel = "body", y = 420, step = 16 } = {}) {
  const w = page.viewportSize().width
  await drv.down(8, y, sel)
  for (const x of [26, 70, 140, Math.round(w * 0.55), Math.round(w * 0.8)]) {
    await page.waitForTimeout(step)
    await drv.move(x, y + 1, sel)
  }
  await drv.up(Math.round(w * 0.8), y + 1, sel)
}

async function goBack(page, drv, mode) {
  if (mode === "swipe") return edgeSwipe(drv, page)
  if (mode === "history") return page.evaluate(() => history.back())
  const back = page.locator("a[data-nav-back]")
  const box = await back.boundingBox().catch(() => null)
  if (!box) return page.evaluate(() => history.back()) // no chat header (already on the list)
  return drv.tap(Math.round(box.x + box.width / 2), Math.round(box.y + box.height / 2), "a[data-nav-back]")
}

// Tap a sidebar row near its TOP-LEFT: during the back slide the pane (fixed, full
// width, translateX 0→100%) uncovers the left edge first, which is precisely where a
// fast user's next tap lands. Returns false when the row isn't hit-testable (the pane
// ate the tap) — counted, never asserted on.
async function tapRow(page, drv, id) {
  const box = await page
    .locator(`.ed-convo-wrap[data-id="${id}"] a.ed-convo`)
    .boundingBox()
    .catch(() => null)
  if (!box) return null
  const x = Math.round(box.x + 14)
  const y = Math.round(box.y + 10)
  await drv.tap(x, y, `.ed-convo-wrap[data-id="${id}"] a.ed-convo`)
  return { x, y, box }
}

async function sidebarIds(page, n) {
  return page.evaluate(
    (n) =>
      [...document.querySelectorAll("#conversations .ed-convo-wrap[data-id]")]
        .slice(0, n)
        .map((w) => w.dataset.id),
    n,
  )
}

// --------------------------------------------------------------------- the tests

test.describe("mobile nav races (stress)", () => {
  test.beforeEach(({}, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only gestures")
  })

  test("(B) rapid back+switch always lands on the LAST chat actually tapped", async ({
    alice,
    seed,
  }, testInfo) => {
    test.setTimeout(60_000 + ITER * (SETTLE + 4_000))
    const page = alice
    const drv = touchDriver(page)
    await instrument(page)
    await page.goto("/app")
    await connected(page)
    const real = await drv.init()
    const ids = await sidebarIds(page, 5)
    expect(ids.length, "seed must give at least 3 sidebar chats").toBeGreaterThanOrEqual(3)
    if (LATENCY) await page.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

    // Prime: open the first chat so every iteration starts from "inside a chat".
    await tapRow(page, drv, ids[0])
    await page.waitForTimeout(SETTLE)

    const rows = []
    for (let i = 0; i < ITER; i++) {
      const delay = DELAYS[i % DELAYS.length]
      const mode = ["button", "swipe", "history"][i % 3]
      const target = ids[(i + 1) % ids.length]
      await mark(page, `iter ${i} delay=${delay} back=${mode} target=${target}`)
      const before = await state(page)

      await goBack(page, drv, mode)
      await page.waitForTimeout(delay) // deliberately mid-flight
      const hit = await tapRow(page, drv, target)
      await page.waitForTimeout(SETTLE)

      const after = await state(page)
      const clicked = after.convoClicks > before.convoClicks
      const row = {
        i,
        delay,
        mode,
        target,
        tapped: !!hit,
        clicked,
        lastClick: after.lastConvoClick,
        url: after.url,
        dom: after.dom,
        path: after.path,
        len: after.len,
        overlay: after.overlay,
      }
      // Only assert when the DOM really saw a row click this iteration: a tap the
      // sliding pane swallowed is not the bug (and is reported separately).
      row.bad = clicked && (after.url !== after.lastConvoClick || after.dom !== after.lastConvoClick)
      rows.push(row)
      if (row.bad) {
        console.log(`  ✗ iter ${i}: clicked=${after.lastConvoClick} but url=${after.url} dom=${after.dom} path=${after.path}`)
      }
      // Recover into a chat so the next iteration has a back gesture to make.
      if (!after.url) {
        await tapRow(page, drv, target)
        await page.waitForTimeout(SETTLE)
      }
    }

    const bad = rows.filter((r) => r.bad)
    const swallowed = rows.filter((r) => !r.clicked)
    const byDelay = {}
    for (const r of rows) {
      byDelay[r.delay] = byDelay[r.delay] || { n: 0, bad: 0 }
      byDelay[r.delay].n++
      if (r.bad) byDelay[r.delay].bad++
    }
    console.log(
      `\n[B] touch=${real ? "CDP (real)" : "synthetic"} latency=${LATENCY}ms iterations=${ITER}\n` +
        `    wrong-chat: ${bad.length}/${rows.length}   tap-swallowed-by-pane: ${swallowed.length}\n` +
        `    by delay: ${JSON.stringify(byDelay)}\n` +
        rows
          .map(
            (r) =>
              `    #${String(r.i).padStart(2)} d=${String(r.delay).padStart(3)} ${r.mode.padEnd(7)} want=${r.target} click=${r.lastClick} url=${r.url} dom=${r.dom} len=${r.len}${r.bad ? "   <-- WRONG CHAT" : r.clicked ? "" : "   (tap swallowed)"}`,
          )
          .join("\n"),
    )
    await dump(page, testInfo, "navlog-B.txt")
    if (LATENCY) await page.evaluate(() => window.liveSocket.disableLatencySim())

    expect(
      bad,
      `landed on a chat that was not the last one tapped (${bad.length}/${rows.length})`,
    ).toEqual([])
  })

  test("(A) no context menu ever pops during back + rapid switching", async ({
    alice,
    bob,
    seed,
  }, testInfo) => {
    test.setTimeout(90_000 + ITER * (SETTLE + 5_000))
    const page = alice
    const drv = touchDriver(page)
    await instrument(page)
    await page.goto("/app")
    await connected(page)
    const real = await drv.init()
    const ids = await sidebarIds(page, 5)
    if (LATENCY) await page.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

    // Live noise: bob messaging the DM re-renders alice's sidebar (preview, badge) AND
    // re-orders the stream — i.e. morphdom churning rows UNDER a live finger, which is
    // the #439 shape of this bug (the touch's target node stops receiving touchend).
    if (NOISE) {
      await bob.goto(`/app/c/${seed.dm_id}`)
      await connected(bob)
    }
    const noise = async (i) => {
      if (!NOISE) return
      await send(bob, `race-${Date.now()}-${i}`).catch(() => {})
    }

    await tapRow(page, drv, ids[0])
    await page.waitForTimeout(SETTLE)

    const rows = []
    for (let i = 0; i < ITER; i++) {
      const delay = DELAYS[i % DELAYS.length]
      const variant = i % 4
      const target = ids[(i + 1) % ids.length]
      const before = await state(page)
      await mark(page, `iter ${i} delay=${delay} variant=${variant} target=${target}`)

      if (variant === 0) {
        // header back, then a fast tap mid-slide
        await goBack(page, drv, "button")
        await page.waitForTimeout(delay)
        await tapRow(page, drv, target)
      } else if (variant === 1) {
        // plain edge swipe from the pane, then a fast tap
        await goBack(page, drv, "swipe")
        await page.waitForTimeout(delay)
        await tapRow(page, drv, target)
      } else if (variant === 2) {
        // the swipe STARTS ON A CHAT ROW: on the list the row's long-press timer arms
        // from the same touchstart that (with a nav in flight) drags the overlay.
        await goBack(page, drv, "button")
        await page.waitForTimeout(delay)
        const box = await page
          .locator(`.ed-convo-wrap[data-id="${target}"] a.ed-convo`)
          .boundingBox()
          .catch(() => null)
        if (box) {
          const y = Math.round(box.y + box.height / 2)
          await noise(i) // sidebar re-orders while the finger is down
          await edgeSwipe(drv, page, {
            sel: `.ed-convo-wrap[data-id="${target}"] a.ed-convo`,
            y,
            step: 14,
          })
        }
        await tapRow(page, drv, target)
      } else {
        // a navigation settles while a finger is DOWN on a row — held 220ms, well
        // under the 450ms long-press, so a menu here is never the feature.
        await goBack(page, drv, "history")
        await page.waitForTimeout(delay)
        const box = await page
          .locator(`.ed-convo-wrap[data-id="${target}"] a.ed-convo`)
          .boundingBox()
          .catch(() => null)
        if (box) {
          const x = Math.round(box.x + 40)
          const y = Math.round(box.y + box.height / 2)
          const sel = `.ed-convo-wrap[data-id="${target}"] a.ed-convo`
          await drv.down(x, y, sel)
          await noise(i) // the row is re-streamed under the finger
          await page.waitForTimeout(220)
          await drv.up(x, y, sel)
        }
        await tapRow(page, drv, target)
      }

      await page.waitForTimeout(SETTLE)
      const after = await state(page)
      const opened = after.menus - before.menus
      rows.push({ i, delay, variant, opened, path: after.path })
      if (opened) console.log(`  ✗ iter ${i} (variant ${variant}, delay ${delay}): ${opened} menu(s) opened`)
      // No menu may survive into the next iteration either.
      const visible = await page.locator("[data-menu]:not([hidden])").count()
      if (visible) {
        rows[rows.length - 1].stuck = visible
        await page.keyboard.press("Escape").catch(() => {})
      }
      if (!after.url) {
        await tapRow(page, drv, target)
        await page.waitForTimeout(SETTLE)
      }
    }

    const bad = rows.filter((r) => r.opened > 0 || r.stuck)
    const touchLog = await page.evaluate(() => window.__touchLog || [])
    const starts = touchLog.filter((e) => e.type === "touchstart" && e.row).length
    const ends = touchLog.filter((e) => e.type !== "touchstart" && e.row).length
    console.log(
      `\n[A] touch=${real ? "CDP (real)" : "synthetic"} latency=${LATENCY}ms noise=${NOISE} iterations=${ITER}\n` +
        `    ghost menus: ${bad.length}/${rows.length}\n` +
        `    row touchstart=${starts} row touchend/cancel=${ends} (a gap = a gesture whose row was morphed away)\n` +
        rows
          .map((r) => `    #${String(r.i).padStart(2)} d=${String(r.delay).padStart(3)} v${r.variant} menus=${r.opened}${r.stuck ? ` stuck=${r.stuck}` : ""}`)
          .join("\n"),
    )
    await dump(page, testInfo, "navlog-A.txt")
    if (LATENCY) await page.evaluate(() => window.liveSocket.disableLatencySim())

    expect(bad, `a context menu opened without a long-press (${bad.length}/${rows.length})`).toEqual(
      [],
    )
  })
})
