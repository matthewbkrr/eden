// What typing costs the socket (#521 tail).
//
// #521 claimed the composer sends an event per character. It does not: the input carries
// `phx-debounce="250"`, and twenty-five characters cost one event. This file exists to keep it
// that way — the debounce is a single attribute, and losing it is silent.
const { test, expect } = require("../helpers/fixtures")

test("typing does not send a message per character", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000)

  await alice.addInitScript(() => {
    window.__pushes = 0
    const orig = WebSocket.prototype.send
    WebSocket.prototype.send = function (data) {
      if (typeof data === "string" && data.includes("composer_changed")) window.__pushes++
      return orig.call(this, data)
    }
  })

  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(600)

  const input = alice.locator("#composer-body")
  await input.click()
  await alice.evaluate(() => (window.__pushes = 0))

  const text = `hello there ${Date.now()}`
  // `pressSequentially`, not the deprecated `type` (#568 review).
  await input.pressSequentially(text, { delay: 45 })
  await alice.waitForTimeout(700)

  const pushes = await alice.evaluate(() => window.__pushes)
  const line = `${text.length} characters -> ${pushes} composer_changed events`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  // A bound tied to the debounce, not to the length of the word (#568 review): `< text.length`
  // still passes at one event short of per-character, which is the very thing being guarded
  // against. Typing at 45ms/char through a 250ms debounce settles at one or two events; five is
  // room for a slow stand, and nowhere near per-character.
  expect(pushes, `${line} — the composer is sending per keystroke again`).toBeLessThanOrEqual(5)

  // ...and the server has to hold the WHOLE string, not just the last batch. Counting events alone
  // would pass on a debounce that drops characters — the comment here used to claim this check and
  // the code did not make it (#568 review). Sending is the proof: the message that arrives is what
  // was typed.
  await alice.keyboard.press("Enter")
  await expect(
    alice.locator("#messages", { hasText: text }),
    "the server did not receive everything that was typed",
  ).toBeVisible({ timeout: 10_000 })
})
