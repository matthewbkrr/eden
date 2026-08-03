// The photo viewer's geometry, layering and paging (#552).
//
// Three reports, one root each, and none of them visible to a server-rendered test — the viewer is
// a singleton <dialog> built entirely in the `.Lightbox` colocated hook, so what it shows exists
// only in the browser:
//
//   * a tall photo overflowed and slid under the fold. `max-height: 100%` on the image is a
//     percentage against a grid row that the image itself sizes; the browser resolves that cycle
//     to `none`, so a 1200x1600 rendered at 1200x1600 with 778px of it below an 880px viewport.
//   * the ← arrow did nothing, and between 768 and 1160px the bar's own Close and Actions buttons
//     paged instead. Nothing in the viewer declared a z-index, so paint order was DOM order.
//   * paging waited for the original (up to 8 MB) behind `visibility: hidden`, while the decoded
//     preview sat unused in the strip.
//
// Plus the one that reads as "tapping a photo opens a different one": the reel reply from a
// previous open repainting the viewer that replaced it.
const { test, expect } = require("../helpers/fixtures")

// A connected socket is not a mounted hook: the viewer is opened by `.Lightbox` on a real click,
// so a click that lands before hydration does nothing at all and the wait below times out.
// `__edInstantNavReady` is the app's own "hooks are up" signal, which the rest of this harness
// already waits on.
//
// `visit` also installs the helper below. It has to be an init script rather than a string handed
// to `evaluate`: this app ships a nonce CSP with no `unsafe-eval` (#54), so anything that reaches
// `eval()` in page context throws — an init script is injected through the debugger and does not.
const visit = async (page, seed) => {
  if (!page.__edHelperInstalled) {
    page.__edHelperInstalled = true
    await page.addInitScript(() => {
      // The slide a PERSON is looking at: the one under the middle of the stage. Not
      // `querySelector(".ed-lightbox__img")` (that is an outgoing slot) and not `nth-child(2)`
      // either — which slot is on screen is exactly what this file found wrong, so nothing here
      // may assume it.
      window.__edOnScreen = () => {
        const box = document.getElementById("ed-lightbox")
        const s = box.querySelector(".ed-lightbox__stage").getBoundingClientRect()
        const x = s.left + s.width / 2
        return [...box.querySelectorAll(".ed-lightbox__slide")]
          .find((sl) => {
            const r = sl.getBoundingClientRect()
            return r.left <= x && x < r.right
          })
          ?.querySelector("img")
      }
    })
  }
  await page.goto(`/app/c/${seed.dm_id}`)
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
}

const open = async (page, msg, seed) => {
  await visit(page, seed)
  const tile = page.locator(`#messages-${msg} .ed-photo`).first()
  await tile.scrollIntoViewIfNeeded()
  await tile.click()
  await page.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
}

// Complaint number one, stated as an assertion: the photo on screen is the photo that was tapped.
// It was not. The stage centres its children and the track is three stage-widths wide, so the
// track began one stage-width to the left of the stage; the `-stageW` that centres the middle slot
// therefore landed on the slot AFTER it, and every open showed the next photo in the reel.
test("the photo on screen is the one that was tapped", async ({ alice, seed }) => {
  await alice.setViewportSize({ width: 1280, height: 880 })

  for (const msg of [seed.portrait_msg_id, seed.landscape_msg_id]) {
    await visit(alice, seed)
    const tile = alice.locator(`#messages-${msg} .ed-photo`).first()
    await tile.scrollIntoViewIfNeeded()
    const tapped = await tile.getAttribute("data-full")
    await tile.click()
    await alice.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
    await alice.waitForTimeout(900)

    const shown = await alice.evaluate(() => {
      const box = document.getElementById("ed-lightbox")
      const stage = box.querySelector(".ed-lightbox__stage").getBoundingClientRect()
      const slide = window.__edOnScreen().closest(".ed-lightbox__slide").getBoundingClientRect()
      return { src: window.__edOnScreen().dataset.src, offset: Math.abs(slide.left - stage.left) }
    })
    expect(shown.src, `tapped ${tapped} in message ${msg}`).toBe(tapped)
    // Flush with the stage, not merely the nearest slot. The width the track is positioned by is
    // measured from the stage; taking it from `window.innerWidth` instead lands a scrollbar's
    // width off on every platform that reserves one, which this stand (overlay scrollbars) cannot
    // reproduce — so this is the invariant that would catch it elsewhere.
    expect(shown.offset, "the slide is not flush with the stage").toBeLessThanOrEqual(1)
    await alice.keyboard.press("Escape")
  }
})

