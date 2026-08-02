// What one incoming message costs the recipient, on the wire (#513, part of epic #506).
//
// The sidebar row for that chat was sent TWICE per message. Not by mistake and not identically by
// accident: `{:conversation_activity}` says "a message arrived, bump this chat", and the read
// handler says "we are looking at it, drop the badge" — and because `mark_read` runs before both,
// they computed the same row. Measured, the second was ~2.6 KB of diff for a picture that does
// not change.
//
// The oracle is the socket, because that is where the cost is: a server-rendered test cannot see
// a duplicate diff at all.
const { test, expect } = require("../helpers/fixtures")

// Phoenix's wire format puts the topic third. Server-PUSHED diffs carry `null` as the second
// element where a reply carries a ref — an earlier version of this pattern required a quoted
// string there and silently counted zero frames, i.e. reported a perfect result.
const isLiveViewFrame = (payload) => /^\["\d*",(?:"[^"]*"|null),"lv:/.test(payload)

// Counted specifically, not "every frame in the window" (#551 review). A window count is at the
// mercy of anything else the session happens to receive — presence, timers, another tab — so a
// legitimate unrelated diff would fail this and teach people to ignore it. The sidebar row is
// identifiable: its stream item id is `conversations-<id>`.
const isSidebarRow = (payload, convId) => payload.includes(`conversations-${convId}`)

test("one incoming message sends the sidebar row once", async ({ alice, bob, seed }, testInfo) => {
  let sidebarFrames = 0
  let sidebarBytes = 0
  let counting = false

  alice.on("websocket", (ws) =>
    ws.on("framereceived", (f) => {
      const payload = String(f.payload || "")
      if (counting && isLiveViewFrame(payload) && isSidebarRow(payload, seed.dm_id)) {
        sidebarFrames++
        sidebarBytes += Buffer.byteLength(payload)
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
  await alice.waitForTimeout(2500)

  counting = true
  const text = `cost-${Date.now()}`
  await bob.locator("#composer-body").click()
  await bob.keyboard.type(text)
  await bob.keyboard.press("Enter")

  // Wait for the message to land, then for the socket to go quiet — the second sidebar frame used
  // to arrive AFTER the message was already visible, so stopping at "the text is there" would
  // have missed exactly the thing under test.
  await alice.locator("#messages", { hasText: text }).waitFor({ timeout: 15_000 })
  await alice.waitForTimeout(2500)
  counting = false

  const line = `sidebar row: ${sidebarFrames} frame(s), ${sidebarBytes} B`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  // Once. Not "at most two" — the row genuinely has to be sent, and sending it twice is the whole
  // defect. Two legitimate handlers compute the same row; only one of them should reach the wire.
  expect(sidebarFrames, `${line} — the sidebar row is being sent twice again`).toBe(1)

  // And the message actually arrived: a render that dropped it would score even better.
  await expect(alice.locator("#messages", { hasText: text })).toBeVisible()
})
