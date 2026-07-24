// Instant-navigation message cache (#427, phase 2): re-opening a chat paints its last-seen thread
// from cache INSTANTLY (in-memory for same-session revisits, IndexedDB across reloads), while the
// real stream loads and replaces it. The cache only ever feeds the display-only overlay, so it's
// never authoritative — the real stream always reconciles (no duplicate rows).
const { test, expect, shot, send } = require("../helpers/fixtures")

async function connected(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 10_000,
  })
}

test.describe("instant navigation cache", () => {
  test("same-session revisit paints the cached thread synchronously (no skeleton)", async ({
    alice,
    seed,
  }) => {
    const page = alice
    await page.goto("/app")
    await connected(page)

    const aSel = `#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`
    const bSel = `#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`

    // Open A → its real messages render → ed:conv-shown snapshots it into the cache.
    await page.locator(aSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    const realCount = await page.locator("#messages .ed-msg, #messages .ed-flat").count()
    expect(realCount, "A must have messages to cache").toBeGreaterThan(0)

    // The snapshot is idle-deferred — wait until A is actually in the in-memory cache.
    await expect
      .poll(() =>
        page.evaluate((dm) => {
          const uid = document.getElementById("instant-nav").dataset.userId
          return !!window.__edMsgCache.peek(uid, dm)
        }, String(seed.dm_id)),
      )
      .toBe(true)

    // Switch to B so A is no longer the active row.
    await page.locator(bSel).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`),
    ).toBeVisible()

    // Revisit A: the in-memory peek paints cached content with NO await — probe the overlay in the
    // same task as the click.
    const probe = await page.evaluate((sel) => {
      document.querySelector(sel).click()
      const ov = document.querySelector(".ed-nav-skel")
      return {
        overlayCount: document.querySelectorAll(".ed-nav-skel").length,
        cached: !!ov?.querySelector(".ed-nav-skel__body--cache"),
        realRows: ov ? ov.querySelectorAll(".ed-msg, .ed-flat").length : 0,
        skelBubbles: ov ? ov.querySelectorAll(".ed-nav-skel__bubble").length : 0,
      }
    }, aSel)
    expect(probe.overlayCount, "exactly one overlay (no stale fade left behind)").toBe(1)
    expect(probe.cached, "overlay body carries cached real rows, not skeleton").toBe(true)
    expect(probe.realRows).toBeGreaterThan(0)
    expect(probe.skelBubbles, "no skeleton bubbles when cache hits").toBe(0)

    // Reconciliation: real stream lands, overlay clears, #messages holds the real rows ONCE.
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    await expect.poll(() => page.locator(".ed-nav-skel").count()).toBe(0)
    expect(await page.locator("#messages .ed-msg, #messages .ed-flat").count()).toBe(realCount)
  })

  test("cross-reload revisit paints from IndexedDB", async ({ alice, seed }, testInfo) => {
    const page = alice
    // Open A on a fresh load → the snapshot persists to IndexedDB.
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await expect(page.locator("#messages .ed-msg, #messages .ed-flat").first()).toBeVisible()
    // The snapshot is idle-deferred — deterministically wait for it to land in IndexedDB (not a
    // fixed timeout) before reloading, so this never flakes on slow CI.
    await expect
      .poll(
        () =>
          page.evaluate(
            (dm) =>
              new Promise((resolve) => {
                const req = indexedDB.open("eden-msg-cache", 1)
                req.onsuccess = () => {
                  const uid = document.getElementById("instant-nav").dataset.userId
                  const tx = req.result.transaction("snapshots", "readonly")
                  tx.objectStore("snapshots").get(uid + ":" + dm).onsuccess = (e) =>
                    resolve(!!e.target.result)
                  tx.onerror = () => resolve(false)
                }
                req.onerror = () => resolve(false)
              }),
            String(seed.dm_id),
          ),
        { timeout: 6_000 },
      )
      .toBe(true)

    // Full reload wipes the in-memory cache; the IDB snapshot survives. Slow the server so the IDB
    // fill wins the race and is observable before the real stream replaces it.
    await page.goto("/app")
    await connected(page)
    await page.evaluate(() => window.liveSocket.enableLatencySim(2500))

    await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).click()
    await expect(page.locator(".ed-nav-skel")).toBeVisible()
    // Skeleton first, then the async IDB read swaps in the cached rows.
    await expect(page.locator(".ed-nav-skel .ed-nav-skel__body--cache")).toBeVisible({
      timeout: 4_000,
    })
    expect(
      await page.locator(".ed-nav-skel .ed-msg, .ed-nav-skel .ed-flat").count(),
    ).toBeGreaterThan(0)
    await shot(page, testInfo, "cache-thread-from-idb")
    await page.evaluate(() => window.liveSocket.disableLatencySim())
  })

  test("logging out wipes the cached threads (shared-machine privacy)", async ({ alice, seed }) => {
    const page = alice
    // Probe WITHOUT creating: a versioned open() would materialize an empty store-less DB and
    // make the app's own put throw NotFoundError. Check existence first, close after reading.
    const idbHas = () =>
      page.evaluate(
        (dm) =>
          (async () => {
            const dbs = await indexedDB.databases()
            if (!dbs.some((d) => d.name === "eden-msg-cache")) return false
            return new Promise((resolve) => {
              const req = indexedDB.open("eden-msg-cache")
              req.onsuccess = () => {
                const db = req.result
                const done = (hit) => {
                  db.close()
                  resolve(hit)
                }
                try {
                  const host = document.getElementById("instant-nav")
                  if (!host) return done(false)
                  const tx = db.transaction("snapshots", "readonly")
                  tx.objectStore("snapshots").get(host.dataset.userId + ":" + dm).onsuccess = (
                    e,
                  ) => done(!!e.target.result)
                  tx.onerror = () => done(false)
                } catch (_e) {
                  done(false)
                }
              }
              req.onerror = () => resolve(false)
            })
          })(),
        String(seed.dm_id),
      )

    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await expect(page.locator("#messages .ed-msg, #messages .ed-flat").first()).toBeVisible()
    await expect.poll(idbHas, { timeout: 6_000 }).toBe(true) // snapshot persisted

    // Block the logout navigation so we can inspect IndexedDB after the click; the click's cache
    // wipe (maybeStart, capture phase) still runs.
    await page.route("**/users/log_out", (r) => r.abort())
    await page.evaluate(() => document.querySelector('a[href="/users/log_out"]').click())

    await expect.poll(idbHas, { timeout: 4_000 }).toBe(false) // clearAll() wiped it
  })

  test("any signed-out page load wipes the cache (covers logout-everywhere / expiry)", async ({
    alice,
    seed,
  }) => {
    const page = alice
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await expect(page.locator("#messages .ed-msg, #messages .ed-flat").first()).toBeVisible()
    const uid = await page.evaluate(() => document.getElementById("instant-nav").dataset.userId)

    // uid-parameterized, non-creating IDB probe — usable on pages without #instant-nav (/login).
    const idbHas = () =>
      page.evaluate(
        ([u, dm]) =>
          (async () => {
            const dbs = await indexedDB.databases()
            if (!dbs.some((d) => d.name === "eden-msg-cache")) return false
            return new Promise((resolve) => {
              const req = indexedDB.open("eden-msg-cache")
              req.onsuccess = () => {
                const db = req.result
                const done = (hit) => {
                  db.close()
                  resolve(hit)
                }
                try {
                  const tx = db.transaction("snapshots", "readonly")
                  tx.objectStore("snapshots").get(u + ":" + dm).onsuccess = (e) =>
                    done(!!e.target.result)
                  tx.onerror = () => done(false)
                } catch (_e) {
                  done(false)
                }
              }
              req.onerror = () => resolve(false)
            })
          })(),
        [uid, String(seed.dm_id)],
      )

    await expect.poll(idbHas, { timeout: 6_000 }).toBe(true) // snapshot persisted

    // End the session for real (an authed /login visit just redirects to /app): kill the cookies
    // — the logout-everywhere / expiry / admin-revoke shape — then land on the login page. app.js
    // sees no #notifier host and wipes the store deterministically.
    await page.context().clearCookies()
    await page.goto("/login")
    await expect.poll(idbHas, { timeout: 6_000 }).toBe(false)
  })

  test("leaving a chat re-snapshots it — a just-sent message survives into the cache", async ({
    alice,
    seed,
  }) => {
    const page = alice
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await expect(page.locator("#messages .ed-msg, #messages .ed-flat").first()).toBeVisible()

    // Send AFTER the shown-time snapshot; only the leave-time snapshot can contain this text.
    const marker = `freshness-${Date.now()}`
    await send(page, marker)
    await expect(page.locator(`#messages :text("${marker}")`)).toBeVisible()

    // Navigate away via a sidebar tap — maybeStart snapshots the departing conversation.
    await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`),
    ).toBeVisible()

    const cachedHasMarker = await page.evaluate(
      ([dm, m]) => {
        const uid = document.getElementById("instant-nav").dataset.userId
        const rec = window.__edMsgCache.peek(uid, dm)
        return !!rec && rec.html.includes(m)
      },
      [String(seed.dm_id), marker],
    )
    expect(cachedHasMarker, "leave-time snapshot carries the message sent while open").toBe(true)
  })
})
