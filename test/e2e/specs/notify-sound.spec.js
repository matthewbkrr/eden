const { test, expect, send } = require("../helpers/fixtures")

// #215: when a gated notification (#213) lands and sound is on and the chat isn't focused,
// the .Notifier hook plays a chime. Real audio can't be asserted, so Web Audio is stubbed to
// record oscillator creations; we assert one happens.
test("a notification chimes when sound is on and the chat isn't focused (#215)", async ({
  alice,
  bob,
  seed,
}) => {
  await alice.addInitScript(() => {
    window.__osc = 0
    class StubCtx {
      constructor() {
        this.state = "running"
        this.currentTime = 0
        this.destination = {}
      }
      resume() {
        this.state = "running"
        return Promise.resolve()
      }
      createGain() {
        return { connect() {}, gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} } }
      }
      createOscillator() {
        window.__osc++
        return { frequency: { setValueAtTime() {} }, connect() {}, start() {}, stop() {} }
      }
    }
    window.AudioContext = StubCtx
    window.webkitAudioContext = StubCtx
  })

  // Notification prefs are shared dev state — make sure alice's sound is ON first.
  await alice.goto("/settings")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const toggle = alice.locator('button[phx-click="set_notify_sound"]')
  if ((await toggle.getAttribute("aria-checked")) === "false") await toggle.click()
  await expect(toggle).toHaveAttribute("aria-checked", "true")

  // Alice is on the chat list, NOT viewing the alice–bob DM (so it isn't focused).
  await alice.goto("/app")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForSelector("#notifier", { state: "attached" })
  await expect(alice.locator("#notifier")).toHaveAttribute("data-sound", "true")
  // The hook unlocks the audio context on the first interaction.
  await alice.evaluate(() => window.dispatchEvent(new Event("pointerdown")))

  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())

  const before = await alice.evaluate(() => window.__osc)
  await send(bob, `chime ${Date.now()}`)
  await expect
    .poll(() => alice.evaluate(() => window.__osc), { timeout: 8000 })
    .toBeGreaterThan(before)
})

// #215 resume fix: the browser auto-suspends the AudioContext after a spell in the background,
// so chime() must resume() it (no fresh gesture needed once unlocked) before playing — otherwise
// a notification stays silent while you're in another app.
test("a suspended audio context is resumed so a backgrounded notification still chimes (#215)", async ({
  alice,
  bob,
  seed,
}) => {
  await alice.addInitScript(() => {
    window.__osc = 0
    class StubCtx {
      constructor() {
        this.state = "running"
        this.currentTime = 0
        this.destination = {}
      }
      resume() {
        this.state = "running" // resume wakes it without a gesture
        return Promise.resolve()
      }
      createGain() {
        return { connect() {}, gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} } }
      }
      createOscillator() {
        window.__osc++
        return { frequency: { setValueAtTime() {} }, connect() {}, start() {}, stop() {} }
      }
    }
    window.AudioContext = StubCtx
    window.webkitAudioContext = StubCtx
  })

  // Sound on (independent of the first test).
  await alice.goto("/settings")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const toggle = alice.locator('button[phx-click="set_notify_sound"]')
  if ((await toggle.getAttribute("aria-checked")) === "false") await toggle.click()
  await expect(toggle).toHaveAttribute("aria-checked", "true")

  await alice.goto("/app")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForSelector("#notifier", { state: "attached" })
  await alice.evaluate(() => window.dispatchEvent(new Event("pointerdown"))) // unlock → running
  // The browser auto-suspended the context while we were backgrounded.
  await alice.evaluate(() => (window.__edAudio.state = "suspended"))

  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())

  const before = await alice.evaluate(() => window.__osc)
  await send(bob, `resume ${Date.now()}`)
  // chime() resume()s the suspended context, then plays.
  await expect
    .poll(() => alice.evaluate(() => window.__osc), { timeout: 8000 })
    .toBeGreaterThan(before)
})
