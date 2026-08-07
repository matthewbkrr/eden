// How soon a picked photo appears (#521 tail).
//
// The staging overlay is gated on `live_entries(@uploads.attachment)` — the SERVER's list — so
// between closing the picker and seeing a thumbnail there is a round trip, even though the file is
// already on the device.
const { test, expect } = require("../helpers/fixtures")
const fs = require("fs")
const path = require("path")

const LATENCY = 500
const fixture = (n) => path.join(__dirname, "..", "fixtures", n)

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

// By NAME: the page carries three upload inputs — the main one, the resend channel and the
// sequential one — and the first in document order is the resend channel, so a bare
// `input[type=file]` stages into a slot nothing is watching.
const MAIN_INPUT = 'input[name="attachment"]'

// N distinct photos from the one on disk: the trailing bytes are ignored by every decoder and make
// each file its own (name AND size), so nothing collapses into one entry on the way in.
const photos = (n) => {
  const base = fs.readFileSync(fixture("sample1.png"))
  return Array.from({ length: n }, (_, i) => ({
    name: `pick-${i}.png`,
    mimeType: "image/png",
    buffer: Buffer.concat([base, Buffer.alloc(i + 1)]),
  }))
}

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
      const imgs = [...document.querySelectorAll(".ed-compose-skel .ed-compose__img")]
      // The tile is a CSS square from the first frame, the photo inside it is not: snapshot once
      // all three have decoded, or the probe races the decode and reports a tile as blank when it
      // was merely early (a flake this test had, not a defect it caught).
      if (
        tiles.length === 3 &&
        tiles.every((t) => t.offsetWidth > 0) &&
        imgs.length === 3 &&
        imgs.every((im) => im.complete && im.naturalWidth > 0)
      ) {
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

// Twelve, because the overlay shows every staged photo (albums of ten are a SEND-side split) and a
// placeholder that drew only the first ten would resize the panel on handoff — the same jump the
// tests above exist to catch, one pick size further out.
test("a pick past one album still hands off without moving", async ({ alice, seed }, testInfo) => {
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
      if (tiles.length && tiles.every((t) => t.offsetWidth > 0)) {
        window.__skel = {
          count: tiles.length,
          panel: rect(document.querySelector(".ed-compose-skel .ed-compose__panel")),
          first: rect(tiles[0]),
          last: rect(tiles[tiles.length - 1]),
        }
        return
      }
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.setInputFiles(MAIN_INPUT, photos(12))
  await expect(alice.locator("[data-upload-preview] .ed-compose__tile")).toHaveCount(12, { timeout: 15_000 })
  await expect(alice.locator(".ed-compose-skel")).toHaveCount(0, { timeout: 10_000 })
  await alice.waitForTimeout(300)

  const real = await alice.evaluate(() => {
    const ov = document.querySelector("[data-upload-preview]")
    const rect = (n) => {
      const r = n.getBoundingClientRect()
      return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
    }
    const tiles = [...ov.querySelectorAll(".ed-compose__tile")]
    return {
      count: tiles.length,
      panel: rect(ov.querySelector(".ed-compose__panel")),
      first: rect(tiles[0]),
      last: rect(tiles[tiles.length - 1]),
    }
  })
  const skel = await alice.evaluate(() => window.__skel)
  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(skel, "the placeholder never laid out its tiles").not.toBeNull()
  const line = `12-photo handoff: placeholder drew ${skel.count} tiles, overlay ${real.count}; panel ${Math.abs(real.panel.h - skel.panel.h)}px`
  console.log(line, JSON.stringify({ skel, real }))
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(skel.count, `${line} — the placeholder truncated the pick`).toBe(real.count)
  expect(Math.abs(real.panel.h - skel.panel.h), `${line} — the panel resized on handoff`).toBeLessThanOrEqual(2)
  for (const k of ["x", "y", "w", "h"]) {
    expect(Math.abs(real.first[k] - skel.first[k]), `${line} — the first tile moved (${k})`).toBeLessThanOrEqual(2)
    expect(Math.abs(real.last[k] - skel.last[k]), `${line} — the last tile moved (${k})`).toBeLessThanOrEqual(2)
  }
})

// Past the staging cap SendQueue stops the pick dead — nothing stages, no overlay is coming — so a
// placeholder here would be a photo that vanishes a few seconds later.
test("a pick past the staging cap paints no placeholder", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)

  const max = await alice.evaluate(() => Number(document.getElementById("composer")?.dataset.maxStaged))
  expect(max, "the composer does not carry the staging cap").toBeGreaterThan(0)

  await alice.setInputFiles(MAIN_INPUT, photos(max + 1))
  await alice.waitForTimeout(1500)
  expect(await alice.locator(".ed-compose-skel").count(), "an over-cap pick drew a placeholder").toBe(0)
  expect(await alice.locator("[data-upload-preview]").count(), "an over-cap pick staged after all").toBe(0)
})

