// How long the interface sits still after a tap that opens something (#521 tail, epic #506).
//
// Every one of these panels is `:if={@assign}` on the server: it does not exist in the DOM until
// the diff lands, and several handlers put a query or two ON TOP of the round trip. On this stand a
// round trip is a few milliseconds and everything looks instant, so the socket is slowed
// deliberately — the same instrument the rest of this epic used.
const { test, expect } = require("../helpers/fixtures")

const LATENCY = 500

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

// Time from the click to the first thing a person could see: a new element inside .ed-root, or a
// class/attribute change that is not LiveView's own loading stamp.
const armProbe = (page) =>
  page.evaluate(() => {
    window.__firstPaint = null
    window.__t0 = null
    // document.body, not .ed-root: several of these panels are rendered as siblings of the app
    // shell, so a probe scoped to the shell would report "nothing happened" for a modal that did
    // in fact open.
    const root = document.body
    window.__probe = new MutationObserver((records) => {
      if (window.__t0 === null || window.__firstPaint !== null) return
      for (const r of records) {
        if (r.type === "childList" && r.addedNodes.length) {
          const meaningful = [...r.addedNodes].some(
            (n) => n.nodeType === 1 && !n.classList?.contains("phx-click-loading"),
          )
          if (meaningful) {
            window.__firstPaint = performance.now() - window.__t0
            return
          }
        }
      }
    })
    window.__probe.observe(root, { childList: true, subtree: true })
  })

const readProbe = (page) =>
  page.evaluate(() => {
    window.__probe?.disconnect()
    return window.__firstPaint
  })

