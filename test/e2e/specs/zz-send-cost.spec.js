// What one incoming message costs the recipient, on the wire (#513, part of epic #506).
//
// The sidebar row for that chat was sent TWICE per message. Not by mistake and not identically by
// accident: `{:conversation_activity}` says "a message arrived, bump this chat", and the read
// handler says "we are looking at it, drop the badge" — and because `mark_read` runs before both,
// they computed the same row. Measured, the second was ~2.6 KB of diff for a picture that does
// not change.
//
// The oracle is the socket, because that is where the cost is. A server-rendered test cannot see
// a duplicate diff at all.
const { test, expect } = require("../helpers/fixtures")

// Phoenix's wire format puts the topic third. Server-PUSHED diffs carry `null` as the second
// element where a reply carries a ref — an earlier version of this pattern required a quoted
// string there and silently counted zero frames.
const isLiveViewFrame = (payload) => /^\["\d*",(?:"[^"]*"|null),"lv:/.test(payload)

// Measured on this stand: 8715 B in 3 frames before, 6132 B in 2 after. The threshold sits
// between them rather than at the achieved number.
const MAX_FRAMES = 2

test("one incoming message does not send the sidebar row twice", async ({
  alice,
  bob,
  seed,
}, testInfo) => {
  let bytes = 0
  let frames = 0
  let counting = false

  alice.on("websocket", (ws) =>
    ws.on("framereceived", (f) => {
      const payload = String(f.payload || "")
      if (counting && isLiveViewFrame(payload)) {
        bytes += Buffer.byteLength(payload)
        frames++
      }
    }),
  )

  for (const page of [alice, bob]) {
    await page.goto(`/app/c/${seed.dm_id}`)
    await page.waitForFunction(
      () => window.liveSocket?.isConnected() && window.__edInstantNavReady,
      null,
      { timeout: 15_000 },
    )
  }
  // Let the mount traffic settle before the window opens.
  await alice.waitForTimeout(2500)

  counting = true
  const text = `cost-${Date.now()}`
  await bob.locator("#composer-body").click()
  await bob.keyboard.type(text)
  await bob.keyboard.press("Enter")

  await alice.locator("#messages", { hasText: text }).waitFor({ timeout: 15_000 })
  await alice.waitForTimeout(2500)
  counting = false

  const line = `receiving one message: ${bytes} B in ${frames} frames`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(frames, `${line} — nothing was measured`).toBeGreaterThan(0)

  // Two frames is the floor and it is not a wish: the message row has to be sent, and the sidebar
  // row has to be sent once. A third means the row went out twice again.
  expect(frames, `${line} — the sidebar row is being sent twice again`).toBeLessThanOrEqual(
    MAX_FRAMES,
  )

  // And the message actually arrived — a "cheap" render that dropped it would score even better.
  await expect(alice.locator("#messages", { hasText: text })).toBeVisible()
})
