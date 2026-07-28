// Mobile navigation races — the STRESS harness for two intermittent field bugs the
// user has never been able to catch by hand (the deterministic single-shot repros from
// #439/#432/#462 live in zz-nav-races.spec.js; this file hunts what's left):
//
//   (B) "wrong chat"  — rapid switching lands on a DIFFERENT chat: one never tapped,
//                       or one tapped earlier.
//   (A) "ghost menu"  — edge-swipe back / header back + rapid switching pops a sidebar
//                       row's CONTEXT MENU as if it had been long-pressed.
//
// Both are timing bugs, so this is a LOOP, not a scenario: N iterations over 4 gesture
// PLANS, sweeping a delay (0/30/60/120/250ms — deliberately landing mid-flight) under a
// simulated RTT.
//
// ORACLE (B) — not "the URL I expected" but the last navigation INTENT the DOM actually
// recorded, replayed from the log:
//   • a row tap that produced a real a.ed-convo click  → that chat must be open;
//   • a back gesture performed FROM a chat             → the list must be open.
// A tap the sliding pane swallowed produces no click, so it can never be a false
// positive (those are counted separately). This is exactly the user's complaint.
//
// ORACLE (A) — a MutationObserver on every [data-menu]'s `hidden` attribute: a menu that
// opens and is closed again by the next tap is invisible to polling. Every synthesised
// touch here is < 250ms and/or moves > 10px, i.e. NEVER a legitimate long-press (450ms),
// so any recorded menu is a bug and not the feature.
//
// Instrumentation (written to artifacts/<project>/navlog-*.txt and attached — the log is
// as valuable as the assertion):
//   window.__navLog    every pushState / replaceState / popstate / <a> click / mark, with
//                      location.pathname + history.length + a ms timestamp.
//   window.__menuLog   every context-menu open (host id + path + t).
//   window.__touchLog  every touchstart/end/cancel that reached `document`. A touchstart
//                      with no matching end is the smoking gun for a row morphed out from
//                      under a live gesture (the #439 shape of the ghost menu).
//
// LATENCY: `liveSocket.enableLatencySim(ms)` — the LiveView built-in the harness already
// uses (zz-instant-nav, zz-instant-nav-cache). It delays the channel in both directions,
// which is what widens these races: a patch's history.pushState only runs in the server
// reply callback (live_socket.js pushHistoryPatch → historyPatch), so a whole RTT passes
// with NO history entry for the screen the user is already looking at. NAV_LATENCY=0 off.
// (CDP Network.emulateNetworkConditions was rejected: it does not throttle frames on an
// already-open WebSocket, so it cannot widen the LiveView round-trip.)
//
// TOUCH: Chromium (mobile-chrome / Pixel 7) drives CDP Input.dispatchTouchEvent — real
// touches, so the browser owns hit-testing and retargeting (a row morphed out from under
// the finger behaves exactly as on a phone). WebKit (mobile-safari) has no CDP: it falls
// back to the synthetic TouchEvent dispatch the rest of the suite uses — note a synthetic
// touchend re-targets by SELECTOR, which is more forgiving than a finger.
//
// Env knobs:
//   NAV_ITER=24          iterations for (B); (A) costs ~3x per iteration and caps at 10
//   NAV_DELAYS=0,30,...  mid-flight delay sweep (ms), cycled per iteration
//   NAV_LATENCY=200      simulated RTT (ms), 0 to disable
//   NAV_NOISE=1          bob messages into the loop (live sidebar re-render + stream
//                        reorder under the finger) — the (A) amplifier
const fs = require("fs")
const path = require("path")
const { test, expect, send, artifactsRoot } = require("../helpers/fixtures")

const ITER = Number(process.env.NAV_ITER || 24)
const DELAYS = (process.env.NAV_DELAYS || "0,30,60,120,250").split(",").map(Number)
const LATENCY = Number(process.env.NAV_LATENCY === undefined ? 200 : process.env.NAV_LATENCY)
const NOISE = process.env.NAV_NOISE !== "0"
const SETTLE = 1200 + 4 * LATENCY

