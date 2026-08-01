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
    if (/\/assets\/js\/[^/]+\.js/.test(r.url())) seen.push(r.url().split("/").pop().split("?")[0])
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

  const sizes = await anon.evaluate(async () => {
    const get = async (p) => (await (await fetch(p)).text()).length
    return { auth: await get("/assets/js/auth.js"), app: await get("/assets/js/app.js") }
  })
  const line = `auth.js ${sizes.auth} B vs app.js ${sizes.app} B (unminified)`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  // A threshold that separates "the chat client is out" from "a few modules moved": the hooks are
  // 46% of the bundle, so anything close to parity means the split did not take.
  expect(sizes.auth, `${line} — the auth bundle is not materially smaller`).toBeLessThan(
    sizes.app * 0.75,
  )
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
