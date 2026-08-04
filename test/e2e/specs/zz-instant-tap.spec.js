// How long a tap sits there doing nothing (#521, part of epic #506).
//
// Two of the most frequent gestures in the app answer only when the server does: a reaction chip
// (the handler returns `{:noreply, socket}` and the chips come back over PubSub) and the
// multi-select checkbox (painted by a hook AFTER the diff). On this stand the round trip is a few
// milliseconds and both look instant, which is exactly why the defect survived — so the socket is
// slowed deliberately with LiveView's own latency simulator, and the question becomes: does
// anything change on screen BEFORE the server answers?
const { test, expect } = require("../helpers/fixtures")

const LATENCY = 400

const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

// Time from the click to the first MEANINGFUL change inside the row.
//
// Not "any mutation": LiveView stamps `phx-click-loading` on the clicked element in the same tick,
// so an observer that takes anything reports ~0ms however mute the interface is — the first
// version of this file did exactly that and passed on the unfixed code. What counts is the state a
// person can see: whether the control reads as pressed, and what it says.
const armProbe = (page, rowSelector, targetSelector) =>
  page.evaluate(([sel, target]) => {
    const row = document.querySelector(sel)
    const sig = () =>
      [...row.querySelectorAll(target)]
        .map((n) => {
          const cls = [...n.classList].filter((c) => !c.startsWith("phx-")).join(".")
          return `${cls}|${n.getAttribute("aria-pressed")}|${n.textContent.trim()}`
        })
        .join("~")
    window.__sig0 = sig()
    window.__firstChange = null
    window.__probeStart = null
    window.__probeObs = new MutationObserver(() => {
      if (window.__probeStart === null || window.__firstChange !== null) return
      if (sig() !== window.__sig0) window.__firstChange = performance.now() - window.__probeStart
    })
    window.__probeObs.observe(row, { childList: true, subtree: true, attributes: true, characterData: true })
  }, [rowSelector, targetSelector])

const readProbe = (page) =>
  page.evaluate(() => {
    window.__probeObs?.disconnect()
    return window.__firstChange
  })

test("a reaction answers the finger, not the round trip", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.goto(room(seed))
  await ready(alice)

  const body = `react-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-flat", { hasText: body }).first()
  await expect(row).toBeVisible()
  const rowId = await row.getAttribute("id")

  // React once through the server so the chip exists, then measure toggling it OFF and ON.
  await alice.evaluate(
    ([id]) => window.liveSocket.execJS(document.body, JSON.stringify([["push", { event: "react", value: { id, emoji: "👍" } }]])),
    [await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")],
  )
  await expect(row.locator(".ed-react")).toBeVisible({ timeout: 10_000 })

  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)
  await armProbe(alice, `#${rowId}`, ".ed-react")

  await alice.evaluate(() => (window.__probeStart = performance.now()))
  await row.locator(".ed-react").first().click()
  await alice.waitForTimeout(LATENCY / 2)

  const delay = await readProbe(alice)
  const line = `reaction: first change ${delay === null ? "never" : Math.round(delay) + "ms"} after the tap (socket at ${LATENCY}ms)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(delay, `${line} — the tap did nothing until the server answered`).not.toBeNull()
  expect(delay, line).toBeLessThan(LATENCY / 2)

  // ...and the guess has to agree with the answer. The chip held one reaction — ours — so the
  // authoritative render removes it; an optimistic paint that fought morphdom would leave a chip
  // reading "0" or a stuck highlight.
  await expect(row.locator(".ed-react")).toHaveCount(0, { timeout: 10_000 })
})

test("the multi-select checkbox ticks under the finger", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.goto(room(seed))
  await ready(alice)

  const body = `select-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-flat", { hasText: body }).first()
  await expect(row).toBeVisible()
  const rowId = await row.getAttribute("id")

  // Enter selection mode through the server, then measure the NEXT tick.
  await alice.evaluate(
    ([id]) => window.liveSocket.execJS(document.body, JSON.stringify([["push", { event: "enter_select", value: { id } }]])),
    [await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")],
  )
  await expect(alice.locator("#messages.ed-selecting")).toBeVisible({ timeout: 10_000 })

  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)
  await armProbe(alice, `#${rowId}`, ".ed-select-hit, .ed-select-check")

  await alice.evaluate(() => (window.__probeStart = performance.now()))
  await row.locator(".ed-select-hit").first().click()
  await alice.waitForTimeout(LATENCY / 2)

  const delay = await readProbe(alice)
  const line = `select: first change ${delay === null ? "never" : Math.round(delay) + "ms"} after the tap (socket at ${LATENCY}ms)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(delay, `${line} — the checkbox waited for the database`).not.toBeNull()
  expect(delay, line).toBeLessThan(LATENCY / 2)
})

// Painting before the server answers means a refusal has to be undone. The server re-streams the
// row on a rejected toggle, so an emoji outside the allowed set leaves nothing behind.
test("a reaction the server refuses does not stay on screen", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(room(seed))
  await ready(alice)

  const body = `reject-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-flat", { hasText: body }).first()
  await expect(row).toBeVisible()
  const id = await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")

  // 🦄 is not in `MessageReaction.allowed/0`. Paint it the way a tap would, then send the event.
  await alice.evaluate(([mid]) => window.__edReact(mid, "🦄"), [id])
  await expect(row.locator(".ed-react")).toBeVisible()

  await alice.evaluate(
    ([mid]) =>
      window.liveSocket.execJS(
        document.body,
        JSON.stringify([["push", { event: "react", value: { id: mid, emoji: "🦄" } }]]),
      ),
    [id],
  )

  // The server refuses and re-streams the row; the invented chip must be gone.
  await expect(row.locator(".ed-react")).toHaveCount(0, { timeout: 10_000 })
})