test("a portrait photo fits between the bar and the strip", async ({ alice, seed }, testInfo) => {
  await alice.setViewportSize({ width: 1280, height: 880 })
  await open(alice, seed.portrait_msg_id, seed)
  await alice.waitForTimeout(1200)

  const geo = await alice.evaluate(() => {
    const box = document.getElementById("ed-lightbox")
    const stage = box.querySelector(".ed-lightbox__stage").getBoundingClientRect()
    const el = window.__edOnScreen()
    const r = el.getBoundingClientRect()
    // The photo inside the element box, which `object-fit: contain` letterboxes.
    const s = Math.min(r.width / el.naturalWidth, r.height / el.naturalHeight)
    return {
      natural: [el.naturalWidth, el.naturalHeight],
      photo: [Math.round(el.naturalWidth * s), Math.round(el.naturalHeight * s)],
      stageH: Math.round(stage.height),
      stageBottom: Math.round(stage.bottom),
      elBottom: Math.round(r.bottom),
      vh: window.innerHeight,
    }
  })

  const line = `portrait ${geo.natural.join("x")} renders ${geo.photo.join("x")} in a ${geo.stageH}px stage`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(geo.natural[1], "the seed photo is not portrait").toBeGreaterThan(geo.natural[0])
  expect(geo.photo[1], `${line} — the photo is taller than the stage`).toBeLessThanOrEqual(
    geo.stageH,
  )
  expect(geo.elBottom, "the photo hangs below the stage").toBeLessThanOrEqual(geo.stageBottom + 1)
})

// Not "the arrow exists" but "a click at its centre reaches it". The arrow was in the DOM, sized,
// visible and completely dead: the stage painted over it, and `elementFromPoint` at the arrow's
// own centre resolved to the photo.
test("every control is the topmost thing at its own centre", async ({ alice, seed }) => {
  // 1280 is where the stage covered the arrows; the 820-1160 band is where the full-height paging
  // zones covered the bar's buttons, so Close paged backwards and Actions was unreachable.
  for (const width of [1280, 1000, 820]) {
    await alice.setViewportSize({ width, height: 880 })
    await open(alice, seed.portrait_msg_id, seed)
    await alice.waitForTimeout(900)

    const hits = await alice.evaluate(() => {
      const at = (sel) => {
        const el = document.querySelector(sel)
        if (!el) return "missing"
        const r = el.getBoundingClientRect()
        if (!r.width) return "zero-sized"
        const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
        return top === el || el.contains(top) ? "ok" : `covered by ${top?.tagName}.${top?.className}`
      }
      return {
        "previous arrow": at(".ed-lightbox__nav--prev"),
        "next arrow": at(".ed-lightbox__nav--next"),
        close: at(".ed-lightbox__close"),
        actions: at(".ed-lightbox__more"),
      }
    })

    for (const [name, verdict] of Object.entries(hits)) {
      expect(verdict, `${name} at ${width}px`).toBe("ok")
    }
  }
})

