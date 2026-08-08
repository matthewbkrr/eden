// Motion under `prefers-reduced-motion: reduce` (#517, part of epic #506).
//
// The blanket fallback at the end of app.css neutralises every TRANSITION, deliberately leaving
// keyframe animations to their own per-case fallbacks so functional spinners keep spinning. That
// makes each of those fallbacks load-bearing — and one of them is out-specificity'd.
const { test, expect } = require("../helpers/fixtures")

// `test.use({ reducedMotion })` would do nothing here: it configures Playwright's own `context`
// fixture, and this harness builds its own signed-in contexts (alice/bob/carol). Measured — with
// `test.use` the page still reported `matchMedia("(prefers-reduced-motion: reduce)").matches ===
// false`, so the first version of this file "proved" a defect that its own instrument had failed
// to ask about. The page-level call is the one that lands.
const reduce = (page) => page.emulateMedia({ reducedMotion: "reduce" })

// The navigation skeleton is on screen for a frame or two, so it is sampled from inside the page
// rather than by an out-of-process assertion that would arrive after it is gone.
test("the navigation skeleton does not animate under reduced motion", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.setViewportSize({ width: 1280, height: 880 })
  await reduce(alice)
  await alice.goto("/app")
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(400)

  await alice.evaluate(() => {
    window.__skel = null
    const tick = () => {
      const el = document.querySelector(".ed-nav-skel")
      if (el) {
        const cs = getComputedStyle(el)
        window.__skel = {
          full: el.classList.contains("ed-nav-skel--full"),
          name: cs.animationName,
          duration: cs.animationDuration,
        }
        return
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).first().click()
  await alice.waitForTimeout(600)

  const skel = await alice.evaluate(() => window.__skel)
  const line = `nav skeleton under reduced motion: ${JSON.stringify(skel)}`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(skel, "the skeleton never painted, so this measures nothing").not.toBeNull()
  expect(
    await alice.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches),
    "the page never asked for reduced motion, so nothing below means anything",
  ).toBe(true)
  expect(skel.name, `${line} — the skeleton still runs a keyframe animation`).toBe("none")
})

// One number for one animation. The flash is a 2200ms keyframe whose fade lives in its last third,
// and two JS timers used to carry the duration themselves — one of them already drifted to 1600ms,
// switching the ring off by a frame in the middle of that fade.
test("everything that clocks the focus flash reads the same number", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const nums = await alice.evaluate(() => {
    // A real bubble, so the number read is the one that actually plays on a message.
    const probe = document.createElement("div")
    probe.className = "ed-msg--focus"
    probe.innerHTML = '<div class="ed-bubble"></div>'
    document.body.appendChild(probe)
    const anim = getComputedStyle(probe.firstElementChild).animationDuration
    probe.remove()
    return {
      token: getComputedStyle(document.documentElement).getPropertyValue("--ed-hold-focus").trim(),
      js: window.__edFocusHold(),
      css: anim,
    }
  })
  console.log("FOCUS HOLD", JSON.stringify(nums))

  const ms = (v) => (v.endsWith("ms") ? parseFloat(v) : parseFloat(v) * 1000)
  expect(nums.token, "the stylesheet no longer names the hold").not.toBe("")
  expect(nums.js, `the timer says ${nums.js}, the token says ${nums.token}`).toBe(ms(nums.token))
  expect(ms(nums.css), `the animation runs ${nums.css}, the token says ${nums.token}`).toBe(
    ms(nums.token),
  )
})

