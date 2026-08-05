// The space a reaction opens under a message (#565).
//
// The row grows by the height of the reactions block the moment a chip lands, and that growth was
// a single step: the message jumped. An element cannot animate from height 0 to auto, so the block
// is a one-track grid whose track goes 0fr -> 1fr, with `@starting-style` to give a node that did
// not exist a frame ago something to animate FROM.
//
// The oracle is not "it looks smooth" but "the height passed through intermediate values": one
// step means a jump, several mean it opened.
const { test, expect } = require("../helpers/fixtures")

test("the space under a message opens gradually, not in one step", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const body = `reveal-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-msg", { hasText: body }).first()
  await expect(row).toBeVisible()
  const id = await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")

  // The feed suppresses motion for the frame a batch lands in. Wait it out — a person reacting
  // does too.
  await alice.waitForFunction(
    () => !document.getElementById("messages").classList.contains("ed-feed--bulk"),
    null,
    { timeout: 5000 },
  )

  // Sample the row's height every frame across the reveal.
  const heights = await alice.evaluate(async ([mid]) => {
    const el = document.getElementById(`messages-${mid}`)
    const seen = []
    let done
    const finished = new Promise((r) => (done = r))
    const tick = () => {
      seen.push(Math.round(el.getBoundingClientRect().height * 10) / 10)
      if (seen.length < 40) requestAnimationFrame(tick)
      else done()
    }
    requestAnimationFrame(tick)
    window.__edReact(mid, "👍")
    await finished
    return seen
  }, [id])

  const distinct = [...new Set(heights)]
  const line = `row height across the reveal: ${distinct.join(" → ")}`
  console.log(line)

  expect(distinct.length, `${line} — the space appeared in one step`).toBeGreaterThan(3)
  expect(distinct[distinct.length - 1], line).toBeGreaterThan(distinct[0])
})

test("reduced motion gets the space without the animation", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.emulateMedia({ reducedMotion: "reduce" })

  const body = `reveal-rm ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-msg", { hasText: body }).first()
  await expect(row).toBeVisible()
  const id = await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")

  const state = await alice.evaluate(([mid]) => {
    window.__edReact(mid, "👍")
    const box = document.getElementById(`messages-${mid}`).querySelector(".ed-reactions")
    // `transitionProperty`, not the duration: a suppressed transition reads as `none` here, while
    // the duration comes back as Chromium's `1e-05s` rather than a clean `0s`.
    return box && { property: getComputedStyle(box).transitionProperty }
  }, [id])

  expect(state, "nothing was painted").not.toBeNull()
  expect(state.property, "the reveal still animates under reduced motion").toBe("none")
  // ...and the space is there all the same: a suppressed animation must not mean a hidden chip.
  await expect(row.locator(".ed-react")).toBeVisible()
  await alice.emulateMedia({ reducedMotion: null })
})

