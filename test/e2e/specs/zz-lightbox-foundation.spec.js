// Lightbox foundation (#465/#469, impeccable audit P1s): native <dialog> semantics
// (trap + focus return), the album counter, and zoom. These lock the audit fixes.
const { test, expect, ready } = require("../helpers/fixtures")

async function openAlbum(page, seed) {
  // Deep-link to the SEEDED three-photo album. This used to page backwards through the dialog
  // looking for any `.ed-photo` and click the last one — in a stand the rest of the harness has
  // been writing to all day, that is whatever copy some other spec dropped in most recently,
  // usually a single photo. Hence an empty album counter and a missing alt: the tests were
  // measuring a different message every run (#588).
  expect(seed.album_msg_id, "the seed no longer carries album_msg_id").toBeTruthy()
  await page.goto(`/app/c/${seed.dm_id}/m/${seed.album_msg_id}`)
  await ready(page)
  const tile = page.locator(`#messages-${seed.album_msg_id} a.ed-photo`).first()
  await expect(tile).toBeVisible({ timeout: 12_000 })
  await tile.click()
  await page.waitForSelector("dialog#ed-lightbox[open]", { timeout: 5000 })

  // Wait for the reel reply to LAND, not for two counter samples to agree. The viewer opens
  // album-scoped ("1 of 3") and re-anchors to the conversation-wide gallery when the
  // `lightbox_media` reply arrives ~300 ms later, which rewrites the counter. The first version
  // of this settle sampled 150 ms apart and returned on its first pair — i.e. before the very
  // event it was named for — so every measurement below was still taken pre-hydration (#588
  // review). `__loading` is set true at open and false the moment the reply is handled, which is
  // the event itself rather than a proxy for it.
  await page.waitForFunction(() => document.getElementById("ed-lightbox").__loading === false, null, {
    timeout: 8000,
  })

  return tile
}

test("dialog semantics: focus moves in, Tab stays in, Esc returns focus", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "keyboard flow")
  const page = alice
  const tile = await openAlbum(page, seed)

  const state = await page.evaluate(() => {
    const d = document.getElementById("ed-lightbox")
    return {
      tag: d.tagName,
      open: d.open,
      label: d.getAttribute("aria-label"),
      focusInside: !!document.activeElement?.closest("#ed-lightbox"),
      // The CURRENT slide. The viewer is a three-slide carousel since #470 and the neighbours are
      // deliberately alt="" (and src-less) until they become current, so a bare
      // `.ed-lightbox__img` reads the previous slide and its empty alt (#588).
      alt: d.querySelector(".ed-lightbox__slide--cur .ed-lightbox__img").getAttribute("alt"),
    }
  })
  expect(state.tag).toBe("DIALOG")
  expect(state.open).toBe(true)
  expect(state.label).toBeTruthy()
  expect(state.focusInside, "focus moved into the dialog").toBe(true)
  expect(state.alt, "img carries an accessible alt").toBeTruthy()

  for (let k = 0; k < 5; k++) await page.keyboard.press("Tab")
  const trapped = await page.evaluate(() => !!document.activeElement?.closest("#ed-lightbox"))
  expect(trapped, "Tab never escapes the modal").toBe(true)

  await page.keyboard.press("Escape")
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(0, { timeout: 3000 })
  const returned = await page.evaluate(() => document.activeElement?.className || "")
  expect(returned, "focus returned to the opening tile").toContain("ed-photo")
  void tile
})

