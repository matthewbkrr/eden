// Swipe down to dismiss the photo viewer (#554), and who holds focus when it opens.
//
// The gesture used to do nothing at all while the finger moved: the photo stayed put, and on
// release the whole dialog cut from 0.85 scrim to transparent in one 150ms fade. What a phone
// gallery does instead is move the photo with the finger and thin the scrim under it, so letting
// go halfway puts everything back.
//
// Touches go through CDP rather than synthetic events: the handlers read `e.touches` and call
// `preventDefault`, and only a real touch stream exercises both.
const { test, expect } = require("../helpers/fixtures")

const openViewer = async (page, seed) => {
  await page.addInitScript(() => {
    window.__edStage = () => {
      const box = document.getElementById("ed-lightbox")
      const stage = box.querySelector(".ed-lightbox__stage")
      const m = new DOMMatrixReadOnly(getComputedStyle(stage).transform)
      return {
        y: Math.round(m.m42),
        scale: Math.round(m.a * 100) / 100,
        fade: Number(
          getComputedStyle(document.documentElement).getPropertyValue("--ed-lb-fade") || 1,
        ),
        open: box.open,
      }
    }
  })
  await page.goto(`/app/c/${seed.dm_id}`)
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  const tile = page.locator(`#messages-${seed.portrait_msg_id} .ed-photo`).first()
  await tile.scrollIntoViewIfNeeded()
  // A finger where there is one: WebKit's focus-visible heuristic weighs the kind of the last
  // interaction, so opening by mouse would answer a different question than the one reported.
  if (await page.evaluate(() => "ontouchstart" in window)) await tile.tap()
  else await tile.click()
  await page.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
  await page.waitForTimeout(800)
}

// A finger, in steps, sampling the stage as it goes.
//
// CDP only. WebKit forbids constructing a `Touch` ("Illegal constructor"), so there is no way to
// synthesise this gesture there — the drag tests below therefore run on Chromium alone, and say so
// rather than quietly covering one engine while looking like they cover all of them.
const dragDown = async (page, distance, { release = true, steps = 8 } = {}) => {
  const cdp = await page.context().newCDPSession(page)
  const { x, y } = await page.evaluate(() => {
    const r = document.querySelector(".ed-lightbox__stage").getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  })
  const send = (type, points) =>
    cdp.send("Input.dispatchTouchEvent", { type, touchPoints: points })

  await send("touchStart", [{ x, y }])
  const samples = []
  for (let i = 1; i <= steps; i++) {
    await send("touchMove", [{ x, y: y + (distance * i) / steps }])
    samples.push(await page.evaluate(() => window.__edStage()))
  }
  if (release) await send("touchEnd", [])
  return samples
}

const touchable = (browserName) =>
  test.skip(browserName !== "chromium", "touch injection is Chromium-only (WebKit blocks new Touch)")

test("the photo follows the finger and the scrim thins under it", async ({ alice, seed, browserName }) => {
  touchable(browserName)
  await openViewer(alice, seed)

  const samples = await dragDown(alice, 140, { release: false })
  const ys = samples.map((s) => s.y)
  const fades = samples.map((s) => s.fade)
  console.log("DRAG", JSON.stringify({ ys, fades, scales: samples.map((s) => s.scale) }))

  // Moving at all is the whole point: this was a flat zero for every frame of the gesture.
  expect(ys[ys.length - 1], `the photo never moved: ${ys}`).toBeGreaterThan(80)
  // ...and monotonically, so it tracks the finger instead of jumping at the end.
  expect(ys.every((v, i) => i === 0 || v >= ys[i - 1]), `not monotonic: ${ys}`).toBe(true)
  // The scrim thins as it goes, rather than stepping to a single value.
  expect(fades[fades.length - 1], `the scrim never thinned: ${fades}`).toBeLessThan(0.8)
  expect(new Set(fades).size, `the scrim moved in one step: ${fades}`).toBeGreaterThan(3)
  // Receding, not sliding off a shelf.
  expect(samples[samples.length - 1].scale).toBeLessThan(1)

  await alice.evaluate(() => document.getElementById("ed-lightbox").__close())
})

test("letting go short of the threshold puts everything back", async ({ alice, seed, browserName }) => {
  touchable(browserName)
  await openViewer(alice, seed)

  // Sampled during the drag, not only after it: without this the test cannot tell "moved and came
  // back" from "never moved at all", which is exactly the behaviour it exists to replace.
  const during = await dragDown(alice, 60)
  expect(during[during.length - 1].y, "the photo did not follow the finger").toBeGreaterThan(30)
  await alice.waitForTimeout(500)

  const rest = await alice.evaluate(() => window.__edStage())
  console.log("SPRUNG BACK", JSON.stringify(rest))
  expect(rest.open, "a short drag closed the viewer").toBe(true)
  expect(rest.y, "the photo stayed where the finger left it").toBe(0)
  expect(rest.fade, "the scrim stayed thin").toBe(1)
})

test("a full drag carries the photo out and closes", async ({ alice, seed, browserName }) => {
  touchable(browserName)
  await openViewer(alice, seed)

  const during = await dragDown(alice, 320)
  expect(during[during.length - 1].y, "the photo did not follow the finger").toBeGreaterThan(150)
  await alice.waitForTimeout(500)

  expect(
    await alice.evaluate(() => document.getElementById("ed-lightbox").open),
    "a full swipe down did not dismiss the viewer",
  ).toBe(false)

  // And the next open starts from rest, not from wherever the last gesture ended.
  const tile = alice.locator(`#messages-${seed.portrait_msg_id} .ed-photo`).first()
  await tile.tap()
  await alice.waitForFunction(() => document.getElementById("ed-lightbox")?.open)

  await alice.waitForTimeout(400)
  const fresh = await alice.evaluate(() => window.__edStage())
  console.log("REOPENED", JSON.stringify(fresh))
  expect(fresh.y, "the viewer reopened still translated").toBe(0)
  expect(fresh.fade, "the viewer reopened with a faded scrim").toBe(1)
})