// The check above proves the numbers agree; it says nothing about the timers actually using them —
// a call site could hardcode 1600 again and it would stay green (#571 review). This one watches the
// class the flash lives on, through the very path that had drifted.
test("the flash from the viewer lasts as long as its animation", async ({ alice, seed }) => {
  test.setTimeout(120_000)
  test.skip(!seed.portrait_msg_id, "no seeded photo on this stand")

  await alice.goto(`/app/c/${seed.dm_id}/m/${seed.portrait_msg_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.locator(`#messages-${seed.portrait_msg_id}`).waitFor({ timeout: 15_000 })
  // The permalink lights the message on arrival; wait that flash out, or the observer below would
  // clock its tail instead of the jump's.
  await alice.waitForFunction(() => !document.querySelector(".ed-msg--focus"), null, {
    timeout: 15_000,
  })

  const tile = alice.locator(`#messages-${seed.portrait_msg_id} .ed-photo`).first()
  await tile.click()
  await alice.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
  await alice.waitForTimeout(500)

  await alice.evaluate(() => {
    window.__hold = { added: null, removed: null }
    const seen = () => !!document.querySelector(".ed-msg--focus")
    window.__holdMo = new MutationObserver(() => {
      const t = performance.now()
      if (seen() && window.__hold.added === null) window.__hold.added = t
      else if (!seen() && window.__hold.added !== null && window.__hold.removed === null) {
        window.__hold.removed = t
      }
    })
    window.__holdMo.observe(document.getElementById("messages"), {
      subtree: true,
      attributes: true,
      attributeFilter: ["class"],
    })
  })

  await alice.locator("#ed-lightbox .ed-lightbox__more").click()
  await alice.locator('#ed-lightbox [data-act="show"]').click()
  await alice.waitForTimeout(3500)

  const hold = await alice.evaluate(() => {
    window.__holdMo?.disconnect()
    return window.__hold
  })
  const lasted =
    hold.added !== null && hold.removed !== null ? Math.round(hold.removed - hold.added) : null
  console.log(`viewer jump: flash lasted ${lasted}ms`)

  expect(hold.added, "the jump never lit the message").not.toBeNull()
  expect(lasted, "the flash never went out").not.toBeNull()
  // The animation is 2200ms. 1600 was the drift this exists to catch, so the window is tight
  // enough to separate them and loose enough for a busy frame.
  expect(lasted, `the flash lasted ${lasted}ms, the animation runs 2200ms`).toBeGreaterThan(2000)
  expect(lasted, `the flash lasted ${lasted}ms, the animation runs 2200ms`).toBeLessThan(2800)
})

// A zero hold is a real value — the plain way to switch the flash off from the stylesheet — and it
// is exactly the value the obvious guards swallow: `!n` and a falsy memo both read it as "nothing
// there" and substitute the 2200ms default, which is the opposite of what was asked (#571 review).
test("a zero hold in the stylesheet is honoured, not replaced by the default", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  // Before any hook runs: the helper reads the token once and remembers it.
  await alice.addInitScript(() => {
    const set = () => document.documentElement.style.setProperty("--ed-hold-focus", "0s")
    if (document.documentElement) set()
    else document.addEventListener("DOMContentLoaded", set)
  })

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

  const hold = await alice.evaluate(() => ({
    token: getComputedStyle(document.documentElement).getPropertyValue("--ed-hold-focus").trim(),
    js: window.__edFocusHold(),
  }))
  console.log("ZERO HOLD", JSON.stringify(hold))

  expect(hold.token, "the override never landed, so this measures nothing").toBe("0s")
  expect(hold.js, `the stylesheet asked for ${hold.token}, the timer says ${hold.js}ms`).toBe(0)
})

// Jumping to a message from the photo viewer glided there; the two other jump-to-a-message
// scrollers already scroll instantly. Under reduced motion a glide is the thing to drop.
test("jumping to a message from the viewer does not glide under reduced motion", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)
  test.skip(!seed.portrait_msg_id, "no seeded photo on this stand")

  await reduce(alice)
  // Through the permalink: this DM carries every message the suite has ever sent, so the seeded
  // photo is far above the window a plain open loads.
  await alice.goto(`/app/c/${seed.dm_id}/m/${seed.portrait_msg_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.locator(`#messages-${seed.portrait_msg_id}`).waitFor({ timeout: 15_000 })
  await alice.waitForTimeout(600)

  // Record what the jump asks for, rather than trying to watch a scroll that is over in a frame.
  await alice.evaluate(() => {
    window.__scrolls = []
    const real = Element.prototype.scrollIntoView
    Element.prototype.scrollIntoView = function (opts) {
      window.__scrolls.push(typeof opts === "object" ? opts.behavior || "auto" : String(opts))
      return real.call(this, opts)
    }
  })

  const tile = alice.locator(`#messages-${seed.portrait_msg_id} .ed-photo`).first()
  await tile.scrollIntoViewIfNeeded()
  await tile.click()
  await alice.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
  await alice.waitForTimeout(500)

  await alice.evaluate(() => window.__scrolls.splice(0)) // the open scrolls too; only the jump counts
  await alice.locator("#ed-lightbox .ed-lightbox__more").click()
  await alice.locator('#ed-lightbox [data-act="show"]').click()
  await alice.waitForTimeout(700)

  const behaviors = await alice.evaluate(() => window.__scrolls)
  console.log("JUMP SCROLLS", JSON.stringify(behaviors))
  expect(behaviors.length, "the jump never scrolled at all").toBeGreaterThan(0)
  expect(behaviors, `the jump glided under reduced motion: ${behaviors}`).not.toContain("smooth")
})