// A file can say image/png and not be one. The real preview then never decodes, and a placeholder
// that waits for a decode sits dead over the live overlay for the whole ceiling — with the pointer
// fix above, on top of it (#569 review).
test("a file that lies about being a photo still hands off", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)

  await alice.evaluate(() => {
    window.__seen = null
    window.__gone = null
    const t0 = performance.now()
    const tick = () => {
      const n = document.querySelectorAll(".ed-compose-skel").length
      if (n && window.__seen === null) window.__seen = performance.now() - t0
      if (window.__seen !== null && !n) {
        window.__gone = performance.now() - t0
        return
      }
      if (performance.now() - t0 < 12_000) requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.setInputFiles(MAIN_INPUT, {
    name: "not-really.png",
    mimeType: "image/png",
    buffer: Buffer.from("this is not a PNG, whatever the extension says"),
  })
  await expect(alice.locator("[data-upload-preview]")).toHaveCount(1, { timeout: 10_000 })
  await alice.waitForTimeout(1500)

  const { seen, gone } = await alice.evaluate(() => ({ seen: window.__seen, gone: window.__gone }))
  console.log(`undecodable pick: placeholder painted at ${seen && Math.round(seen)}ms, gone at ${gone && Math.round(gone)}ms`)
  expect(seen, "the placeholder never painted, so its exit proves nothing").not.toBeNull()
  expect(gone, "the placeholder waited for a decode that never comes").not.toBeNull()
  // Well inside the ten-second ceiling: the point is that it hands off on the overlay, not that it
  // eventually times out.
  expect(gone, `the placeholder sat over the real overlay for ${gone}ms`).toBeLessThan(5000)
})

// A placeholder is a promise the server has to keep. When the socket is down the pick is lost with
// the cleared input — nothing is coming, and it has to say so at once rather than sit out the
// ceiling that exists for a link which is merely slow.
test("a placeholder gives up at once when the socket is down", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await alice.waitForTimeout(600)

  await alice.evaluate(() => window.liveSocket.disconnect())

  // Watched from inside the page: it comes and goes within a frame or two of the pick, which is
  // faster than an out-of-process assertion can poll — the first version of this test read zero and
  // concluded the placeholder had never painted at all.
  await alice.evaluate(() => {
    window.__seen = null
    window.__gone = null
    const t0 = performance.now()
    const tick = () => {
      const n = document.querySelectorAll(".ed-compose-skel").length
      if (n && window.__seen === null) window.__seen = performance.now() - t0
      if (window.__seen !== null && !n) {
        window.__gone = performance.now() - t0
        return
      }
      if (performance.now() - t0 < 12_000) requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })

  await alice.setInputFiles(MAIN_INPUT, fixture("sample1.png"))
  await alice.waitForTimeout(2500)

  const { seen, gone } = await alice.evaluate(() => ({ seen: window.__seen, gone: window.__gone }))
  console.log(`offline placeholder: painted at ${seen && Math.round(seen)}ms, gone at ${gone && Math.round(gone)}ms`)
  expect(seen, "the placeholder never painted, so its exit proves nothing").not.toBeNull()
  expect(gone, "the placeholder is still on screen with the socket down").not.toBeNull()
  expect(gone, `the placeholder sat out the slow-link ceiling instead (${gone}ms)`).toBeLessThan(2000)
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