// Taking the last reaction off hides the chip. Putting it back before the server answers has to
// bring it back — the toggle found the chip again but left it hidden, so the restored reaction was
// invisible for a whole round trip (#562 review).
test("re-adding a reaction before the server answers shows it again", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(room(seed))
  await ready(alice)

  const body = `retoggle-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-flat", { hasText: body }).first()
  await expect(row).toBeVisible()
  const id = await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")

  await alice.evaluate(
    ([mid]) =>
      window.liveSocket.execJS(
        document.body,
        JSON.stringify([["push", { event: "react", value: { id: mid, emoji: "👍" } }]]),
      ),
    [id],
  )
  const chip = row.locator(".ed-react").first()
  await expect(chip).toBeVisible({ timeout: 10_000 })

  // Off and straight back on, both inside one (slowed) round trip.
  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)
  await chip.click()
  await expect(chip).toBeHidden()
  // Re-add and read ONCE, with no auto-retry: the server's own answer to the first tap is still in
  // flight and will remove the chip for real, so a retrying assertion would be judging the
  // authoritative render rather than the optimistic one (learned the hard way elsewhere in this
  // harness).
  const restored = await alice.evaluate(([mid]) => {
    window.__edReact(mid, "👍")
    const row = document.getElementById(`messages-${mid}`)
    const c = row && row.querySelector('.ed-react[phx-value-emoji="👍"]')
    return c && { hidden: c.hidden, text: c.textContent.trim(), pressed: c.getAttribute("aria-pressed") }
  }, [id])

  expect(restored, "the chip vanished entirely").not.toBeNull()
  expect(restored.hidden, "the restored reaction stayed invisible").toBe(false)
  expect(restored.text, `the restored chip reads "${restored && restored.text}"`).toMatch(/1/)
  expect(restored.pressed).toBe("true")
  await alice.evaluate(() => window.liveSocket.disableLatencySim())
})

// The correction carries the server's state, it does not invert the guess. That matters for the
// add-add race, where a refusal means "someone else's insert won" and the reaction IS there:
// inverting would show "not mine" over a row where it is mine, with no later diff to fix it
// (#562 review).

// NOTE: there is deliberately no e2e for "the correction carries the server's state rather than
// the inverse of the guess". Telling those two apart needs a foreign reaction already on the
// message, and the version of this test that arranged one via the second browser could not get
// bob's chip to appear on alice's page on this stand — a fixture problem, not a product one, and a
// test that cannot fail for the right reason is worse than none. The server half of that contract
// is covered in `chat_live_test.exs` instead, where it is deterministic and runs in CI.
