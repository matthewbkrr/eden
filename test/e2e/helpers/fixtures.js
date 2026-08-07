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
  // The menu this host owns, not "the first visible .ed-menu on the page". Since #508/#541 the
  // menus are shared page-level nodes and several exist at once (message, room, conversation,
  // folder, member); the sidebar ones sit EARLIER in the document, so `.first()` could hand back a
  // menu with no Select in it and the caller would wait out its whole timeout on an item that was
  // never going to appear. Mirrors `sharedMenuId()` in the .ContextMenu hook.
  const menuId = await messageLocator
    .evaluate((el) => {
      const host = el.closest("[phx-hook]") || el
      if (host.dataset.messageId) return "message-menu"
      if (host.dataset.room) return "room-menu"
      if (host.classList.contains("ed-convo-wrap")) return "convo-menu"
      return null
    })
    .catch(() => null)
  const menu = menuId ? page.locator(`#${menuId}`) : page.locator(".ed-menu:visible").first()
  // Everything inside toPass so a detach (the optimistic node swapping to the real row right
  // as we act) just retries and re-resolves the locator, instead of failing on a stale handle.
  await base.expect(async () => {
    await messageLocator.scrollIntoViewIfNeeded().catch(() => {})
    // The host has to be a REAL row first. A just-sent message is an optimistic clone for a beat
    // — same classes, same text, no hook and no `data-message-id` — and a `contextmenu` dispatched
    // at it lands on nothing at all. Measured: the first dispatch after a send was a no-op (the
    // menu never even flickered), the next one 250ms later opened it.
    await base
      .expect(messageLocator)
      .toHaveAttribute("data-message-id", /\d+/, { timeout: 2000 })
      .catch(() => {}) // flat rows and non-message hosts carry it elsewhere; the retry covers them
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
  // pre-connect has no phx-submit to handle and is silently dropped.
  //
  // Connected is not enough, though: the connected render REPLACES the dead-render form, and a
  // submit fired in that window goes with it. Measured — submitting the instant `isConnected()`
  // turns true, the message never arrived in ten seconds; after the composer had settled it
  // arrived in 21-47ms. The composer's own hook having run is the signal that the form on screen
  // is the live one (`edenVideoUrls` is set in .SendQueue's mounted()), and it is what nine
  // specs in this harness were silently failing on.
  await page.waitForFunction(
    () => {
      const f = document.getElementById("composer")
      return !!(window.liveSocket && window.liveSocket.isConnected() && f && f.edenVideoUrls)
    },
    null,
    { timeout: 10_000 },
  )
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
