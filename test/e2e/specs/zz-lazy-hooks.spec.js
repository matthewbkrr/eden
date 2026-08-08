// The second hook bundle (#511): what the boot path no longer carries, and the promise that
// deferring it changes nothing a person can notice.
//
// The unit test (`asset_bundles_test.exs`) already guards the two lists against drifting apart.
// What only a browser can answer is whether the handover works: LiveView demands a hook at the
// instant the element mounts, so every deferred name is registered as a placeholder that has to
// pass its instance to the real hook once the bundle lands.
const { test, expect } = require("../helpers/fixtures")

const ready = (page) =>
  page.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)

const loaded = (page) => page.waitForFunction(() => !!window.__edenLazyHooks)

test("the boot bundle sheds the interaction hooks, and the second one carries them", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)

  const source = async (path) => {
    const res = await alice.request.get(path)
    expect(res.status(), `${path} did not serve`).toBe(200)
    return await res.text()
  }

  const [app, lazy] = [await source("/assets/js/app.js"), await source("/assets/js/lazy.js")]

  // Not a byte budget — that belongs in the issue, and a dev build is not a prod build. What this
  // pins is WHERE the code sits, by a string only the lightbox has. Comparing the two sizes proved
  // nothing (`app < app + lazy` is arithmetic, not a test — #578 review), while a marker in the
  // wrong bundle is the regression that actually matters: an eager import quietly putting a
  // deferred hook back on the boot path AND leaving its copy in the second bundle.
  expect(lazy, "the second bundle does not carry the lightbox").toContain("ed-lightbox")
  expect(app, "the lightbox is back in the boot bundle").not.toContain("ed-lightbox")
})

test("every placeholder hands over to the real hook", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await loaded(alice)

  // The map LiveView holds is patched the moment the bundle lands, so no name
  // may still answer with a placeholder. One that does is a hook registered as deferred and then
  // never built into the second bundle — its feature would be silently dead.
  const stranded = await alice.evaluate(() =>
    Object.entries(window.liveSocket.hooks)
      .filter(([, hook]) => hook && hook.__lazyPlaceholder)
      .map(([name]) => name),
  )

  expect(stranded, "these hooks never arrived").toEqual([])
})

test("an element mounted before the bundle landed still answers afterwards", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  // The first request for the bundle is refused, which pins the ordering the test needs instead of
  // hoping for it: the messages mount, the person presses, and the hooks genuinely are not there
  // yet. Waiting for the socket and then for the bundle proved nothing — the real hook could have
  // registered before the row ever mounted (#578 review). Refused, not delayed: a held request is
  // at the mercy of the browser deciding the connection is no longer worth fulfilling.
  let refuse = true
  await alice.route("**/assets/js/lazy.js*", (route) =>
    refuse ? route.abort("failed") : route.continue(),
  )

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)

  const message = alice.locator("[id^='messages-'] [data-message-id]").last()
  await expect(message).toBeVisible({ timeout: 10_000 })
  const menu = alice.locator("#message-menu")

  expect(
    await alice.evaluate(() => !!window.__edenLazyHooks),
    "the bundle arrived anyway — this test is no longer testing the window it names",
  ).toBe(false)

  // Inside the window: the element is mounted against a placeholder and the press does nothing.
  // That is the documented cost of deferring — the gesture is not queued and not replayed, because
  // synthesizing gestures is what gave this app its ghost-menu races.
  await message.click({ button: "right" })
  await alice.waitForTimeout(300)
  await expect(menu, "the menu opened with no hook behind it").toBeHidden()

  // A refused fetch re-arms the triggers, so the next gesture tries again — otherwise one dropped
  // request would leave a chat with no menus until reload.
  refuse = false
  await alice.mouse.click(4, 4)
  await loaded(alice)

  // Out the other side: the SAME element, mounted long before any of this, now answers.
  await message.click({ button: "right" })
  await expect(
    menu,
    "the context menu never opened — the placeholder never handed the element over",
  ).toBeVisible({ timeout: 5000 })
})