// The element that holds the photo spans the whole stage so that the preview and the original
// occupy the same box. That makes `e.target` the <img> even in the letterboxing beside a portrait,
// where a tap has always dismissed the viewer — so the dismiss has to hit-test the photo itself.
test("a tap beside a portrait photo closes, a tap on it does not", async ({ alice, seed }) => {
  await alice.setViewportSize({ width: 1280, height: 880 })
  await open(alice, seed.portrait_msg_id, seed)
  await alice.waitForFunction(() => {
    const el = window.__edOnScreen()
    return el && el.complete && el.naturalWidth > 0
  })

  const points = await alice.evaluate(() => {
    const el = window.__edOnScreen()
    const r = el.getBoundingClientRect()
    const s = Math.min(r.width / el.naturalWidth, r.height / el.naturalHeight)
    const w = el.naturalWidth * s
    const cx = r.left + r.width / 2
    const cy = r.top + r.height / 2
    return {
      onPhoto: [cx, cy],
      // Just clear of the photo's edge. Not halfway to the stage edge: the paging zone lives
      // there, and a click in it is meant to page, so that point proves nothing either way.
      beside: [cx + w / 2 + 24, cy],
      gap: Math.round(r.width - w),
    }
  })

  expect(points.gap, "this photo fills the stage, so there is nothing beside it to tap")
    .toBeGreaterThan(80)

  await alice.mouse.click(...points.onPhoto)
  await alice.waitForTimeout(300)
  expect(
    await alice.evaluate(() => document.getElementById("ed-lightbox").open),
    "tapping the photo itself closed the viewer",
  ).toBe(true)

  await alice.mouse.click(...points.beside)
  await alice.waitForTimeout(400)
  expect(
    await alice.evaluate(() => document.getElementById("ed-lightbox").open),
    "tapping the backdrop beside the photo did not close the viewer",
  ).toBe(false)
})

// Zooming moves the photo's edges outward; the dismiss hit test has to move with them. It did not:
// it measured the photo from the untransformed layout box, so at 2.5x a click on the enlarged photo
// outside its 1x footprint read as backdrop and closed the viewer (#553 review).
test("a click on a zoomed photo does not dismiss the viewer", async ({ alice, seed }) => {
  await alice.setViewportSize({ width: 1280, height: 880 })
  await open(alice, seed.portrait_msg_id, seed)
  await alice.waitForFunction(() => {
    const el = window.__edOnScreen()
    return !!el && el.complete && el.naturalWidth > 0
  })

  const box = await alice.evaluate(() => {
    const el = window.__edOnScreen()
    const r = el.getBoundingClientRect()
    const s = Math.min(r.width / el.naturalWidth, r.height / el.naturalHeight)
    return { cx: r.left + r.width / 2, cy: r.top + r.height / 2, w: el.naturalWidth * s }
  })

  // Zoom about the centre, the way a double-click does.
  await alice.mouse.dblclick(box.cx, box.cy)
  await alice.waitForTimeout(400)

  const zoomed = await alice.evaluate(() => {
    const el = window.__edOnScreen()
    const r = el.getBoundingClientRect()
    const s = Math.min(r.width / el.naturalWidth, r.height / el.naturalHeight)
    return { cx: r.left + r.width / 2, w: el.naturalWidth * s, cy: r.top + r.height / 2 }
  })
  expect(zoomed.w, "the double-click did not zoom, so this proves nothing").toBeGreaterThan(
    box.w * 1.5,
  )

  // A point that is on the ENLARGED photo, outside its unzoomed footprint, and clear of the paging
  // zone — a click in the zone pages and never reaches the dismiss, so it would pass either way.
  const spot = await alice.evaluate(
    ([unzoomedRight, enlargedRight]) => {
      const zone = document
        .querySelector(".ed-lightbox__zone--next")
        .getBoundingClientRect()
      const limit = Math.min(enlargedRight, zone.left)
      return { x: (unzoomedRight + limit) / 2, room: limit - unzoomedRight }
    },
    [box.cx + box.w / 2, zoomed.cx + zoomed.w / 2],
  )
  expect(spot.room, "no room between the unzoomed photo and the paging zone to test with")
    .toBeGreaterThan(40)

  await alice.mouse.click(spot.x, zoomed.cy)
  await alice.waitForTimeout(400)

  expect(
    await alice.evaluate(() => document.getElementById("ed-lightbox").open),
    "clicking the enlarged photo closed the viewer",
  ).toBe(true)
})

