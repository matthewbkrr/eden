// Where an optimistically-painted reaction lands (#562 follow-up).
//
// The chip is created client-side so the tap answers immediately, which means the client has to
// put it where the server would. In a bubble row (DMs and groups) the server renders the reactions
// block as a SIBLING of `.ed-bubble`; the first version appended it INSIDE the bubble, so a
// reaction flew to the left inside the blue bubble for a round trip and then jumped into place.
//
// The oracle is not "it looks right" but "the client's parent is the server's parent".
const { test, expect } = require("../helpers/fixtures")

test("an optimistic reaction lands where the server puts it", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const body = `anchor-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-msg", { hasText: body }).first()
  await expect(row).toBeVisible()
  // From the row's own stream dom id (`messages-123`). It used to be scraped off any
  // `[phx-value-id]` inside the row — which was the select overlay, and since #561 that exists
  // only while selection mode is on. A row's identity is its stream id; the overlay never was.
  const id = await row.evaluate((r) => /-(\d+)$/.exec(r.id)[1])

  // Paint it, and record the parent the CLIENT chose — read once, before any answer can arrive.
  const optimistic = await alice.evaluate(([mid]) => {
    window.__edReact(mid, "👍")
    const box = document.getElementById(`messages-${mid}`).querySelector(".ed-reactions")
    return box && {
      parentClass: box.parentElement.className,
      insideBubble: !!box.closest(".ed-bubble"),
    }
  }, [id])

  expect(optimistic, "nothing was painted").not.toBeNull()
  expect(optimistic.insideBubble, "the chip was painted inside the bubble").toBe(false)

  // Now let the server answer and compare: same parent, or the chip moves when the diff lands.
  await expect(row.locator(".ed-react")).toBeVisible({ timeout: 10_000 })
  await alice.waitForTimeout(400)

  const authoritative = await alice.evaluate(([mid]) => {
    const box = document.getElementById(`messages-${mid}`).querySelector(".ed-reactions")
    return box && { parentClass: box.parentElement.className, insideBubble: !!box.closest(".ed-bubble") }
  }, [id])

  expect(authoritative.insideBubble).toBe(false)
  expect(
    optimistic.parentClass,
    `client put it under "${optimistic.parentClass}", server under "${authoritative.parentClass}"`,
  ).toBe(authoritative.parentClass)
})
