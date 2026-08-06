// What typing costs the socket (#521 tail).
//
// The composer form is `phx-change="composer_changed"` with no debounce, so every character is a
// message to the server — and the server echoes `value` back into the input it came from.
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

  const text = "hello there"
  await input.type(text, { delay: 45 })
  await alice.waitForTimeout(700)

  const pushes = await alice.evaluate(() => window.__pushes)
  const line = `${text.length} characters -> ${pushes} composer_changed events`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  await input.fill("")

  // The composer has to keep working: what the server holds must match what was typed.
  expect(pushes, `${line} — one round trip per keystroke`).toBeLessThan(text.length)
})
