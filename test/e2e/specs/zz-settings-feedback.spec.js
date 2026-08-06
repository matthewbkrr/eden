// A save button that looks dead for the whole round trip (#521 tail).
//
// `phx-disable-with` existed in three places across the project and none of them were the Save
// buttons in Settings: a tap there left the button unchanged until the server answered, which on a
// slow link reads as "nothing happened" and invites a second tap.
const { test, expect } = require("../helpers/fixtures")

test("saving a profile shows the button working", async ({ alice }, testInfo) => {
  test.setTimeout(120_000)

  await alice.goto("/app/settings")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const save = alice.locator('button[type="submit"]', { hasText: /Save|Сохранить/ }).first()
  await expect(save).toBeVisible()

  await alice.evaluate(() => window.liveSocket.enableLatencySim(600))

  // Read while the request is still in flight — but polled, not snapped in the same tick as the
  // click (#568 review): whether `phx-disable-with` lands before the handler returns is LiveView's
  // business, and a test that assumes it is testing that instead of the button. The window is a
  // fraction of the simulated latency, so "before the server answered" still holds.
  const during = await alice.evaluate(async () => {
    const btn = [...document.querySelectorAll('button[type="submit"]')].find((b) =>
      /Save|Сохранить/.test(b.textContent),
    )
    btn.click()
    const until = performance.now() + 200
    while (!btn.disabled && performance.now() < until) {
      await new Promise((r) => requestAnimationFrame(r))
    }
    return { disabled: btn.disabled, text: btn.textContent.trim() }
  })
  console.log(`while saving: disabled=${during.disabled}, label="${during.text}"`)
  testInfo.annotations.push({
    type: "measurement",
    description: `while saving: disabled=${during.disabled}, label="${during.text}"`,
  })

  await alice.evaluate(() => window.liveSocket.disableLatencySim())

  expect(during.disabled, "the save button stayed live while the request was in flight").toBe(true)
  expect(during.text, "the button said nothing about being busy").toMatch(/\.\.\.|…/)
})
