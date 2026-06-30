const { test, expect, send } = require("../helpers/fixtures")

// #206 follow-up: the focus-suppression must use WINDOW focus, not just tab visibility.
// An alt-tab to another app leaves document.hidden = false but document.hasFocus() = false —
// the user isn't looking, so a message in the OPEN chat should still ping. We stub hasFocus()
// to false (and Web Audio, to record the chime) and assert the open chat pings.
test("an open chat still pings when the window is blurred (#206 follow-up)", async ({
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
    // Window is alt-tabbed away (no OS focus) while the tab stays "visible".
    document.hasFocus = () => false
  })

  // Alice OPENS the alice–bob DM and stays on it (the "focused" chat).
  await alice.goto(`/app/c/${seed.dm_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  // Precondition: sound on (the default; other specs restore it).
  await expect(alice.locator("#notifier")).toHaveAttribute("data-sound", "true")
  await alice.evaluate(() => window.dispatchEvent(new Event("pointerdown"))) // unlock audio
  await alice.waitForTimeout(600) // let the IdleTracker push tab_hidden (window blurred)

  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())

  const before = await alice.evaluate(() => window.__osc)
  await send(bob, `blur ping ${Date.now()}`)
  // The chat is OPEN, but the window isn't focused → not suppressed → chime.
  await expect
    .poll(() => alice.evaluate(() => window.__osc), { timeout: 8000 })
    .toBeGreaterThan(before)
})