// Gesture plans, cycled per iteration. Each step is executed in order; `wait` is the
// swept mid-flight delay.
const PLANS = [
  { name: "backBtn→tap", steps: ["back:button", "wait", "tap"] },
  { name: "backSwipe→tap", steps: ["back:swipe", "wait", "tap"] },
  { name: "sysBack→tap", steps: ["back:history", "wait", "tap"] },
  // The mid-LOAD swipe: tap a chat, then edge-swipe while it is still loading. That path
  // drags the instant-nav overlay and commits with a raw history.back() (chat_live.ex
  // onTouchEnd, the `s.ov` branch) — the prime suspect for landing on an earlier chat.
  { name: "tap→midloadSwipe", steps: ["back:button", "tap", "wait", "back:swipe"] },
]

// ---------------------------------------------------------------- instrumentation

async function instrument(page) {
  // addInitScript, not evaluate: a stalled socket makes LiveView fall back to a FULL page
  // load, and the log has to survive that (it restarts, which the log itself records).
  await page.addInitScript(() => {
    const now = () => Math.round(performance.now())
    window.__navLog = []
    window.__menuLog = []
    window.__touchLog = []
    const rec = (type, extra) =>
      window.__navLog.push(
        Object.assign({ t: now(), type, path: location.pathname, len: history.length }, extra || {}),
      )
    window.__rec = rec
    window.__mark = (note) => rec("mark", { note })
    rec("document-load")
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
    // WHO asked to traverse? The app calls history.back() from exactly two places
    // (chat_live.ex .InstantNav onTouchEnd, and native.js for the Android hardware
    // back) — the stack frame tells them apart from a test-driven one.
    const hb = history.back.bind(history)
    history.back = function () {
      rec("history.back()", {
        note: (new Error().stack || "").split("\n").slice(1, 4).join(" | ").replace(/https?:\/\/[^\s)]*\//g, ""),
      })
      return hb()
    }
    const hg = history.go.bind(history)
    history.go = function (d) {
      rec("history.go()", { to: String(d) })
      return hg(d)
    }
    // Capture phase on document, installed BEFORE any hook mounts, so it sees every click
    // even when .InstantNav / .ContextMenu preventDefault or stopPropagation it.
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
    for (const type of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
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

const convId = (p) => {
  const m = p.match(/^\/app\/c\/([^\/]+)$/) || p.match(/^\/channels\/[^\/]+\/r\/([^\/]+)$/)
  return m ? m[1] : null
}

async function state(page) {
  return page.evaluate(() => {
    const scroll = document.getElementById("message-scroll")
    const main = document.getElementById("chat-dropzone")
    return {
      path: location.pathname,
      dom: scroll ? scroll.dataset.conversationId : null,
      overlay: document.querySelectorAll(".ed-nav-skel").length,
      mainHidden: main ? main.classList.contains("hidden") : null,
      len: history.length,
      events: window.__navLog.length,
      menus: window.__menuLog.length,
    }
  })
}

function render(logs) {
  const nav = logs.nav.map(
    (e) =>
      `${String(e.t).padStart(7)}ms  ${e.type.padEnd(13)} len=${String(e.len).padEnd(3)} ${e.path}` +
      (e.kind ? ` [${e.kind}]` : "") +
      (e.to ? ` -> ${e.to}` : "") +
      (e.note ? `  # ${e.note}` : ""),
  )
  const touch = logs.touch.map(
    (e) =>
      `${String(e.t).padStart(7)}ms  ${e.type.padEnd(11)} row=${e.row} <${e.tag}> connected=${e.connected}`,
  )
  return (
    `=== __navLog (${logs.nav.length}) ===\n${nav.join("\n")}\n\n` +
    `=== __menuLog (${logs.menu.length}) ===\n${JSON.stringify(logs.menu, null, 1)}\n\n` +
    `=== __touchLog (${logs.touch.length}) ===\n${touch.join("\n")}\n`
  )
}

async function dump(page, testInfo, name, extra = "") {
  const logs = await page
    .evaluate(() => ({
      nav: window.__navLog || [],
      menu: window.__menuLog || [],
      touch: window.__touchLog || [],
    }))
    .catch(() => ({ nav: [], menu: [], touch: [] }))
  const body = extra + render(logs)
  const dir = path.join(artifactsRoot, testInfo.project.name)
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, name)
  fs.writeFileSync(file, body)
  await testInfo.attach(name, { body, contentType: "text/plain" })
  return { file, logs, body }
}

// ------------------------------------------------------------------ touch driver

function touchDriver(page) {
  let s = null
  // Swallowed synthetic dispatches, COUNTED rather than ignored (#485 review). On the
  // WebKit path a dispatch is addressed BY SELECTOR, so when the row is morphed out of the
  // DOM mid-gesture — the exact scenario under test — the selector stops resolving and the
  // synthetic touchend simply never fires. That manufactures the very "row touchstart with
  // no matching touchend" gap the (A) summary reports as the ghost-menu smoking gun. A
  // silent catch would make a harness artifact indistinguishable from an app defect, so the
  // summaries print this count and flag the gap as untrustworthy when it is non-zero.
  // (A real finger keeps delivering to a detached target; only the selector path loses it.)
  let missed = 0
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
      .catch(() => {
        missed++
      })
  }
  return {
    async init() {
      s = await page.context().newCDPSession(page).catch(() => null)
      return !!s
    },
    get real() {
      return !!s
    },
    get missed() {
      return missed
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
    // A tap is always a REAL touch (page.touchscreen works on Chromium AND WebKit) —
    // a synthetic TouchEvent pair is not turned into a click by the browser, so a
    // dispatched "tap" would never navigate.
    async tap(x, y, _sel) {
      await page.touchscreen.tap(x, y)
    },
  }
}

// The edge-swipe recognizer (.InstantNav onTouchStart/Move/End): ONE touch starting at
// clientX <= 24, armed at dx >= 8, committed on release past 35% of the width OR faster
// than 0.35 px/ms. `sel` is where a SYNTHETIC start is dispatched — "body" for a plain
// edge swipe, a row selector for "the swipe starts on a chat row" (which arms that row's
// long-press timer from the same touchstart).
async function edgeSwipe(drv, page, { sel = "body", y = 420, step = 16 } = {}) {
  const w = page.viewportSize().width
  await drv.down(8, y, sel)
  for (const x of [26, 70, 140, Math.round(w * 0.55), Math.round(w * 0.8)]) {
    await page.waitForTimeout(step)
    await drv.move(x, y + 1, sel)
  }
  await drv.up(Math.round(w * 0.8), y + 1, sel)
}

// A back gesture is only issued when there is something to go back FROM (a chat, or a
// chat still loading behind the instant-nav overlay). Returns the pre-gesture path so
// the oracle can tell "this back should have landed on the list" from "no-op".
async function backStep(page, drv, mode) {
  const pre = await page.evaluate((m) => {
    window.__mark(`back:${m}`)
    return {
      path: location.pathname,
      overlay: document.querySelectorAll(".ed-nav-skel").length,
      hasBack: !!document.querySelector("a[data-nav-back]"),
    }
  }, mode)
  const inChat = !!convId(pre.path) || pre.overlay > 0
  if (!inChat) return { did: false, from: pre.path }
  if (mode === "swipe") {
    await edgeSwipe(drv, page)
  } else if (mode === "history") {
    await page.evaluate(() => history.back())
  } else {
    const box = await page.locator("a[data-nav-back]").boundingBox().catch(() => null)
    if (!box) return { did: false, from: pre.path }
    await drv.tap(
      Math.round(box.x + box.width / 2),
      Math.round(box.y + box.height / 2),
      "a[data-nav-back]",
    )
  }
  return { did: true, from: pre.path }
}

// Tap a sidebar row near its TOP-LEFT: during the back slide the pane (fixed, full width,
// translateX 0→100%) uncovers the left edge first, which is exactly where a fast user's
// next tap lands. Returns null when the row has no box (we're inside a chat — the mobile
// sidebar is hidden); a tap the pane swallows simply records no click.
async function tapRow(page, drv, id) {
  const box = await page
    .locator(`.ed-convo-wrap[data-id="${id}"] a.ed-convo`)
    .boundingBox()
    .catch(() => null)
  if (!box) return null
  const x = Math.round(box.x + 14)
  const y = Math.round(box.y + 10)
  await drv.tap(x, y, `.ed-convo-wrap[data-id="${id}"] a.ed-convo`)
  return { x, y }
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

// Replay an iteration's log slice into the navigation INTENT it expressed:
//   a real convo click → that chat id;  a back FROM a chat → null (the list).
function expectedFrom(events) {
  let expected
  for (const e of events) {
    if (e.type === "click" && e.kind === "convo") expected = e.to
    else if (e.type === "mark" && e.note.startsWith("back:") && convId(e.path)) expected = null
  }
  return expected
}

// --------------------------------------------------------------------- the tests

test.describe("mobile nav races (stress)", () => {
  test.beforeEach(({}, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only gestures")
  })

  test("(B) rapid back+switch always lands on the LAST screen actually asked for", async ({
    alice,
    seed,
  }, testInfo) => {
    test.setTimeout(120_000 + ITER * (SETTLE + 10_000))
    const page = alice
    const drv = touchDriver(page)
    await instrument(page)
    await page.goto("/app")
    await connected(page)
    const real = await drv.init()
    const ids = await sidebarIds(page, 5)
    expect(ids.length, "seed must give at least 3 sidebar chats").toBeGreaterThanOrEqual(3)
    if (LATENCY) await page.evaluate((ms) => window.liveSocket?.enableLatencySim?.(ms), LATENCY)

    // Prime: open a chat so the first iteration has a back gesture to make.
    await tapRow(page, drv, ids[0])
    await page.waitForTimeout(SETTLE)

    const rows = []
    for (let i = 0; i < ITER; i++) {
      const delay = DELAYS[i % DELAYS.length]
      const plan = PLANS[i % PLANS.length]
      const target = ids[(i + 1) % ids.length]
      const before = await state(page)
      await page.evaluate(
        (n) => window.__mark(n),
        `── iter ${i}  plan=${plan.name}  delay=${delay}ms  target=${target}`,
      )

      for (const step of plan.steps) {
        if (step === "wait") await page.waitForTimeout(delay)
        else if (step === "tap") await tapRow(page, drv, target)
        else await backStep(page, drv, step.split(":")[1])
      }
      await page.waitForTimeout(SETTLE)

      const after = await state(page)
      const events = await page.evaluate((n) => window.__navLog.slice(n), before.events)
      const expected = expectedFrom(events)
      const got = convId(after.path)
      const row = {
        i,
        delay,
        plan: plan.name,
        target,
        expected: expected === undefined ? "(nothing happened)" : expected === null ? "list" : expected,
        got: got || "list",
        dom: after.dom,
        len: after.len,
      }
      row.bad =
        expected !== undefined &&
        (got !== expected || (expected !== null && after.dom !== expected))
      rows.push(row)
      if (row.bad) {
        console.log(
          `  ✗ iter ${i} [${plan.name} d=${delay}] asked for ${row.expected}, got ${row.got} (#message-scroll=${after.dom})`,
        )
      }
      // Recover into a chat so the next iteration has something to back out of.
      if (!convId(after.path)) {
        await tapRow(page, drv, target)
        await page.waitForTimeout(SETTLE)
      }
    }

    const bad = rows.filter((r) => r.bad)
    const stats = {}
    for (const r of rows) {
      const k = `${r.plan}@${r.delay}ms`
      stats[k] = stats[k] || { n: 0, bad: 0 }
      stats[k].n++
      if (r.bad) stats[k].bad++
    }
    const summary =
      `[B] touch=${real ? "CDP (real)" : "synthetic"} latency=${LATENCY}ms iterations=${ITER}` +
      (drv.missed ? `  (${drv.missed} synthetic dispatches dropped — selector no longer resolved)` : "") +
      `\n` +
      `    WRONG SCREEN: ${bad.length}/${rows.length}\n` +
      Object.entries(stats)
        .map(([k, v]) => `    ${k.padEnd(28)} ${v.bad}/${v.n}`)
        .join("\n") +
      "\n" +
      rows
        .map(
          (r) =>
            `    #${String(r.i).padStart(2)} d=${String(r.delay).padStart(3)} ${r.plan.padEnd(17)} want=${String(r.expected).padEnd(6)} got=${String(r.got).padEnd(6)} dom=${String(r.dom).padEnd(6)} len=${r.len}${r.bad ? "   <-- WRONG" : ""}`,
        )
        .join("\n")
    console.log("\n" + summary + "\n")
    const { file } = await dump(page, testInfo, "navlog-B.txt", summary + "\n\n")
    console.log("    navLog: " + file + "\n")
    if (LATENCY) await page.evaluate(() => window.liveSocket?.disableLatencySim?.())

    expect(
      bad,
      `landed on a screen that was not the last one asked for (${bad.length}/${rows.length}) — see ${file}`,
    ).toEqual([])
  })

  test("(A) no context menu ever pops during back + rapid switching", async ({
    alice,
    bob,
    seed,
  }, testInfo) => {
    // (A) is ~3x the cost of (B) per iteration — four gesture variants plus live noise,
    // each waiting out a simulated RTT — so it gets its OWN, smaller budget instead of
    // (B)'s. At NAV_ITER=24 the file blew a 756s timeout while the oracle ("did ANY menu
    // open") had long since been exercised; that count buys nothing here.
    const A_ITER = Math.min(ITER, 10)
    test.setTimeout(180_000 + A_ITER * 3 * (SETTLE + 9_000))
    const page = alice
    const drv = touchDriver(page)
    await instrument(page)
    await page.goto("/app")
    await connected(page)
    const real = await drv.init()
    const ids = await sidebarIds(page, 5)
    if (LATENCY) await page.evaluate((ms) => window.liveSocket?.enableLatencySim?.(ms), LATENCY)

    // Live noise: bob messaging the DM re-renders alice's sidebar (preview + badge) AND
    // re-orders the stream — morphdom churning rows UNDER a live finger, which is the
    // #439 shape of this bug (the touch's target node stops receiving touchend).
    if (NOISE) {
      await bob.goto(`/app/c/${seed.dm_id}`)
      await connected(bob)
    }
    const noise = (i) => (NOISE ? send(bob, `race-${Date.now()}-${i}`).catch(() => {}) : null)

    await tapRow(page, drv, ids[0])
    await page.waitForTimeout(SETTLE)

    const rows = []
    for (let i = 0; i < A_ITER; i++) {
      const delay = DELAYS[i % DELAYS.length]
      const variant = i % 4
      const target = ids[(i + 1) % ids.length]
      const before = await state(page)
      await page.evaluate(
        (n) => window.__mark(n),
        `── iter ${i}  variant=${variant}  delay=${delay}ms  target=${target}`,
      )

      if (variant === 0) {
        // header back, then a fast tap mid-slide
        await backStep(page, drv, "button")
        await page.waitForTimeout(delay)
        await tapRow(page, drv, target)
      } else if (variant === 1) {
        // plain edge swipe out of the chat, then a fast tap mid-slide
        await backStep(page, drv, "swipe")
        await page.waitForTimeout(delay)
        await tapRow(page, drv, target)
      } else if (variant === 2) {
        // The swipe STARTS ON A CHAT ROW: the same touchstart arms that row's 450ms
        // long-press timer AND (with a nav in flight) drags the instant-nav overlay.
        await backStep(page, drv, "button")
        await page.waitForTimeout(delay)
        await tapRow(page, drv, target) // start the load…
        await page.waitForTimeout(delay)
        const box = await page
          .locator(`.ed-convo-wrap[data-id="${ids[0]}"] a.ed-convo`)
          .boundingBox()
          .catch(() => null)
        if (box) {
          await noise(i) // …and re-order the sidebar under the finger
          await edgeSwipe(drv, page, {
            sel: `.ed-convo-wrap[data-id="${ids[0]}"] a.ed-convo`,
            y: Math.round(box.y + box.height / 2),
            step: 14,
          })
        }
      } else {
        // A navigation settles while a finger is DOWN on a row — held 220ms, well under
        // the 450ms long-press, so a menu here is never the feature. The finger JITTERS
        // by a few px (a real one always does) but stays under the 10px cancel, and it
        // sits on the row's right edge — the time / unread-badge corner, where nodes are
        // ADDED AND REMOVED by a re-render (a discarded touch target gets no touchend).
        await backStep(page, drv, "history")
        await page.waitForTimeout(delay)
        const box = await page
          .locator(`.ed-convo-wrap[data-id="${target}"] a.ed-convo`)
          .boundingBox()
          .catch(() => null)
        if (box) {
          const x = Math.round(box.x + box.width - 26)
          const y = Math.round(box.y + (i % 8 < 4 ? 14 : box.height - 16))
          const sel = `.ed-convo-wrap[data-id="${target}"] a.ed-convo`
          await drv.down(x, y, sel)
          await noise(i) // the row is re-streamed / re-ordered under the finger
          await page.waitForTimeout(110)
          await drv.move(x + 3, y - 2, sel)
          await page.waitForTimeout(110)
          await drv.move(x + 1, y + 3, sel)
          await drv.up(x + 1, y + 3, sel)
        }
        await tapRow(page, drv, target)
      }

      await page.waitForTimeout(SETTLE)
      const after = await state(page)
      const opened = after.menus - before.menus
      const stuck = await page.locator("[data-menu]:not([hidden])").count()
      rows.push({ i, delay, variant, opened, stuck, path: after.path })
      if (opened || stuck) {
        console.log(`  ✗ iter ${i} [v${variant} d=${delay}] menus opened=${opened} stuck=${stuck}`)
        await page.keyboard.press("Escape").catch(() => {})
      }
      if (!convId(after.path)) {
        await tapRow(page, drv, target)
        await page.waitForTimeout(SETTLE)
      }
    }

    // BURST: the loop above settles between iterations, which a panicking user never
    // does. Here the gestures overlap for real — back / tap / back / tap with nothing
    // but the swept delay between them, so patches, slides and touches interleave.
    await page.evaluate(() => window.__mark("── BURST (no settle)"))
    const burstBefore = (await state(page)).menus
    for (let i = 0; i < A_ITER * 2; i++) {
      const delay = DELAYS[i % DELAYS.length]
      const target = ids[(i + 1) % ids.length]
      await backStep(page, drv, i % 2 ? "swipe" : "button")
      await page.waitForTimeout(delay)
      await tapRow(page, drv, target)
      if (NOISE && i % 6 === 0) await noise(1000 + i)
    }
    await page.waitForTimeout(SETTLE)
    const burstMenus = (await state(page)).menus - burstBefore
    if (burstMenus) console.log(`  ✗ BURST: ${burstMenus} menu(s) opened`)
    rows.push({ i: "burst", delay: "-", variant: "-", opened: burstMenus, stuck: 0 })

    const bad = rows.filter((r) => r.opened > 0 || r.stuck > 0)
    const touchLog = await page.evaluate(() => window.__touchLog || [])
    const starts = touchLog.filter((e) => e.type === "touchstart" && e.row).length
    const ends = touchLog.filter(
      (e) => (e.type === "touchend" || e.type === "touchcancel") && e.row,
    ).length
    const summary =
      `[A] touch=${real ? "CDP (real)" : "synthetic"} latency=${LATENCY}ms noise=${NOISE} iterations=${A_ITER}\n` +
      `    GHOST MENUS: ${bad.length}/${rows.length}\n` +
      `    row touchstart=${starts}  row touchend/cancel=${ends}  ` +
      (drv.missed
        ? `(GAP NOT DIAGNOSTIC: ${drv.missed} synthetic dispatches were dropped because their selector stopped resolving — harness, not app)\n`
        : `(a gap = a gesture whose row was morphed away mid-touch)\n`) +
      rows
        .map(
          (r) =>
            `    #${String(r.i).padStart(2)} d=${String(r.delay).padStart(3)} v${r.variant} opened=${r.opened} stuck=${r.stuck}`,
        )
        .join("\n")
    console.log("\n" + summary + "\n")
    const { file } = await dump(page, testInfo, "navlog-A.txt", summary + "\n\n")
    console.log("    navLog: " + file + "\n")
    if (LATENCY) await page.evaluate(() => window.liveSocket?.disableLatencySim?.())

    expect(
      bad,
      `a context menu opened without a long-press (${bad.length}/${rows.length}) — see ${file}`,
    ).toEqual([])
  })

  // (C) is the OTHER half of the ghost menu, and (A) structurally cannot see it: (A) only
  // ever asks "did a menu open by itself", never "did a menu I opened ON PURPOSE outlive the
  // screen it belongs to". Nothing in the ContextMenu hook closes on navigation — close()
  // is reachable only from an outside click, Escape, a scroll, or destroyed() — and on mobile
  // the sidebar is not removed on navigation, it gets class="hidden". A menu inside it is then
  // display:none but still OPEN (`hidden` attribute false, module-scoped `active` still
  // pointing at that hook, this.el.isConnected true), and updated() actively re-asserts
  // hidden=false on every sidebar re-render. Reveal the list again and the menu is simply
  // back — which is exactly the "a modal appears as if I long-pressed a chat" report.
  //
  // Driven through popstate on purpose: a history traversal produces NO click, so onDoc —
  // the one listener that would have closed it — never fires. That is the deterministic
  // shape of the bug; the header-back path reaches the same state but self-heals ~450ms
  // later when backFinish's programmatic re-click finally bubbles.
  test("(C) a context menu never survives a navigation", async ({ alice }, testInfo) => {
    test.setTimeout(120_000)
    const page = alice
    const drv = touchDriver(page)
    await instrument(page)
    await page.goto("/app")
    await connected(page)
    await drv.init()
    const ids = await sidebarIds(page, 2)

    // A forward history entry to traverse into, without clicking anything later.
    await tapRow(page, drv, ids[0])
    await page.waitForTimeout(SETTLE)
    await page.evaluate(() => history.back())
    await page.waitForTimeout(SETTLE)

    // A REAL long-press on a sidebar row: 700ms, no movement, well past the 450ms threshold.
    // This menu is the feature working correctly — the bug is what happens to it next.
    const box = await page.locator(`.ed-convo-wrap[data-id="${ids[0]}"] a.ed-convo`).boundingBox()
    const sel = `.ed-convo-wrap[data-id="${ids[0]}"] a.ed-convo`
    const x = Math.round(box.x + box.width / 2)
    const y = Math.round(box.y + box.height / 2)
    await drv.down(x, y, sel)
    await page.waitForTimeout(700)
    await drv.up(x, y, sel)
    await page.waitForTimeout(200)

    const openedOnPurpose = await page.locator("[data-menu]:not([hidden])").count()
    expect(openedOnPurpose, "a 700ms long-press must open the row menu — otherwise this test proves nothing").toBe(1)

    // Traverse INTO the chat. No click anywhere, so nothing incidental can close the menu.
    await page.evaluate(() => {
      window.__mark("C: history.forward into chat")
      history.forward()
    })
    await page.waitForTimeout(SETTLE)
    const openAfterNav = await page.locator("[data-menu]:not([hidden])").count()

    // …and back to the list, where a menu still holding `hidden=false` becomes VISIBLE again.
    await page.evaluate(() => {
      window.__mark("C: history.back to list")
      history.back()
    })
    await page.waitForTimeout(SETTLE)
    // count(), not isVisible() (#488 review): isVisible() is strict-mode and THROWS on more
    // than one match, which a resurfacing regression would produce — and the catch would then
    // swallow it into a pass, masking the exact bug this assertion exists for.
    const visibleOnReturn = (await page.locator("[data-menu]:not([hidden])").count()) > 0

    // Phase 2 — the header-back path, which reaches the same state by a different route and
    // is the one the user actually performs. maybeStart's back branch stopPropagations the
    // tap in CAPTURE, so onDoc never sees it; the list is revealed at the same moment. If a
    // menu is open in the chat pane, it is on screen over the list until backFinish's
    // programmatic re-click finally bubbles ~450ms later. Sample DURING that window, not
    // after it, or the flash is invisible to the assertion.
    await tapRow(page, drv, ids[0])
    await page.waitForTimeout(SETTLE)
    const msg = page.locator("#messages [data-message-id]").last()
    const flash = { opened: 0, duringBack: 0 }
    if (await msg.count()) {
      const mb = await msg.boundingBox().catch(() => null)
      if (mb) {
        const msel = "#messages [data-message-id]:last-child"
        const mx = Math.round(mb.x + mb.width / 2)
        const my = Math.round(mb.y + mb.height / 2)
        await drv.down(mx, my, msel)
        await page.waitForTimeout(700)
        await drv.up(mx, my, msel)
        await page.waitForTimeout(200)
        flash.opened = await page.locator("[data-menu]:not([hidden])").count()
        await backStep(page, drv, "button")
        // SAMPLE the whole slide instead of betting on one timestamp (#488 review): a single
        // 180ms probe is at the mercy of machine speed and of whether the handler happened to
        // run synchronously. Poll across the window and keep the WORST reading — the menu was
        // over the list if it was open at any point before the re-click lands.
        for (let t = 0; t < 420; t += 30) {
          await page.waitForTimeout(30)
          const n = await page.locator("[data-menu]:not([hidden])").count()
          if (n > flash.duringBack) flash.duringBack = n
        }
        await page.waitForTimeout(SETTLE)
      }
    }

    const summary =
      `[C] sidebar row + popstate\n` +
      `      menu open after long-press: ${openedOnPurpose}\n` +
      `      still open after navigating away: ${openAfterNav}  (must be 0)\n` +
      `      VISIBLE again after returning to the list: ${visibleOnReturn}  (must be false)\n` +
      `    message row + header back\n` +
      (flash.opened
        ? `      menu open after long-press: ${flash.opened}\n` +
          `      worst reading across the back slide: ${flash.duringBack}  (must be 0)\n`
        : `      NOT EXERCISED — the long-press opened no menu on this engine, so the\n` +
          `      assertion below passes vacuously (WebKit dispatches synthetic touches by\n` +
          `      selector and they do not always reach a message row). This phase is only\n` +
          `      meaningful where it reports a menu opened.\n`)
    console.log("\n" + summary)
    const { file } = await dump(page, testInfo, "navlog-C.txt", summary + "\n")

    expect(openAfterNav, `the menu outlived the navigation — see ${file}`).toBe(0)
    expect(visibleOnReturn, `the menu came back with the list — see ${file}`).toBe(false)
    // Assert phase 2 ONLY where it actually ran (#488 review). Where the synthetic long-press
    // opened no menu the assertion would pass without exercising anything, and a vacuous green
    // on the path the user actually performs is worse than an honest gap — annotate instead.
    if (flash.opened) {
      expect(flash.duringBack, `the menu was still open over the list mid-back — see ${file}`).toBe(0)
    } else {
      testInfo.annotations.push({
        type: "not-exercised",
        description: "(C) phase 2: the long-press opened no menu on this engine — header-back path unverified here",
      })
    }
  })
})