// ...and closing again. Taking your own last reaction off used to shut the space in one step, the
// same jump in reverse. The node has to stay in the DOM for the length of the transition — an
// element that has left it has nothing to animate — so this is a class, not a removal.
test("the space closes gradually when the last reaction goes", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const body = `collapse-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-msg", { hasText: body }).first()
  await expect(row).toBeVisible()
  const id = await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")

  // Through the SERVER, so the chip is real: an optimistic one is wiped by the next re-render of
  // the row (a read tick is enough), and the close would then be measured from an already-closed
  // state — which is what the first version of this test did.
  await alice.evaluate(
    ([mid]) =>
      window.liveSocket.execJS(
        document.body,
        JSON.stringify([["push", { event: "react", value: { id: mid, emoji: "👍" } }]]),
      ),
    [id],
  )
  await expect(row.locator(".ed-react")).toBeVisible({ timeout: 10_000 })
  await alice.waitForTimeout(400)

  // Slow the socket, or the server's own diff replaces the row before the first animation frame
  // and there is nothing left to measure — on this stand a round trip is milliseconds. On a real
  // connection the optimistic close is what a person sees, which is exactly the thing under test.
  await alice.evaluate(() => window.liveSocket.enableLatencySim(600))

  const before = await alice.evaluate(([mid]) => {
    const el = document.getElementById(`messages-${mid}`)
    return {
      found: !!el,
      h: el && Math.round(el.getBoundingClientRect().height),
      chips: el && el.querySelectorAll(".ed-react").length,
      box: el && !!el.querySelector(".ed-reactions"),
    }
  }, [id])
  console.log("BEFORE", JSON.stringify(before))

  const heights = await alice.evaluate(async ([mid]) => {
    const el = document.getElementById(`messages-${mid}`)
    const seen = []
    let done
    const finished = new Promise((r) => (done = r))
    const tick = () => {
      seen.push(Math.round(el.getBoundingClientRect().height * 10) / 10)
      if (seen.length < 40) requestAnimationFrame(tick)
      else done()
    }
    requestAnimationFrame(tick)
    // The real gesture: a tap on the chip. It paints the close and sends the toggle.
    el.querySelector(".ed-react").click()
    await finished
    return seen
  }, [id])

  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  const distinct = [...new Set(heights)]
  const line = `row height across the close: ${distinct.join(" → ")}`
  console.log(line)

  expect(distinct.length, `${line} — the space shut in one step`).toBeGreaterThan(3)
  expect(distinct[distinct.length - 1], line).toBeLessThan(distinct[0])
})

// Reacting again while the space is closing (#565 review). Two ways this went wrong: the block was
// still wearing the closing class, so the new chip landed inside a collapsed track; and the spent
// chip stayed behind, reading zero, because the revival path only took the class off.
test("a reaction that arrives mid-close reopens the space cleanly", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const body = `revive-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-msg", { hasText: body }).first()
  await expect(row).toBeVisible()
  const id = await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")

  await alice.evaluate(() => window.liveSocket.enableLatencySim(600))

  const state = await alice.evaluate(async ([mid]) => {
    const el = document.getElementById(`messages-${mid}`)
    window.__edReact(mid, "👍") // on
    await new Promise((r) => setTimeout(r, 250))
    window.__edReact(mid, "👍") // off — the space starts closing
    await new Promise((r) => setTimeout(r, 60)) // ...and back on, mid-animation
    window.__edReact(mid, "🎉")
    // Read INSIDE the closing window, not after it: the finish handler cleans up on its own, so a
    // late look sees a tidy result whether or not the re-add was handled (both mutants passed a
    // check taken at +500ms).
    await new Promise((r) => setTimeout(r, 40))

    const box = el.querySelector(".ed-reactions")
    return box && {
      closing: box.classList.contains("ed-reactions--closing"),
      hidden: box.hidden,
      rows: getComputedStyle(box).gridTemplateRows,
      visibleChips: [...box.querySelectorAll(".ed-react")].filter((c) => !c.hidden).length,
      zeroChips: [...box.querySelectorAll(".ed-react")].filter(
        (c) => !c.hidden && (c.querySelector(".ed-react__count")?.textContent || "").trim() === "0",
      ).length,
    }
  }, [id])

  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(state, "the block disappeared entirely").not.toBeNull()
  expect(state.closing, "the block is still marked closing with a live reaction in it").toBe(false)
  expect(state.hidden, "the revived block stayed hidden").toBe(false)
  expect(state.visibleChips, "the new reaction is not on screen").toBe(1)
  expect(state.zeroChips, "a spent chip stayed behind reading zero").toBe(0)
})