test("with the original unavailable the viewer still shows the photo", async ({ alice, seed }) => {
  await alice.setViewportSize({ width: 1280, height: 880 })

  // Block every original BEFORE opening. Previews come from a different URL and are what the strip
  // already decodes, so this isolates the question exactly: when the big file is not there yet,
  // does a frame appear or a blank? It used to be a blank — the slide carried the original behind
  // `visibility: hidden` and nothing was drawn until it arrived.
  await alice.route(/\/files\/\d+$/, (route) => route.abort())

  await open(alice, seed.portrait_msg_id, seed)
  await alice.waitForTimeout(1500)

  const shown = async () =>
    alice.evaluate(() => {
      const el = window.__edOnScreen()
      return {
        visible: getComputedStyle(el).visibility,
        showing: (el.currentSrc || "").split("/files/")[1] || "",
        decoded: el.complete && el.naturalWidth > 0,
      }
    })

  // Wait for the condition, not for a duration: a preview decode is a few tens of milliseconds on
  // one run and past 300ms on a loaded one. The bound is what makes this a test — with the original
  // blocked and no preview painted, nothing ever decodes and this times out.
  const painted = async () => {
    await alice
      .waitForFunction(
        () => {
          const el = window.__edOnScreen()
          return !!el && el.complete && el.naturalWidth > 0
        },
        null,
        { timeout: 4000 },
      )
      .catch(() => {})
  }

  await painted()
  const onOpen = await shown()
  expect(onOpen.decoded, "the viewer opened on an empty frame").toBe(true)
  expect(onOpen.visible, "the viewer opened hidden").toBe("visible")
  expect(onOpen.showing, "the slot waited for the original instead of painting the preview")
    .toContain("/thumb/")

  await alice.evaluate(() => document.getElementById("ed-lightbox").__step(1))
  await alice.waitForTimeout(320) // past the slide, so the settled centre slot is the one measured
  await painted()

  const afterStep = await shown()
  expect(afterStep.decoded, "paging landed on an empty frame").toBe(true)
  expect(afterStep.showing, "paging waited for the original").toContain("/thumb/")
})

