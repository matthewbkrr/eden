// What a signed-out page downloads (#511, part of epic #506).
//
// Login, the 2FA challenge and invite acceptance render a form. They were loading the entire chat
// client to do it — 80 KB gzip of lightbox, upload queue, instant navigation, message cache and
// 39 other hooks with no host on the page. They now load a bundle with the LiveView runtime and
// the two hooks such a page actually uses: 44.5 KB gzip.
//
// Splitting a bundle is easy to get subtly wrong in a way nothing notices: the page still renders,
// the socket still connects, and a hook that quietly failed to register only shows up when someone
// taps the thing it powers. So this checks both halves — which file arrives, and that the moved
// hook still works.
const { test, expect } = require("../helpers/fixtures")

const scriptsFor = async (page, url) => {
  const seen = []
  const errors = []
  page.on("response", (r) => {
    // Take the file name first, then require it to BE a .js — an unanchored match on the URL also
    // accepts `app.js.map`, which would put "app.js.map" in `seen` and let a genuine leak through
    // the `not.toContain("app.js")` assertion below. No source maps are built today; the point is
    // that this assertion should not depend on that staying true (#542 review).
    const file = r.url().split("/").pop().split("?")[0]
    if (r.url().includes("/assets/js/") && /^[^/]+\.js$/.test(file)) seen.push(file)
  })
  page.on("console", (m) => m.type() === "error" && errors.push(m.text().slice(0, 200)))
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)))
  await page.goto(url)
  await page.waitForFunction(() => window.liveSocket?.isConnected())
  return { seen, errors }
}

test("a signed-out page loads the small bundle, the app loads the full one", async ({
  browser,
  alice,
}, testInfo) => {
  const anon = await browser.newPage()
  const login = await scriptsFor(anon, "http://localhost:4001/login")

  expect(login.seen, `login pulled ${JSON.stringify(login.seen)}`).toContain("auth.js")
  expect(login.seen, "the login page is still pulling the chat client").not.toContain("app.js")

  // An unregistered hook is a console error, not a crash — the page would look fine.
  expect(login.errors, `console errors on /login: ${JSON.stringify(login.errors)}`).toEqual([])

  // What the split means, asserted directly: the login bundle carries none of the chat client.
  //
  // This used to be a size ratio (`auth < app * 0.75`) and it went red for the WRONG reason —
  // measured: #511 moved thirty hooks out of app.js into lazy.js (213 KB), so app.js SHRANK, and
  // the ratio rose 0.51 -> 0.75. Both bundles are dominated by the shared LiveView runtime
  // (auth.js is 345 KB of which the chat hooks are 0), so the ratio tends to 1 the better the
  // split gets: the guard punished the improvement it exists to protect. Its comment claimed the
  // hooks were 46% of the bundle; they are 24.7% (#588).
  const bundles = await anon.evaluate(async () => {
    const get = async (p) => (await (await fetch(p)).text()).length
    const auth = await (await fetch("/assets/js/auth.js")).text()
    return {
      auth: auth.length,
      app: await get("/assets/js/app.js"),
      // Named hooks, not a byte count: this is what "the chat client is not here" means, and it
      // cannot drift with the size of the runtime both bundles share.
      leaked: ["ContextMenu", "SendQueue", "Lightbox", "InstantNav", "ReactionGrid"].filter((h) =>
        auth.includes(h),
      ),
    }
  })
  const line = `auth.js ${bundles.auth} B vs app.js ${bundles.app} B (unminified)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  expect(
    bundles.leaked,
    `the login bundle carries chat hooks: ${bundles.leaked.join(", ")}`,
  ).toEqual([])
  // And it is still the smaller of the two — a floor that survives further splitting, unlike a
  // ratio close to the runtime's own share.
  expect(bundles.auth, `${line} — the auth bundle is not smaller at all`).toBeLessThan(bundles.app)
  await anon.close()

  const app = await scriptsFor(alice, "/app")
  expect(app.seen, `the app pulled ${JSON.stringify(app.seen)}`).toContain("app.js")
})

test("the password reveal still works after moving out of the colocated hooks", async ({
  browser,
}) => {
  // `.PasswordReveal` and `.FlashAutoHide` stopped being colocated so the auth bundle could import
  // them without dragging the generated index (which hands back all 42 hooks at once). Moving a
  // hook renames it — `phx-hook=".PasswordReveal"` becomes `phx-hook="PasswordReveal"` — and
  // getting that wrong leaves a toggle that simply does nothing.
  const page = await browser.newPage()
  await page.goto("http://localhost:4001/login")
  await page.waitForFunction(() => window.liveSocket?.isConnected())

  const input = page.locator("[data-reveal-input]").first()
  const toggle = page.locator("[data-reveal-toggle]").first()

  await expect(input).toHaveAttribute("type", "password")
  await toggle.click()
  await expect(input).toHaveAttribute("type", "text")
  await expect(toggle).toHaveAttribute("aria-pressed", "true")
  await toggle.click()
  await expect(input).toHaveAttribute("type", "password")

  await page.close()
})
