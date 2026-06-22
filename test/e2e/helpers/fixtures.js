// Custom test fixtures for the eden audit.
//
// Each of `alice` / `bob` / `carol` is a Page in its OWN browser context loaded from that
// user's saved session — so a single test can drive several simultaneous users and watch
// realtime delivery (one sends, another sees it live). Every page collects console errors
// + uncaught page errors + 4xx/5xx responses into arrays you can assert on or dump to the
// audit. `shot()` writes organized screenshots under artifacts/<project>/.
const base = require("@playwright/test")
const fs = require("fs")
const path = require("path")

const seed = JSON.parse(fs.readFileSync(path.join(__dirname, "..", ".seed.json"), "utf8"))
const authPath = (key) => path.join(__dirname, "..", ".auth", `${key}.json`)
const artifactsRoot = path.join(__dirname, "..", "artifacts")

function attachDiagnostics(page, label) {
  const diag = { consoleErrors: [], pageErrors: [], badResponses: [] }
  page.on("console", (msg) => {
    if (msg.type() === "error") diag.consoleErrors.push(`[${label}] ${msg.text()}`)
  })
  page.on("pageerror", (err) => diag.pageErrors.push(`[${label}] ${err.message}`))
  page.on("response", (res) => {
    const s = res.status()
    // /healthz and websocket upgrades aside, flag real 4xx/5xx on app requests.
    if (s >= 400 && !res.url().includes("/healthz")) {
      diag.badResponses.push(`[${label}] ${s} ${res.request().method()} ${res.url()}`)
    }
  })
  page.__diag = diag
  return diag
}

async function userPage(browser, key, use) {
  const ctx = await browser.newContext({ storageState: authPath(key) })
  const page = await ctx.newPage()
  attachDiagnostics(page, key)
  // Always accept data-confirm dialogs (delete chat/folder/message) — registering per-test
  // raced the dialog on some engines. .catch swallows "already handled" if a test also acts.
  page.on("dialog", (d) => d.accept().catch(() => {}))
  await use(page)
  await ctx.close()
}

const test = base.test.extend({
  seed: async ({}, use) => use(seed),
  alice: async ({ browser }, use) => userPage(browser, "alice", use),
  bob: async ({ browser }, use) => userPage(browser, "bob", use),
  carol: async ({ browser }, use) => userPage(browser, "carol", use),
})

// Open a message's Telegram-style context menu and return the OPEN menu locator. The
// .ContextMenu hook listens to `contextmenu`, so dispatching it works on any project
// (desktop right-click / mobile long-press alike). Retries because a just-streamed-in
// message's hook can attach a beat after paint. Every message renders its own hidden
// .ed-menu, so the returned locator is scoped to the visible one.
async function openMenu(page, messageLocator) {
  const menu = page.locator(".ed-menu:visible").first()
  // Everything inside toPass so a detach (the optimistic node swapping to the real row right
  // as we act) just retries and re-resolves the locator, instead of failing on a stale handle.
  await base.expect(async () => {
    await messageLocator.scrollIntoViewIfNeeded().catch(() => {})
    await messageLocator.dispatchEvent("contextmenu", { bubbles: true })
    await base.expect(menu).toBeVisible({ timeout: 700 })
  }).toPass({ timeout: 12_000 })
  return menu
}

// Fill the composer and submit it. Uses requestSubmit on the form so it fires phx-submit
// (and the SendQueue hook's submit handler) deterministically — independent of Enter-key
// focus/timing quirks that differ between the bubble and flat composers.
async function send(page, text) {
  // The composer can be visible before the LiveView socket connects; a submit fired
  // pre-connect has no phx-submit to handle and is silently dropped. Wait for connect.
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 10_000,
  })
  await page.fill("#composer-body", text)
  await page.locator("#composer").evaluate((f) => f.requestSubmit())
}

// Screenshot helper: artifacts/<project>/<NN-name>.png, full page.
async function shot(page, testInfo, name) {
  const dir = path.join(artifactsRoot, testInfo.project.name)
  fs.mkdirSync(dir, { recursive: true })
  const safe = name.replace(/[^a-z0-9._-]+/gi, "-")
  await page.screenshot({ path: path.join(dir, `${safe}.png`), fullPage: false })
}

// Collect all diagnostics across a set of pages (for the audit assertions / report).
function allDiagnostics(...pages) {
  return pages.reduce(
    (acc, p) => {
      const d = p.__diag || { consoleErrors: [], pageErrors: [], badResponses: [] }
      acc.consoleErrors.push(...d.consoleErrors)
      acc.pageErrors.push(...d.pageErrors)
      acc.badResponses.push(...d.badResponses)
      return acc
    },
    { consoleErrors: [], pageErrors: [], badResponses: [] }
  )
}

module.exports = { test, expect: base.expect, seed, shot, send, openMenu, allDiagnostics, artifactsRoot }