test("album counter shows and tracks paging", async ({ alice, seed }, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "arrow paging is desktop")
  const page = alice
  await openAlbum(page, seed)
  const count = page.locator(".ed-lightbox__count")
  await expect(count).toBeVisible()
  // "N of M", whatever M is: the viewer opens album-scoped and then hydrates to the whole
  // conversation's gallery, so pinning M to the album's 3 is pinning a state that lives ~300 ms
  // (#588). What the counter must do is EXIST and TRACK paging.
  const first = (await count.textContent()).trim()
  expect(first).toMatch(/^\d+ \S+ \d+$/)

  // The index, not just "the text changed". Hydration rewrites this counter all by itself, so a
  // `not.toHaveText(first)` assertion was satisfied by the reel arriving and stayed green with
  // arrow paging deleted from the product — verified by mutation (#588 review). Asking the viewer
  // where it is, and requiring exactly one step, is something hydration cannot forge.
  const at = () => page.evaluate(() => document.getElementById("ed-lightbox").__index())
  const before = await at()
  await page.keyboard.press("ArrowRight")
  await expect.poll(at, { message: "ArrowRight did not move the viewer", timeout: 3000 }).toBe(before + 1)
  await expect(count).not.toHaveText(first)
  await expect(count).toHaveText(/^\d+ \S+ \d+$/)
})

test("zoom: dblclick toggles scale, paging resets it", async ({ alice, seed }, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "dblclick flow")
  const page = alice
  await openAlbum(page, seed)
  const img = page.locator(".ed-lightbox__slide--cur img")
  await img.dblclick()
  await page.waitForTimeout(250)
  const zoomed = await page.evaluate(() => ({
    tf: getComputedStyle(document.querySelector(".ed-lightbox__slide--cur img")).transform,
    cls: document.getElementById("ed-lightbox").className,
  }))
  expect(zoomed.tf, "transform applied").not.toBe("none")
  expect(zoomed.cls).toContain("ed-lightbox--zoomed")

  await page.keyboard.press("ArrowRight")
  await page.waitForTimeout(150)
  const reset = await page.evaluate(
    () => getComputedStyle(document.querySelector(".ed-lightbox__slide--cur img")).transform,
  )
  expect(reset, "paging resets zoom").toBe("none")
  await page.keyboard.press("Escape")
})

test("mobile: counter is the album signal; swipe-down still closes", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(!testInfo.project.name.startsWith("mobile"), "touch flow")
  const page = alice
  await openAlbum(page, seed)
  await expect(page.locator(".ed-lightbox__count")).toBeVisible()
  const touch = (type, x, y) =>
    page.dispatchEvent("#ed-lightbox", type, {
      touches: type === "touchend" ? [] : [{ identifier: 1, clientX: x, clientY: y }],
      changedTouches: [{ identifier: 1, clientX: x, clientY: y }],
      targetTouches: type === "touchend" ? [] : [{ identifier: 1, clientX: x, clientY: y }],
    })
  await touch("touchstart", 200, 300)
  await touch("touchend", 205, 420)
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(0, { timeout: 3000 })
})

// ---- Wave B chrome (#465): the TG-style bar, the action menu, paging motion.

test("chrome: who/when/counter render and the menu offers the message actions", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await openAlbum(page, seed)

  await expect(page.locator(".ed-lightbox__who")).not.toBeEmpty()
  await expect(page.locator(".ed-lightbox__when")).not.toBeEmpty()
  await expect(page.locator(".ed-lightbox__count")).toBeVisible()
  // The bar sits inside the safe area — the old floating X hid under the notch.
  const barTop = await page.evaluate(
    () => Math.round(document.querySelector(".ed-lightbox__bar").getBoundingClientRect().top),
  )
  expect(barTop).toBe(0)

  await page.locator(".ed-lightbox__more").click()
  const items = page.locator(".ed-lightbox__item:visible")
  await expect(items).toHaveCount(6) // own photo → delete-for-everyone included
  await expect(page.locator('[data-act="show"]')).toBeVisible()
  await expect(page.locator('[data-act="save"]')).toBeVisible()
  await expect(page.locator('[data-act="del-all"]')).toBeVisible()

  // A click on the backdrop closes the MENU first, not the viewer.
  await page.mouse.click(5, 400)
  await expect(page.locator(".ed-lightbox__menu")).toBeHidden()
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(1)
  await page.keyboard.press("Escape")
})

