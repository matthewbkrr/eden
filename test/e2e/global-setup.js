// Logs each seeded user in once and saves their session cookie as a storageState file,
// so every project/test reuses it (the Phoenix session cookie is signed server-side, so
// it's browser-agnostic — a Chromium login works in WebKit/Firefox contexts too).
const { chromium } = require("@playwright/test")
const fs = require("fs")
const path = require("path")

module.exports = async () => {
  const seedPath = path.join(__dirname, ".seed.json")
  if (!fs.existsSync(seedPath)) {
    throw new Error("test/e2e/.seed.json missing — run `mix run test/e2e/seed.exs` first.")
  }
  const seed = JSON.parse(fs.readFileSync(seedPath, "utf8"))
  const authDir = path.join(__dirname, ".auth")
  fs.mkdirSync(authDir, { recursive: true })

  const browser = await chromium.launch()
  try {
    // Reuse a recent session instead of logging in every run. The signed-out credential POST
    // is rate limited (#236: 10 per 5 minutes per IP) and this loop spends three of them per
    // run, so a few runs in a row started failing at login — the harness was throttling
    // itself. Session tokens outlive this window by a wide margin; E2E_FRESH_AUTH=1 forces
    // the old behaviour when a test genuinely needs a brand-new session.
    const MAX_AGE_MS = 60 * 60 * 1000
    for (const key of Object.keys(seed.users)) {
      const statePath = path.join(authDir, `${key}.json`)
      if (
        process.env.E2E_FRESH_AUTH !== "1" &&
        fs.existsSync(statePath) &&
        Date.now() - fs.statSync(statePath).mtimeMs < MAX_AGE_MS
      ) {
        continue
      }
      const user = seed.users[key]
      const ctx = await browser.newContext()
      const page = await ctx.newPage()
      await page.goto(seed.base_url + "/login")
      await page.locator("#user_username").waitFor({ state: "visible" })
      // LoginLive re-renders the (empty) form on socket connect, which WIPES pre-connect
      // input — so wait for connect FIRST, then fill, then submit immediately.
      await page.waitForTimeout(1200)
      await page.fill("#user_username", user.username)
      await page.fill("#user_password", seed.password)
      await Promise.all([
        page.waitForURL("**/app**", { timeout: 15_000 }),
        page.evaluate(() => document.querySelector("#user_username").form.requestSubmit()),
      ])
      await ctx.storageState({ path: path.join(authDir, `${key}.json`) })
      await ctx.close()
      console.log(`  ✓ authed ${key} (${user.username})`)
    }
  } finally {
    await browser.close()
  }
}
