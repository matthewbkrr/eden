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

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)

  // The messages are on screen the moment the view connects, which is BEFORE the bundle is even
  // asked for — so every one of these rows mounted against a placeholder. That is the path being
  // tested: not the arrival of the bundle, but the handover to an instance that already existed.
  //
  // It does not test the window itself. A gesture inside it is not replayed (see `deferred.js` for
  // why re-dispatching was rejected), and an earlier version of this test claimed to cover that
  // race while its own timing meant the bundle had always landed first (#578 review). Delaying the
  // response to force the ordering was tried and does not survive this harness's request
  // interception, so the honest thing is a test that says what it checks.
  await loaded(alice)

  const message = alice.locator("[id^='messages-'] [data-message-id]").last()
  await expect(message).toBeVisible({ timeout: 10_000 })
  await message.click({ button: "right" })

  await expect(
    alice.locator("#message-menu"),
    "the context menu never opened — the placeholder never handed the element over",
  ).toBeVisible({ timeout: 5000 })
})