test("the back arrow closes the viewer (the bar guard must not swallow it)", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await openAlbum(page, seed)
  // #472 review caught this dead: the "clicks on the bar don't close" guard ran
  // BEFORE the back-arrow check, and no spec had ever clicked the arrow.
  await page.locator(".ed-lightbox__close").click()
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(0, { timeout: 3000 })
})

test("a click on the bar's empty space does NOT close the viewer", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await openAlbum(page, seed)
  await page.locator(".ed-lightbox__title").click()
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(1)
  await page.keyboard.press("Escape")
})

test("menu action reaches the server: Reply opens the reply bar", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await openAlbum(page, seed)
  await page.locator(".ed-lightbox__more").click()
  // Scoped to the viewer's own menu: the shared #message-menu carries the same `data-act`, so an
  // unscoped locator is a strict-mode violation rather than a click (#588).
  await page.locator('#ed-lightbox [data-act="reply"]').click()
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(0, { timeout: 3000 })
  // The composer's reply bar is the server's answer to the pushed event.
  await expect(page.locator("#composer [data-reply-bar], #composer .ed-reply-bar")).toBeVisible({
    timeout: 5000,
  })
})

test("Show in chat closes the viewer and highlights the message", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await openAlbum(page, seed)
  const msgId = await page.evaluate(() => document.getElementById("ed-lightbox").__meta.msg)
  const row = page.locator(`#messages-${msgId}`)

  // Clear the deck first. openAlbum arrives by PERMALINK, and that route highlights its target
  // row for --ed-hold-focus (2.2 s) all on its own — the same row and the same class this test
  // asserts, because every photo of the album belongs to one message. Measured by mutation:
  // with "Show in chat" reduced to just closing the viewer, the test still passed on the
  // leftover highlight (#588 review). Waiting it out is what makes the assertion below evidence.
  await expect(row, "the permalink highlight never expired").not.toHaveClass(/ed-msg--focus/, {
    timeout: 6000,
  })

  await page.locator(".ed-lightbox__more").click()
  await page.locator('#ed-lightbox [data-act="show"]').click()
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(0, { timeout: 3000 })
  await expect(row).toHaveClass(/ed-msg--focus/, { timeout: 3000 })
})

// FAILING, and left failing on purpose (#588). Measured on this stand: opening the seeded album
// shows "1 of 3", then the reel hydrates to the conversation-wide gallery ("1778 of 1780") within
// ~300 ms; ArrowRight after that does move the index (1778 -> 1779) but fires no `transitionstart`
// on the track at all, so the frame swaps dead — which is the exact complaint #465 set out to fix.
// It was red before this branch too, so it is not spec rot from the seeded album: either paging a
// large reel genuinely lost its animation, or the animation is conditional in a way nothing states.
// Answering that is a product question, not a locator fix, so it gets its own issue rather than a
// green-looking edit here. Tracked as #589.
test.fixme("paging animates the frame instead of swapping it dead", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(testInfo.project.name.startsWith("mobile"), "one project is enough")
  const page = alice
  await openAlbum(page, seed)
  // Proof of MOTION, not of a style string: paging must travel the carousel TRACK.
  // The first attempt animated the frame 18px behind the decode-hide — invisible in
  // practice ("картинки резко меняются"), which a style-string assert never caught.
  await page.evaluate(() => {
    window.__moved = []
    document
      .querySelector(".ed-lightbox__track")
      .addEventListener("transitionstart", (e) => window.__moved.push(e.propertyName))
  })
  // Direction is arbitrary here — the reel hydrates to a mid-list index, so either arrow moves.
  // (An earlier draft of this comment claimed ArrowLeft had nowhere to go, which was wrong: that
  // is only true for the album-scoped moment before hydration. #588 review caught it.)
  await page.keyboard.press("ArrowRight")
  await page.waitForFunction(() => window.__moved?.includes("transform"), null, { timeout: 2000 })
  await page.waitForTimeout(420)
  const settled = await page.evaluate(
    () => document.querySelector(".ed-lightbox__track").style.transition,
  )
  expect(settled, "the track stops animating once it settles").toBe("none")
  await page.keyboard.press("Escape")
})
