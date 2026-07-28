// Lightbox foundation (#465/#469, impeccable audit P1s): native <dialog> semantics
// (trap + focus return), the album counter, and zoom. These lock the audit fixes.
const { test, expect } = require("../helpers/fixtures")

async function openAlbum(page, seed) {
  await page.goto(`/app/c/${seed.dm_id}`)
  await page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  const tile = page.locator("#messages a.ed-photo").last()
  await tile.click()
  await page.waitForSelector("dialog#ed-lightbox[open]", { timeout: 5000 })
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
      alt: d.querySelector(".ed-lightbox__img").getAttribute("alt"),
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
  // openAlbum clicks the album's LAST tile, so entry lands on 3-of-3 — assert the
  // format, then that paging moves the number (wraps to 1).
  const first = (await count.textContent()).trim()
  expect(first).toMatch(/^\d \S+ 3$/)
  await page.keyboard.press("ArrowRight")
  await expect(count).not.toHaveText(first, { timeout: 3000 })
  await expect(count).toHaveText(/^\d \S+ 3$/)
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
  await page.locator('[data-act="reply"]').click()
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
  await page.locator(".ed-lightbox__more").click()
  await page.locator('[data-act="show"]').click()
  await expect(page.locator("dialog#ed-lightbox[open]")).toHaveCount(0, { timeout: 3000 })
  await expect(page.locator(`#messages-${msgId}`)).toHaveClass(/ed-msg--focus/, { timeout: 3000 })
})

test("paging animates the frame instead of swapping it dead", async ({
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
  await page.keyboard.press("ArrowLeft")
  await page.waitForFunction(() => window.__moved?.includes("transform"), null, { timeout: 2000 })
  await page.waitForTimeout(420)
  const settled = await page.evaluate(
    () => document.querySelector(".ed-lightbox__track").style.transition,
  )
  expect(settled, "the track stops animating once it settles").toBe("none")
  await page.keyboard.press("Escape")
})