// Menus appeared as a fade and disappeared as a cut: `[hidden]` is `display: none`, and nothing
// animates out of that (#517). The exit is a transition with a discrete `display`, so the box stays
// on screen long enough to fade and is then dropped.
test("a menu fades out instead of cutting", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(400)

  // Open the shared message menu the way the app does, on the newest row.
  const opened = await alice.evaluate(() => {
    const rows = document.querySelectorAll("#messages .ed-bubble[data-message-id]")
    const host = rows[rows.length - 1]
    if (!host) return false
    host.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 300, clientY: 300 }))
    return !document.getElementById("message-menu").hidden
  })
  expect(opened, "the menu did not open, so its exit proves nothing").toBe(true)
  await alice.waitForTimeout(400) // let the entrance settle at opacity 1

  // Close it, then sample the frames after: the box has to still be painted, and part-way gone.
  const frames = await alice.evaluate(async () => {
    const m = document.getElementById("message-menu")
    // Through the hook's own close, not by setting `hidden` by hand: the exit is the hook's job.
    document.body.click()
    const seen = []
    for (let i = 0; i < 6; i++) {
      await new Promise((r) => requestAnimationFrame(r))
      const cs = getComputedStyle(m)
      seen.push({ display: cs.display, opacity: Number(cs.opacity), hidden: m.hidden, aria: m.getAttribute("aria-hidden") })
    }
    return seen
  })
  const line = `menu exit frames: ${JSON.stringify(frames)}`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  const mid = frames.filter((f) => f.display !== "none" && f.opacity > 0 && f.opacity < 1)
  expect(mid.length, `${line} — the menu vanished in one frame`).toBeGreaterThan(0)

  // Only the pixels get the extra frames: a screen reader and the pointer are told at once.
  expect(mid.every((f) => f.aria === "true"), `${line} — the leaving menu is still exposed`).toBe(
    true,
  )

  // ...and it does leave: still displayed a few frames later would mean it never drops out.
  await alice.waitForTimeout(500)
  expect(
    await alice.evaluate(() => getComputedStyle(document.getElementById("message-menu")).display),
    "the menu stayed in the layout after its exit",
  ).toBe("none")
})

// The exit is motion like any other: someone who asked for none gets none.
test("a menu leaving under reduced motion does not fade", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await reduce(alice)
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(400)

  const frames = await alice.evaluate(async () => {
    const rows = document.querySelectorAll("#messages .ed-bubble[data-message-id]")
    const host = rows[rows.length - 1]
    host.dispatchEvent(
      new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 300, clientY: 300 }),
    )
    await new Promise((r) => setTimeout(r, 300))
    const m = document.getElementById("message-menu")
    document.body.click()
    const seen = []
    for (let i = 0; i < 4; i++) {
      await new Promise((r) => requestAnimationFrame(r))
      seen.push(Number(getComputedStyle(m).opacity))
    }
    return seen
  })
  console.log("menu exit under reduce:", JSON.stringify(frames))

  expect(
    frames.filter((o) => o > 0 && o < 1).length,
    `the menu faded out under reduced motion: ${frames}`,
  ).toBe(0)
})
