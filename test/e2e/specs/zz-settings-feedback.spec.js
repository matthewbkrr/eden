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

  // Read once, immediately: the point is what the button looks like BEFORE the answer.
  const during = await alice.evaluate(() => {
    const btn = [...document.querySelectorAll('button[type="submit"]')].find((b) =>
      /Save|Сохранить/.test(b.textContent),
    )
    btn.click()
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