// Opening a chat renders every message at once, and each one with reactions would play the reveal
// — fifty little animations for a screen nobody has acted on. That is choreography on load, which
// the product's own motion rules rule out (#565 review).
test("opening a chat does not play the reveal on every message", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  // Watch from before the feed exists.
  await alice.addInitScript(() => {
    window.__reveals = 0
    document.addEventListener(
      "transitionstart",
      (e) => {
        if (e.propertyName === "grid-template-rows" && e.target.classList?.contains("ed-reactions")) {
          window.__reveals++
        }
      },
      true,
    )
  })

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  // Put a real reaction in the chat first, or the load has nothing to animate and the assertion
  // below would pass on any code at all.
  const seedBody = `bulk-seed ${Date.now()}`
  await alice.locator("#composer-body").fill(seedBody)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const seedRow = alice.locator("#messages .ed-msg", { hasText: seedBody }).first()
  await expect(seedRow).toBeVisible()
  const seedId = await seedRow.locator("[phx-value-id]").first().getAttribute("phx-value-id")
  await alice.evaluate(
    ([mid]) =>
      window.liveSocket.execJS(
        document.body,
        JSON.stringify([["push", { event: "react", value: { id: mid, emoji: "👍" } }]]),
      ),
    [seedId],
  )
  await expect(seedRow.locator(".ed-react")).toBeVisible({ timeout: 10_000 })

  // Now load the chat afresh: every block arrives in one batch.
  await alice.evaluate(() => (window.__reveals = 0))
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(1500)

  const onLoad = await alice.evaluate(() => ({
    reveals: window.__reveals,
    blocks: document.querySelectorAll("#messages .ed-reactions").length,
  }))
  console.log(`on open: ${onLoad.blocks} reaction blocks, ${onLoad.reveals} reveals played`)

  expect(onLoad.blocks, "no reactions in this chat, so nothing could have animated").toBeGreaterThan(0)
  expect(onLoad.reveals, "the whole screen animated itself in on load").toBe(0)

  // ...and a single reaction still animates: the suppression is for renders, not for events.
  const body = `bulk-probe ${Date.now()}`
  await alice.locator("#composer-body").fill(body)
  await alice.locator("#composer").evaluate((f) => f.requestSubmit())
  const row = alice.locator("#messages .ed-msg", { hasText: body }).first()
  await expect(row).toBeVisible()
  await alice.waitForTimeout(400)
  const id = await row.locator("[phx-value-id]").first().getAttribute("phx-value-id")

  await alice.evaluate(([mid]) => window.__edReact(mid, "👍"), [id])
  await alice.waitForTimeout(300)
  const after = await alice.evaluate(() => window.__reveals)
  expect(after, "a reaction the person just added did not animate").toBeGreaterThan(onLoad.reveals)
})

// Pulling in history drops a page of rows into a feed that is already mounted, so the server's
// suppression class is not re-sent for it.
//
// Measured honestly: this passes with the batch detection disabled too, so something else is
// already keeping those rows quiet — most likely the synchronous layout the separator reconcile
// does in the same task, which commits the end state before the starting one is ever painted. The
// test stays because "history does not animate itself in" is worth holding down whatever keeps it
// true; the batch threshold above is a rule, not a fix, and is NOT what this proves.
test("pulling in history does not play the reveal on the rows it brings", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.addInitScript(() => {
    window.__reveals = 0
    document.addEventListener(
      "transitionstart",
      (e) => {
        if (e.propertyName === "grid-template-rows" && e.target.classList?.contains("ed-reactions")) {
          window.__reveals++
        }
      },
      true,
    )
  })

  await alice.goto(`/channels/${seed.channel_id}/r/${seed.general_room_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(1200)
  await alice.evaluate(() => (window.__reveals = 0))

  // Page back until the feed stops growing.
  let seen = -1
  for (let i = 0; i < 8; i++) {
    const before = await alice.locator("#messages > *").count()
    if (before === seen) break
    seen = before
    await alice.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }))
    await alice
      .waitForFunction((n) => document.querySelectorAll("#messages > *").length > n, before, {
        timeout: 3000,
      })
      .catch(() => {})
  }
  await alice.waitForTimeout(600)

  const state = await alice.evaluate(() => ({
    rows: document.querySelectorAll("#messages > *").length,
    blocks: document.querySelectorAll("#messages .ed-reactions").length,
    reveals: window.__reveals,
  }))
  console.log(`after paging: ${state.rows} rows, ${state.blocks} reaction blocks, ${state.reveals} reveals`)

  expect(state.blocks, "history brought no reactions, so nothing could have animated").toBeGreaterThan(0)
  expect(state.reveals, "history animated itself in").toBe(0)
})
