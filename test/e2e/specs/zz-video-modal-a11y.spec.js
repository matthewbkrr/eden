// The full-screen video overlay is a modal (#365/R068).
//
// It used to be a plain `<div>` with hand-rolled Escape and click handlers: no role, no modal
// semantics, and Tab walked straight out of it into the chat behind — a keyboard user could focus
// and activate a message they could not see, and closing left focus wherever it had wandered. It
// is a native `<dialog>` now, so the trap, the top layer, focus return and Escape come from the
// platform. What that buys is only real if something checks it.
const { test, expect } = require("../helpers/fixtures")
const path = require("path")
const { execFileSync } = require("child_process")
const fs = require("fs")
const os = require("os")

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

// A one-second test pattern, made here rather than committed: a binary fixture in the repo for a
// test that needs any valid mp4 is a file nobody can review.
function tinyVideo() {
  const file = path.join(os.tmpdir(), `eden-e2e-tiny-${process.pid}.mp4`)

  if (!fs.existsSync(file)) {
    execFileSync("ffmpeg", [
      "-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10",
      "-pix_fmt", "yuv420p", "-y", file,
    ])
  }

  return file
}

test("the video overlay is a modal dialog, and gives focus back when it closes", async ({
  alice,
  seed,
}) => {
  test.setTimeout(180_000)
  test.skip(!hasFfmpeg(), "needs ffmpeg to make the clip")

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)

  await alice.locator('#composer input[name="attachment"]').setInputFiles(tinyVideo())
  await expect(alice.locator("[data-upload-preview]")).toBeVisible()
  await alice.locator('[data-upload-preview] button[type="submit"]').click()

  const poster = alice.locator(".ed-video-box").last()
  await expect(poster, "the video never arrived in the stream").toBeVisible({ timeout: 60_000 })

  await poster.click()

  const overlay = alice.locator("#ed-video-modal")
  await expect(overlay).toBeVisible()

  // The page behind must not scroll. A top-layer dialog covers it but does not lock it, and the
  // lock lives in our code — exactly the line that vanished when hand-rolled listeners gave way to
  // showModal() (#585 review).
  expect(
    await alice.evaluate(() => document.body.style.overflow),
    "the chat behind the overlay can still be scrolled",
  ).toBe("hidden")

  const state = await alice.evaluate(() => {
    const box = document.getElementById("ed-video-modal")

    return {
      tag: box.tagName,
      open: box.open === true,
      label: box.getAttribute("aria-label"),
      focusInside: box.contains(document.activeElement),
    }
  })

  // `<dialog>` + `showModal()` is what carries the modal semantics: a bare div announces nothing
  // and traps nothing, however many listeners it has.
  expect(state.tag, "the overlay is not a dialog element").toBe("DIALOG")
  expect(state.open, "the dialog was not opened modally — no top layer, no focus trap").toBe(true)
  expect(state.label, "the dialog has no accessible name").toBeTruthy()
  expect(state.focusInside, "focus stayed outside the open dialog").toBe(true)

  // Escape is the platform's now, not a document-level keydown listener of ours.
  await alice.keyboard.press("Escape")
  await expect(overlay).toBeHidden()

  // Back on the thing that opened it, not merely "somewhere outside": focus landing on <body> is
  // exactly the lost-context this change exists to prevent, and it would satisfy a weaker
  // assertion (#585 review).
  expect(
    await alice.evaluate(() => document.activeElement?.closest?.(".ed-video-box") !== null),
    "focus did not return to the video that opened the overlay",
  ).toBe(true)

  expect(
    await alice.evaluate(() => document.body.style.overflow),
    "the scroll lock outlived the overlay — the page behind stays frozen",
  ).toBe("")

  // ...and the clip stops. A closed overlay that keeps playing audio is the bug the close handler
  // exists for, and moving that handler onto the dialog's own `close` event is exactly the kind of
  // change that can silently drop it.
  // Polled: the dialog hides the moment `close()` runs, while the handler that stops the clip is
  // an event listener on it — asserting immediately raced the product rather than testing it
  // (#585 review).
  await expect
    .poll(
      () =>
        alice.evaluate(() => {
          const v = document.querySelector("#ed-video-modal .ed-video-modal__player")
          return v.paused && !v.getAttribute("src")
        }),
      { message: "the video kept playing after the overlay closed", timeout: 5000 },
    )
    .toBe(true)
})

function hasFfmpeg() {
  try {
    execFileSync("ffmpeg", ["-version"], { stdio: "ignore" })
    return true
  } catch {
    return false
  }
}
