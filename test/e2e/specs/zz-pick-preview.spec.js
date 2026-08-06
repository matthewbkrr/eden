// How soon a picked photo appears (#521 tail).
//
// The staging overlay is gated on `live_entries(@uploads.attachment)` — the SERVER's list — so
// between closing the picker and seeing a thumbnail there is a round trip, even though the file is
// already on the device.
const { test, expect } = require("../helpers/fixtures")
const path = require("path")

const LATENCY = 500
const fixture = (n) => path.join(__dirname, "..", "fixtures", n)

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

// By NAME: the page carries three upload inputs — the main one, the resend channel and the
// sequential one — and the first in document order is the resend channel, so a bare
// `input[type=file]` stages into a slot nothing is watching.
const MAIN_INPUT = 'input[name="attachment"]'

test("a picked photo appears without waiting for the server", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)

  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  const t0 = Date.now()
  await alice.evaluate(() => {
    window.__previewAt = null
    window.__t0 = performance.now()
    const tick = () => {
      if (window.__previewAt === null && document.querySelector("[data-upload-preview] img, .ed-compose-skel img")) {
        window.__previewAt = performance.now() - window.__t0
      }
      if (window.__previewAt === null && performance.now() - window.__t0 < 4000) {
        requestAnimationFrame(tick)
      }
    }
    requestAnimationFrame(tick)
  })

  await alice.setInputFiles(MAIN_INPUT, fixture("sample1.png"))
  await alice.waitForTimeout(2000)

  const at = await alice.evaluate(() => window.__previewAt)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  const line = `picked photo previewed after ${at === null ? "never" : Math.round(at) + "ms"} (socket at ${LATENCY}ms, wall ${Date.now() - t0}ms)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(at, `${line} — no preview appeared at all`).not.toBeNull()
  expect(at, `${line} — the preview waited for the server`).toBeLessThan(LATENCY)
})

// Early is only half of it. The placeholder is a stand-in for a box the server is about to draw, so
// the handoff has to be a swap, not a jump — otherwise the photo lands, then shifts, and the
// abruptness moves rather than goes away.
// Three shapes, because the placeholder and .ImgPreview clamp the box by different routes and only
// agree by construction: `max-width: 100%` against `body.clientWidth - 28`, and `max-height: 60vh`
// against `innerHeight * 0.6`. 900x600 is clamped by neither, 2600x2600 by width, 600x1600 by
// height — one fixture would have proved only the easy case (#569 review).
for (const [file, shape] of [
  ["sample1.png", "900x600, clamped by neither"],
  ["big-photo.png", "2600x2600, clamped by width"],
  ["tall-photo.png", "600x1600, clamped by height"],
])
test(`the photo does not move when the real overlay takes over (${shape})`, async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)
  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  // Sampled while the placeholder is alive, and again on the very frame it leaves: read afterwards
  // and both the box and the fade are already over.
  await alice.evaluate(() => {
    window.__skel = null
    window.__handoffOpacity = null
    const rect = (n) => {
      const r = n.getBoundingClientRect()
      return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
    }
    const tick = () => {
      const img = document.querySelector(".ed-compose-skel .ed-compose__img")
      if (img && img.complete && img.naturalWidth > 0 && img.offsetWidth > 0 && !window.__skel) {
        window.__skel = { img: rect(img), panel: rect(document.querySelector(".ed-compose-skel .ed-compose__panel")) }
      }
      const real = document.querySelector("[data-upload-preview] .ed-compose__img")
      if (window.__skel && !img && real) {
        window.__handoffOpacity = Number(getComputedStyle(real).opacity)
        return
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.setInputFiles(MAIN_INPUT, fixture(file))
  await alice.waitForSelector("[data-upload-preview] .ed-compose__img")
  await expect(alice.locator(".ed-compose-skel")).toHaveCount(0, { timeout: 10_000 })
  // Past the grow-in the real overlay would run on its own: if it still ran, the photo would be
  // mid-animation here and the measurement would catch it.
  await alice.waitForTimeout(400)

  const real = await alice.evaluate(() => {
    const ov = document.querySelector("[data-upload-preview]")
    const rect = (n) => {
      const r = n.getBoundingClientRect()
      return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
    }
    const img = ov.querySelector(".ed-compose__img")
    return { img: rect(img), panel: rect(ov.querySelector(".ed-compose__panel")), src: img.getAttribute("src") }
  })
  const skel = await alice.evaluate(() => window.__skel)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(skel, "the placeholder never painted a photo").not.toBeNull()
  const drift = ["x", "y", "w", "h"].map((k) => Math.abs(real.img[k] - skel.img[k]))
  const line = `handoff drift (${shape}): photo ${drift.join("/")}px (x/y/w/h), panel ${Math.abs(real.panel.h - skel.panel.h)}px tall`
  console.log(line, JSON.stringify({ skel, real }))
  testInfo.annotations.push({ type: "measurement", description: line })

  // 2px covers subpixel rounding between a browser-laid-out box and one .ImgPreview computes.
  expect(Math.max(...drift), `${line} — the photo jumped on handoff`).toBeLessThanOrEqual(2)
  expect(Math.abs(real.panel.h - skel.panel.h), `${line} — the panel resized on handoff`).toBeLessThanOrEqual(2)

  // The real preview shows the URL the placeholder already decoded, rather than a second one for
  // the same file — the shared store is the point, and a broken src would prove it was revoked.
  // The photo was on screen a frame ago; if the real one starts its grow-in from nothing, that
  // reads as a flinch under a picture that had already arrived.
  const opacity = await alice.evaluate(() => window.__handoffOpacity)
  expect(opacity, "never caught the frame the placeholder left on").not.toBeNull()
  expect(opacity, `the real photo faded in from ${opacity} after the handoff`).toBe(1)

  expect(real.src, "the real preview has no source").toMatch(/^blob:/)
  expect(
    await alice.evaluate(() => {
      const im = document.querySelector("[data-upload-preview] .ed-compose__img")
      return im.complete && im.naturalWidth > 0
    }),
    "the real preview is blank — its object URL was pulled out from under it",
  ).toBe(true)
})

// The grid the placeholder draws is a second copy of `album_cols/1`, in JavaScript. A copy drifts
// silently unless something compares it with the original, which is what this does — three photos
// is where the two disagree first (3 across, not 2).
test("a multi-photo pick lands in the same grid the server draws", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)
  await alice.evaluate((ms) => window.liveSocket.enableLatencySim(ms), LATENCY)

  await alice.evaluate(() => {
    window.__skel = null
    const rect = (n) => {
      const r = n.getBoundingClientRect()
      return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
    }
    const tick = () => {
      const tiles = [...document.querySelectorAll(".ed-compose-skel .ed-compose__tile")]
      if (tiles.length === 3 && tiles.every((t) => t.offsetWidth > 0)) {
        window.__skel = {
          tiles: tiles.map(rect),
          panel: rect(document.querySelector(".ed-compose-skel .ed-compose__panel")),
          // A box is not a picture: opacity 0 has a rect too, and only the lone-photo case gets an
          // explicit rule for it (#569 review).
          painted: [...document.querySelectorAll(".ed-compose-skel .ed-compose__img")].map((im) => ({
            opacity: Number(getComputedStyle(im).opacity),
            decoded: im.complete && im.naturalWidth > 0,
            w: im.getBoundingClientRect().width,
          })),
        }
        return
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.setInputFiles(MAIN_INPUT, [fixture("sample1.png"), fixture("sample2.png"), fixture("sample3.png")])
  await expect(alice.locator("[data-upload-preview] .ed-compose__tile")).toHaveCount(3, { timeout: 10_000 })
  await expect(alice.locator(".ed-compose-skel")).toHaveCount(0, { timeout: 10_000 })
  await alice.waitForTimeout(300)

  const real = await alice.evaluate(() => {
    const ov = document.querySelector("[data-upload-preview]")
    const rect = (n) => {
      const r = n.getBoundingClientRect()
      return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
    }
    return {
      tiles: [...ov.querySelectorAll(".ed-compose__tile")].map(rect),
      panel: rect(ov.querySelector(".ed-compose__panel")),
    }
  })
  const skel = await alice.evaluate(() => window.__skel)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(skel, "the placeholder never laid out three tiles").not.toBeNull()
  expect(skel.painted.length, "a tile without a photo in it").toBe(3)
  for (const im of skel.painted) {
    expect(im.opacity, `a placeholder tile is transparent: ${JSON.stringify(skel.painted)}`).toBe(1)
    expect(im.decoded, `a placeholder tile never decoded: ${JSON.stringify(skel.painted)}`).toBe(true)
    expect(im.w, `a placeholder tile has no width: ${JSON.stringify(skel.painted)}`).toBeGreaterThan(0)
  }
  const drift = skel.tiles.flatMap((t, i) => ["x", "y", "w", "h"].map((k) => Math.abs(real.tiles[i][k] - t[k])))
  const line = `3-photo handoff drift: tiles ${Math.max(...drift)}px, panel ${Math.abs(real.panel.h - skel.panel.h)}px`
  console.log(line, JSON.stringify({ skel, real }))
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(Math.max(...drift), `${line} — the tiles moved on handoff`).toBeLessThanOrEqual(2)
  expect(Math.abs(real.panel.h - skel.panel.h), `${line} — the panel resized on handoff`).toBeLessThanOrEqual(2)
})

// A placeholder is a promise the server has to keep. When it cannot — the socket is down, so no
// entry is ever staged — the promise has to expire rather than leave a modal on screen that answers
// nothing.
test("a placeholder the server never answers gives up", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)

  await alice.evaluate(() => window.liveSocket.disconnect())
  await alice.setInputFiles(MAIN_INPUT, fixture("sample1.png"))
  await expect(alice.locator(".ed-compose-skel")).toHaveCount(1)
  await expect(alice.locator(".ed-compose-skel")).toHaveCount(0, { timeout: 10_000 })
  expect(await alice.locator("[data-upload-preview]").count(), "an overlay appeared while offline").toBe(0)
})

// A full-screen scrim that lets taps through to the chat underneath is a lie: the placeholder looks
// modal for as long as it is up, so it has to swallow the tap the way the real overlay does — and
// give the screen back, since it is the one thing on top when the answer never comes.
test("the placeholder catches taps instead of passing them to the chat", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)

  // The composer, because it is always on screen and says plainly whether a press reached it: a
  // press on a text field focuses it.
  const box = await alice.locator("#composer-body").boundingBox()
  expect(box, "no composer to tap through to").not.toBeNull()
  await alice.evaluate(() => document.activeElement?.blur())

  // A second of latency: the placeholder is up long enough that the tap is unambiguously ITS tap
  // and not the real overlay's, which the assertion below re-checks rather than assumes.
  await alice.evaluate(() => window.liveSocket.enableLatencySim(1000))
  await alice.setInputFiles(MAIN_INPUT, fixture("sample1.png"))
  await expect(alice.locator(".ed-compose-skel")).toHaveCount(1)

  const state = await alice.evaluate(() => ({
    skel: document.querySelectorAll(".ed-compose-skel").length,
    real: document.querySelectorAll("[data-upload-preview]").length,
  }))
  await alice.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  const focused = await alice.evaluate(() => document.activeElement?.id || "")
  const skelAfter = await alice.locator(".ed-compose-skel").count()
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(state, "the real overlay was already up — this tap proves nothing about the placeholder").toEqual({
    skel: 1,
    real: 0,
  })
  expect(focused, "the tap went through the placeholder and landed in the composer").not.toBe("composer-body")
  expect(skelAfter, "the placeholder ignored a tap on itself").toBe(0)
})

// Only photos. A document does not go in the grid at all (it is listed under it), and a video tile
// carries a player — a placeholder that drew either as a square photo would move things on handoff.
test("a document pick paints no placeholder", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)

  await alice.setInputFiles(MAIN_INPUT, {
    name: "notes.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("a document, not a photo"),
  })
  expect(await alice.locator(".ed-compose-skel").count(), "a document drew a photo placeholder").toBe(0)
  // ...and the real overlay still opens, so this is "no placeholder", not "no preview".
  await expect(alice.locator("[data-upload-preview]")).toHaveCount(1, { timeout: 10_000 })
})