const measure = async (page, label, act, testInfo) => {
  await armProbe(page)
  await page.evaluate(() => (window.__t0 = performance.now()))
  await act()
  // Long enough for the WORST case: these handlers put queries on top of the round trip, and the
  // first version of this probe read at LATENCY+300 and reported "never" for a panel that landed
  // at 1187ms.
  await page.waitForTimeout(LATENCY * 3 + 500)
  const at = await readProbe(page)
  const line = `${label}: first paint ${at === null ? "never" : Math.round(at) + "ms"} after the tap (socket at ${LATENCY}ms)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })
  return at
}

test("what the panels cost to open", async ({ alice, seed }, testInfo) => {
  test.setTimeout(180_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(500)
  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  const profile = await measure(
    alice,
    "profile aside (chat header)",
    () => alice.locator("[data-opens=aside]").first().click(),
    testInfo,
  )
  await alice.keyboard.press("Escape")
  await alice.waitForTimeout(LATENCY * 2)

  const newChat = await measure(
    alice,
    "new-chat modal",
    () => alice.locator('[phx-click="toggle_new"]').first().click(),
    testInfo,
  )
  await alice.keyboard.press("Escape")
  await alice.waitForTimeout(LATENCY + 200)

  // The anchored card hangs off a message avatar, and a DM in bubbles has none — rooms do.
  await alice.evaluate(() => window.liveSocket.disableLatencySim())
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)
  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  const popover = await measure(
    alice,
    "profile card (message avatar)",
    () => alice.locator('#messages [data-opens="popover"]').first().click(),
    testInfo,
  )
  await alice.keyboard.press("Escape")

  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(popover, "the profile card never appeared").not.toBeNull()
  expect(popover, `the profile card waited for the server (${popover}ms)`).toBeLessThan(300)
  expect(profile, "the profile panel never appeared").not.toBeNull()
  expect(newChat, "the new-chat modal never appeared").not.toBeNull()
  // A full round trip on this stand is 1000ms (the simulator delays both directions). Anything
  // near that means the tap is still waiting for the server.
  expect(profile, `the profile panel waited for the server (${profile}ms)`).toBeLessThan(300)
  expect(newChat, `the new-chat modal waited for the server (${newChat}ms)`).toBeLessThan(300)
})

// Early is half of it: the placeholder has to hand over and leave, and land where the real card
// lands — a stand-in that appears somewhere else only moves the jump.
test("the placeholder hands the panel over without moving it", async ({ alice, seed }, testInfo) => {
  test.setTimeout(180_000)

  await alice.setViewportSize({ width: 1280, height: 880 })
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await ready(alice)
  await alice.waitForTimeout(500)
  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  // Sampled while it is alive: afterwards there is nothing left to read.
  await alice.evaluate(() => {
    window.__skelBox = null
    const rect = (n) => {
      const r = n.getBoundingClientRect()
      return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width) }
    }
    const tick = () => {
      const card = document.querySelector(".ed-skel-panel__card--popover")
      if (card && card.offsetWidth) {
        window.__skelBox = rect(card)
        return
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.locator('#messages [data-opens="popover"]').first().click()
  await alice.locator(".ed-popover").waitFor({ timeout: 15_000 })
  await alice.waitForTimeout(400)

  const real = await alice.evaluate(() => {
    const n = document.querySelector(".ed-popover")
    const r = n.getBoundingClientRect()
    return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width) }
  })
  const skel = await alice.evaluate(() => window.__skelBox)
  const left = await alice.locator(".ed-skel-panel").count()
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  const line = `profile handoff: placeholder ${JSON.stringify(skel)} → panel ${JSON.stringify(real)}`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(skel, "the placeholder never painted").not.toBeNull()
  expect(left, "the placeholder stayed on screen under the real panel").toBe(0)
  expect(Math.abs(real.x - skel.x), `${line} — the card moved sideways on handoff`).toBeLessThanOrEqual(2)
  expect(Math.abs(real.y - skel.y), `${line} — the card moved vertically on handoff`).toBeLessThanOrEqual(2)
})

// A placeholder is a promise the server has to keep; with the socket down it cannot, so it has to
// say so at once rather than sit there dimming the screen.
test("a panel placeholder gives up at once when the socket is down", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)

  await alice.evaluate(() => {
    window.__seen = null
    window.__gone = null
    const t0 = performance.now()
    const tick = () => {
      const n = document.querySelectorAll(".ed-skel-panel").length
      if (n && window.__seen === null) window.__seen = performance.now() - t0
      if (window.__seen !== null && !n) {
        window.__gone = performance.now() - t0
        return
      }
      if (performance.now() - t0 < 12_000) requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.evaluate(() => window.liveSocket.disconnect())
  await alice.locator('[phx-click="toggle_new"]').first().click()
  await alice.waitForTimeout(2000)

  const { seen, gone } = await alice.evaluate(() => ({ seen: window.__seen, gone: window.__gone }))
  console.log(`offline panel placeholder: painted at ${seen && Math.round(seen)}ms, gone at ${gone && Math.round(gone)}ms`)
  expect(seen, "the placeholder never painted, so its exit proves nothing").not.toBeNull()
  expect(gone, "the placeholder is still dimming the screen with the socket down").not.toBeNull()
  expect(gone, `it sat for ${gone}ms`).toBeLessThan(1500)
})

// The placement asks "does the card fit below the anchor?", and the answer depends on the card's
// HEIGHT. A stand-in three lines tall answers it differently near the bottom of a screen — it sits
// below, the real card flips above, and the jump is back (#573 review). The flip itself cannot be
// staged on this stand (the newest row sits ~70px from the top of even a 460px viewport, so
// everything fits below either way), so what is asserted here is the property the flip decision
// rests on: the two boxes are close enough in height to answer that question the same way.
test("the placeholder is about as tall as the card it stands for", async ({ alice, seed }, testInfo) => {
  test.setTimeout(180_000)

  await alice.setViewportSize({ width: 1280, height: 880 })
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await ready(alice)
  await alice.waitForTimeout(500)
  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  await alice.evaluate(() => {
    window.__skelH = null
    const tick = () => {
      const card = document.querySelector(".ed-skel-panel__card--popover")
      if (card && card.offsetHeight) {
        window.__skelH = card.offsetHeight
        return
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.locator('#messages [data-opens="popover"]').first().click()
  await alice.locator(".ed-popover").waitFor({ timeout: 15_000 })
  await alice.waitForTimeout(400)

  const realH = await alice.evaluate(() => document.querySelector(".ed-popover").offsetHeight)
  const skelH = await alice.evaluate(() => window.__skelH)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  const line = `card heights: placeholder ${skelH}px, panel ${realH}px`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(skelH, "the placeholder never painted").not.toBeNull()
  // Three lines of shimmer come to ~90px; the card is ~250px. Anything in that gap decides the
  // flip differently.
  expect(Math.abs(realH - skelH), `${line} — they would flip at different anchors`).toBeLessThan(120)
})

// A scrim that dims the screen and lets taps through to the app behind is a lie — the same one the
// photo placeholder had (#569), and the modal it stands for traps clicks (#573 review).
test("the panel placeholder catches taps instead of passing them to the app", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)

  const box = await alice.locator("#composer-body").boundingBox()
  expect(box, "no composer to tap through to").not.toBeNull()
  await alice.evaluate(() => document.activeElement?.blur())

  // A full second of round trip, so the tap below is unambiguously the placeholder's.
  await alice.evaluate(() => window.liveSocket.enableLatencySim(500))
  await alice.locator('[phx-click="toggle_new"]').first().click()
  await expect(alice.locator(".ed-skel-panel")).toHaveCount(1)

  await alice.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  const focused = await alice.evaluate(() => document.activeElement?.id || "")
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(focused, "the tap went through the placeholder and landed in the composer").not.toBe(
    "composer-body",
  )
})

// The anchored card does not dim the screen on desktop — its own scrim is a transparent
// click-catcher — so a placeholder that dimmed would flash the whole screen grey for a round trip
// and then undim (#573 review).
test("the anchored card's placeholder does not dim the screen", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.setViewportSize({ width: 1280, height: 880 })
  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await ready(alice)
  await alice.waitForTimeout(400)

  await alice.evaluate(() => {
    window.__scrims = null
    const tick = () => {
      const skel = document.querySelector('.ed-skel-panel[data-kind="popover"] .ed-skel-panel__scrim')
      if (skel) {
        window.__scrims = { placeholder: getComputedStyle(skel).backgroundColor }
        return
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.evaluate(() => window.liveSocket.enableLatencySim(500))
  await alice.locator('#messages [data-opens="popover"]').first().click()
  await alice.locator(".ed-popover").waitFor({ timeout: 15_000 })
  await alice.waitForTimeout(300)

  const real = await alice.evaluate(
    () => getComputedStyle(document.querySelector(".ed-popover__scrim")).backgroundColor,
  )
  const seen = await alice.evaluate(() => window.__scrims)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  const line = `popover scrims: placeholder ${seen && seen.placeholder}, panel ${real}`
  console.log(line)
  expect(seen, "the placeholder never painted").not.toBeNull()
  // Both transparent: whatever the real card does, the stand-in does the same.
  const transparent = (v) => v === "rgba(0, 0, 0, 0)" || v === "transparent"
  expect(transparent(real), `${line} — the real card dims after all, so this test is wrong`).toBe(true)
  expect(transparent(seen.placeholder), `${line} — the placeholder dimmed the screen`).toBe(true)
})
