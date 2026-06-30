const { test, expect, send } = require("../helpers/fixtures")

// #217: the notification output splits by where your attention is.
//   • AWAY (window not focused / tab hidden) → a desktop OS notification fires (it carries its
//     own system sound), and the Web Audio chime is suppressed (no double-ding).
//   • ON THE SITE (window focused + tab visible) → the in-app chime plays instead, and NO OS
//     banner is shown (you're already looking at eden — a banner would be redundant noise).
// Real audio/OS notifications can't be asserted, so both are stubbed to record.

function stubs() {
  // Record native Notification constructions + oscillator (chime) plays.
  window.__notifs = []
  window.__osc = 0
  function StubNotification(title, opts) {
    window.__notifs.push({ title, opts })
    this.close = () => {}
  }
  StubNotification.permission = "granted"
  StubNotification.requestPermission = () => Promise.resolve("granted")
  window.Notification = StubNotification
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
}

// Turn alice's sound AND desktop notifications on, then land her on /app (not the bob DM, so the
// server still pushes the notify). Shared dev prefs, so set them explicitly each run.
async function enableBoth(alice) {
  await alice.goto("/settings")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  const sound = alice.locator('button[phx-click="set_notify_sound"]')
  if ((await sound.getAttribute("aria-checked")) === "false") await sound.click()
  const desktop = alice.locator("#notify-desktop-switch")
  if ((await desktop.getAttribute("aria-checked")) === "false") await desktop.click()
  await expect(desktop).toHaveAttribute("aria-checked", "true")

  await alice.goto("/app")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForSelector("#notifier", { state: "attached" })
  await expect(alice.locator("#notifier")).toHaveAttribute("data-desktop", "true")
  await alice.evaluate(() => window.dispatchEvent(new Event("pointerdown"))) // unlock audio
}

test("AWAY: a desktop notification fires and the chime is suppressed (#217)", async ({
  alice,
  bob,
  seed,
}) => {
  await alice.addInitScript(stubs)
  // Window is alt-tabbed away (no OS focus) while the tab stays "visible".
  await alice.addInitScript(() => (document.hasFocus = () => false))
  await enableBoth(alice)

  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())

  const msg = `desktop ${Date.now()}`
  await send(bob, msg)

  // A desktop notification was created — sender name as title, message as body, a tag for replace.
  await expect
    .poll(() => alice.evaluate(() => window.__notifs.length), { timeout: 8000 })
    .toBeGreaterThan(0)
  const notif = await alice.evaluate(() => window.__notifs[window.__notifs.length - 1])
  expect(notif.title).toContain("Bob")
  expect(notif.opts.body).toBe(msg)
  expect(notif.opts.tag).toBeTruthy()
  // The chime was suppressed because the desktop notification fired (no double-ding).
  expect(await alice.evaluate(() => window.__osc)).toBe(0)

  // Restore: turn desktop back off so other specs see the default.
  await alice.goto("/settings")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.locator("#notify-desktop-switch").click()
})

test("ON THE SITE: the chime plays and NO desktop banner is shown (#217)", async ({
  alice,
  bob,
  seed,
}) => {
  await alice.addInitScript(stubs)
  // The window is focused and the tab is visible — alice is actively on the site.
  await alice.addInitScript(() => (document.hasFocus = () => true))
  await enableBoth(alice)

  await bob.goto(`/app/c/${seed.dm_id}`)
  await bob.waitForFunction(() => window.liveSocket?.isConnected())

  const before = await alice.evaluate(() => window.__osc)
  await send(bob, `onsite ${Date.now()}`)

  // The chime plays (you're on the site)...
  await expect
    .poll(() => alice.evaluate(() => window.__osc), { timeout: 8000 })
    .toBeGreaterThan(before)
  // ...and NO OS banner was shown (it would be redundant while you're looking at eden).
  expect(await alice.evaluate(() => window.__notifs.length)).toBe(0)

  // Restore: turn desktop back off so other specs see the default.
  await alice.goto("/settings")
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.locator("#notify-desktop-switch").click()
})
