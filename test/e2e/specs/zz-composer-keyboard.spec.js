// Composer keyboard behavior (#439): tapping Send must not steal focus from the input —
// on the phone a focus loss collapses the keyboard between every message (TG keeps it up).
// Desktop suppresses the focus steal on mousedown; touch suppresses it on touchend and
// submits the form itself — so this also guards against a double submission.
const { test, expect } = require("../helpers/fixtures")

async function connected(page) {
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 10_000 },
  )
}

test("send keeps focus in the input (and sends exactly once)", async ({ alice, seed }, testInfo) => {
  const page = alice
  const mobile = testInfo.project.name.startsWith("mobile")
  await page.goto(`/app/c/${seed.dm_id}`)
  await connected(page)

  const marker = `focuskeep-${Date.now()}`
  const input = page.locator("#composer-body")
  await input.click()
  await input.fill(marker)

  const send = page.locator('#composer button[type="submit"]')
  if (mobile) {
    await send.tap() // real touch sequence → the touchend path
  } else {
    await send.click() // mouse path: mousedown is prevented, click still submits
  }

  await expect(page.locator(`#messages :text("${marker}")`)).toBeVisible()
  // Exactly one send — the touch path suppresses the synthesized click after submitting.
  expect(await page.locator(`#messages .ed-msg:has-text("${marker}")`).count()).toBe(1)
  // Focus stayed in the input → the keyboard would stay up on a device.
  const focused = await page.evaluate(() => document.activeElement && document.activeElement.id)
  expect(focused, "input keeps focus through the send").toBe("composer-body")
})
