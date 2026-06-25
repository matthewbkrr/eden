// #153: the login form is server-rendered and interactive before the LiveView socket
// connects. Without phx-update="ignore", the connect re-render patches the (empty) form
// and intermittently WIPES what was typed pre-connect (a race — the audit hit it on every
// engine; global-setup.js works around it by waiting for connect before filling). With the
// guard the form is never patched, so pre-connect input always survives. Looped because the
// wipe is a race: a single un-guarded run can survive by luck, three rarely all do.
const { test, expect } = require("../helpers/fixtures")

test("login keeps credentials typed before the socket connects (#153)", async ({
  browser,
  seed,
}) => {
  const base = seed.base_url || "http://localhost:4001"

  for (let i = 0; i < 3; i++) {
    const ctx = await browser.newContext() // unauthenticated → /login renders
    const page = await ctx.newPage()
    await page.goto(base + "/login")
    await page.locator("#user_username").waitFor({ state: "visible" })
    // Type IMMEDIATELY, racing the connect — the moment that used to wipe the inputs.
    await page.fill("#user_username", "typed_user")
    await page.fill("#user_password", "typed_pass")
    await page.waitForFunction(() => window.liveSocket?.isConnected())
    await page.waitForTimeout(500)

    const vals = await page.evaluate(() => ({
      u: document.querySelector("#user_username")?.value,
      p: document.querySelector("#user_password")?.value,
    }))
    expect(vals, `run ${i}: input survived the connect`).toEqual({ u: "typed_user", p: "typed_pass" })
    await ctx.close()
  }
})
