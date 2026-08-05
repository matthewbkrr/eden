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
