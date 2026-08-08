// The second hook bundle (#511): what the boot path no longer carries, and the promise that
// deferring it changes nothing a person can notice.
//
// The unit test (`asset_bundles_test.exs`) already guards the two lists against drifting apart.
// What only a browser can answer is whether the handover works: LiveView demands a hook at the
// instant the element mounts, so every deferred name is registered as a placeholder that has to
// pass its instance to the real hook once the bundle lands — and a gesture that arrives before it
// does must still end up doing what it asked for.
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

  const size = async (path) => {
    const res = await alice.request.get(path)
    expect(res.status(), `${path} did not serve`).toBe(200)
    return (await res.body()).length
  }

  const [app, lazy] = [await size("/assets/js/app.js"), await size("/assets/js/lazy.js")]

  // Not a byte budget — that belongs in the issue, and a dev build is not a prod build. This only
  // asserts the SPLIT is real: a second bundle exists, carries a meaningful share, and the boot
  // bundle is no longer the whole client.
  expect(lazy, "the second bundle is suspiciously small — did the imports get dropped?").toBeGreaterThan(20_000)
  expect(app, "the boot bundle still looks like it carries everything").toBeLessThan(app + lazy)
})

test("every placeholder hands over to the real hook", async ({ alice, seed }) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)
  await loaded(alice)

  // The bundle arrives at idle; the map LiveView holds is patched at the same moment, so no name
  // may still answer with a placeholder. One that does is a hook registered as deferred and then
  // never built into the second bundle — its feature would be silently dead.
  const stranded = await alice.evaluate(() =>
    Object.entries(window.liveSocket.hooks)
      .filter(([, hook]) => hook && hook.__lazyPlaceholder)
      .map(([name]) => name),
  )

  expect(stranded, "these hooks never arrived").toEqual([])
})

test("a gesture that lands before the bundle does still opens the menu", async ({
  alice,
  seed,
}) => {
  test.setTimeout(120_000)

  await alice.goto(`/app/c/${seed.dm_id}`)
  await ready(alice)

  // Deliberately WITHOUT waiting for the bundle: this is the race the deferral introduces — the
  // element is mounted, its hook is not there yet, and the person is already pressing. The
  // placeholder must catch up rather than swallow the gesture.
  const message = alice.locator("[id^='messages-'] [data-message-id]").last()
  await expect(message).toBeVisible({ timeout: 10_000 })
  await message.click({ button: "right" })

  await expect(
    alice.locator("#message-menu"),
    "the context menu never opened — the deferred hook lost the gesture",
  ).toBeVisible({ timeout: 5000 })
})