// `showModal()` hands focus to the first focusable child — the back arrow — and WebKit counts that
// as focus-visible, so on an iPhone the viewer opened with a ring around a control nobody touched.
// This is the engine the report came from, so it must not be skipped here.
test("opening the viewer does not put a focus ring on the back arrow", async ({ alice, seed }) => {
  await openViewer(alice, seed)

  const focus = await alice.evaluate(() => ({
    active: document.activeElement?.id || document.activeElement?.tagName,
    activeTag: document.activeElement?.tagName,
    // Elements that are DRAWN with a ring, not merely matching the selector: WebKit gives the
    // dialog itself focus-visible once it holds focus, and the dialog's own outline is none — so
    // matching alone would fail on a viewer that shows nothing.
    ringed: [...document.querySelectorAll(":focus-visible")]
      .filter((n) => {
        const cs = getComputedStyle(n)
        return cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0
      })
      .map((n) => `${n.tagName}.${n.className}`),
  }))
  console.log("FOCUS", JSON.stringify(focus))

  expect(focus.ringed, "a control is wearing a focus ring on open").toEqual([])
  // The dialog ITSELF, by id — not merely "something whose class starts with ed-lightbox", which
  // every control in here satisfies.
  expect(focus.active, "the dialog did not take its own focus").toBe("ed-lightbox")
  expect(focus.activeTag).toBe("DIALOG")
})

// The other half: this is not "rings removed". A keyboard user must still see where focus is.
// Separate test rather than a tail on the one above, because Safari does not traverse with Tab
// unless the user turns it on — and a mid-test skip would report the check above as skipped too,
// on the very engine the report came from.
test("Tab still shows where focus is", async ({ alice, seed }) => {
  await openViewer(alice, seed)
  await alice.keyboard.press("Tab")

  const tabbed = await alice.evaluate(() => {
    const a = document.activeElement
    return {
      cls: a?.className || a?.tagName,
      inside: !!a && a !== document.getElementById("ed-lightbox") && !!a.closest?.("#ed-lightbox"),
      ring: a?.matches(":focus-visible"),
      width: getComputedStyle(a).outlineWidth,
    }
  })
  console.log("AFTER TAB", JSON.stringify(tabbed))
  test.skip(!tabbed.inside, "this engine does not traverse with Tab")

  expect(tabbed.ring, "Tab no longer shows where focus is").toBe(true)
  expect(parseFloat(tabbed.width), "the focused control has no visible ring").toBeGreaterThan(0)
})

// A gesture can end without a touchend: a second finger arrives, or the system takes the touch
// away. The photo must come home rather than stay where the finger left it.
test("a cancelled gesture puts the photo back", async ({ alice, seed, browserName }) => {
  touchable(browserName)
  await openViewer(alice, seed)

  const cdp = await alice.context().newCDPSession(alice)
  const { x, y } = await alice.evaluate(() => {
    const r = document.querySelector(".ed-lightbox__stage").getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  })
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] })
  await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y + 70 }] })
  expect((await alice.evaluate(() => window.__edStage())).y, "the drag did not start").toBeGreaterThan(30)

  await cdp.send("Input.dispatchTouchEvent", { type: "touchCancel", touchPoints: [] })
  await alice.waitForTimeout(500)

  const after = await alice.evaluate(() => window.__edStage())
  console.log("CANCELLED", JSON.stringify(after))
  expect(after.open, "a cancelled gesture closed the viewer").toBe(true)
  expect(after.y, "the photo stayed where the cancelled gesture left it").toBe(0)
  expect(after.fade, "the scrim stayed thin after a cancelled gesture").toBe(1)
})

// Each settle schedules the same cleanup on a timer. A gesture that starts inside the previous
// one's window used to be stripped of `--dismissing` mid-drag by that stale timer, and the chrome
// stopped fading halfway through (#555 review).
test("a gesture started inside the previous settle keeps fading the chrome", async ({
  alice,
  seed,
  browserName,
}) => {
  touchable(browserName)
  await openViewer(alice, seed)

  // A short drag, released: this schedules the 280ms cleanup.
  await dragDown(alice, 50)

  // ...and a new one immediately, well inside that window.
  const cdp = await alice.context().newCDPSession(alice)
  const { x, y } = await alice.evaluate(() => {
    const r = document.querySelector(".ed-lightbox__stage").getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  })
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] })
  await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y + 40 }] })
  await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y + 90 }] })
  await alice.waitForTimeout(320) // past when the previous settle would have fired

  const mid = await alice.evaluate(() => {
    const box = document.getElementById("ed-lightbox")
    const bar = box.querySelector(".ed-lightbox__bar")
    return {
      dismissing: box.classList.contains("ed-lightbox--dismissing"),
      barOpacity: Number(getComputedStyle(bar).opacity),
      ...window.__edStage(),
    }
  })
  console.log("SECOND GESTURE", JSON.stringify(mid))

  expect(mid.dismissing, "the previous settle stripped the class mid-gesture").toBe(true)
  expect(mid.barOpacity, "the chrome stopped fading mid-gesture").toBeLessThan(1)
  expect(mid.y, "the photo is not following the second gesture").toBeGreaterThan(50)

  await cdp.send("Input.dispatchTouchEvent", { type: "touchCancel", touchPoints: [] })
})