test("the stage does not resize under the photo when the reel lands", async ({ alice, seed }) => {
  await alice.setViewportSize({ width: 1280, height: 880 })
  await visit(alice, seed)
  const tile = alice.locator(`#messages-${seed.portrait_msg_id} .ed-photo`).first()
  await tile.scrollIntoViewIfNeeded()

  // Sample every frame from before the tap: the strip's band used to be claimed only once the
  // server's reel arrived, which moved the photo a round-trip after it appeared.
  await alice.evaluate(() => {
    window.__bottoms = []
    const tick = () => {
      const b = document.getElementById("ed-lightbox")
      const st = b && b.open && b.querySelector(".ed-lightbox__stage")
      if (st) window.__bottoms.push(Math.round(st.getBoundingClientRect().bottom))
      if (window.__bottoms.length < 90) requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await tile.click()
  await alice.waitForTimeout(1600)

  const seen = await alice.evaluate(() => [...new Set(window.__bottoms)])
  expect(seen.length, `the stage resized mid-open: ${seen.join(" then ")}`).toBe(1)
})

test("a reel reply that arrives after a reopen cannot repaint the viewer", async ({
  alice,
  seed,
}) => {
  await alice.setViewportSize({ width: 1280, height: 880 })
  await visit(alice, seed)
  await alice.locator(`#messages-${seed.landscape_msg_id} .ed-photo`).first().scrollIntoViewIfNeeded()

  await open(alice, seed.portrait_msg_id, seed)

  // Hold the NEXT reel reply rather than delivering it. The callback is the production one,
  // untouched; only its arrival moves. Nothing else can produce this window on a local stand:
  // network throttling does not touch an established WebSocket (measured — the reply still landed
  // in 173ms), and forcing the long-poll fallback delivers both replies inside one batch, so the
  // DOM never shows the intermediate state at all.
  await alice.evaluate(() => {
    const hook = document.getElementById("ed-lightbox").__hook
    const real = hook.pushEvent.bind(hook)
    hook.pushEvent = (ev, payload, cb) =>
      ev === "lightbox_media" && cb
        ? real(ev, payload, (reply) => (window.__late = () => cb(reply)))
        : real(ev, payload, cb)
    document.getElementById("ed-lightbox").__close()
    setTimeout(() => hook.openLightbox(), 200)
  })
  await alice.waitForFunction(() => typeof window.__late === "function", null, { timeout: 15_000 })

  // Now open a different photo, the way a person would.
  await alice.evaluate(() => document.getElementById("ed-lightbox").__close())
  await alice.locator(`#messages-${seed.landscape_msg_id} .ed-photo`).first().click()
  await alice.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
  await alice.waitForTimeout(400)

  const shown = () =>
    alice.evaluate(() => {
      const b = document.getElementById("ed-lightbox")
      return {
        photo: Number((window.__edOnScreen().dataset.src || "").split("/").pop()),
        message: b.__meta && String(b.__meta.msg),
      }
    })

  const before = await shown()
  await alice.evaluate(() => window.__late())
  await alice.waitForTimeout(400)
  const after = await shown()

  expect(after.photo, "the late reply repainted the viewer with the previous photo").toBe(
    before.photo,
  )
  expect(after.message, "the late reply moved the chrome to the previous message").toBe(
    before.message,
  )
})
// Paging used to rebuild the filmstrip on every step: ~49 <img> nodes replaced while the slide
// animation was running, and the 44 thumbnail requests that came with it queued ahead of the
// preview for the photo being paged TO. Measured here: six steps, six rebuilds before, zero after.
test("paging inside the strip's window does not rebuild it", async ({ alice, seed }, testInfo) => {
  await alice.setViewportSize({ width: 1280, height: 880 })
  await visit(alice, seed)
  const tile = alice.locator(`#messages-${seed.portrait_msg_id} .ed-photo`).first()
  await tile.scrollIntoViewIfNeeded()
  await tile.click()
  await alice.waitForFunction(() => document.getElementById("ed-lightbox")?.open)
  await alice.waitForTimeout(1600)

  const files = []
  alice.on("request", (r) => r.url().includes("/files/") && files.push(r.url().split("/files/")[1]))

  await alice.evaluate(() => {
    const strip = document.querySelector(".ed-lightbox__strip")
    window.__rebuilds = 0
    new MutationObserver((ms) => {
      for (const m of ms) if (m.addedNodes.length > 1) window.__rebuilds++
    }).observe(strip, { childList: true })
    window.__tabbable = strip.querySelectorAll("button").length
  })

  for (let i = 0; i < 6; i++) {
    await alice.evaluate(() => document.getElementById("ed-lightbox").__step(1))
    await alice.waitForTimeout(340)
  }

  const stats = await alice.evaluate(() => ({ rebuilds: window.__rebuilds, tabbable: window.__tabbable }))
  const originals = files.filter((f) => !f.includes("/thumb/"))
  const thumbs = files.filter((f) => f.includes("/thumb/"))
  const line = `6 steps: ${originals.length} originals, ${thumbs.length} thumbnails, ${stats.rebuilds} strip rebuilds`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(stats.rebuilds, `${line} — the strip is rebuilding on steps inside its own window`).toBe(0)
  // One original per step, for the newly-adjacent photo. Anything more is a redundant fetch.
  expect(originals.length, line).toBeLessThanOrEqual(6)
  expect(thumbs.length, `${line} — thumbnails are being refetched instead of reused`).toBe(0)
})
