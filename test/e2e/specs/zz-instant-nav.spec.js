// Instant-navigation skeleton (#instant-nav): tapping a sidebar chat must paint the
// target's shell + a shimmer skeleton in the SAME frame (client-side, no server round-trip),
// then fade it out once .ScrollBottom announces the real stream landed (ed:conv-shown).
//
// The overlay window is tiny on localhost, so instead of racing a screenshot we instrument
// the DOM: a MutationObserver records the overlay's add (with its painted name) and remove,
// and a listener counts ed:conv-shown. That proves the whole handshake deterministically.
const { test, expect, shot, send } = require("../helpers/fixtures")

async function instrument(page) {
  await page.evaluate(() => {
    window.__skel = { addedName: null, hasShimmer: false, full: false, removed: false, shown: 0 }
    const mo = new MutationObserver((muts) => {
      for (const m of muts) {
        for (const n of m.addedNodes) {
          if (n.nodeType === 1 && n.classList && n.classList.contains("ed-nav-skel")) {
            window.__skel.addedName = (n.querySelector(".ed-nav-skel__name")?.textContent || "").trim()
            window.__skel.hasShimmer = !!n.querySelector(".ed-skel-shimmer")
            window.__skel.full = n.classList.contains("ed-nav-skel--full")
            window.__skel.hasFoot = !!n.querySelector(".ed-nav-skel__foot")
            window.__skel.anim = getComputedStyle(n).animationName
          }
        }
        for (const n of m.removedNodes) {
          if (n.nodeType === 1 && n.classList && n.classList.contains("ed-nav-skel")) {
            window.__skel.removed = true
          }
        }
      }
    })
    mo.observe(document.body, { childList: true })
    window.addEventListener("ed:conv-shown", () => window.__skel.shown++)
  })
}

async function connected(page) {
  // Socket connected AND the InstantNav hook mounted (its beacon) — the sync click-probes
  // below race hook attachment otherwise (intermittent "ov is null").
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 10_000 },
  )
}

test.describe("instant navigation skeleton", () => {
  test("DM tap: paints shell + skeleton, fades on real stream", async ({ alice, seed }, testInfo) => {
    const page = alice
    await page.goto("/app")
    await connected(page)
    await instrument(page)

    const dm = page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`)
    await expect(dm).toBeVisible()
    const name = (await dm.locator(".ed-convo__name").first().textContent()).trim()
    await dm.click()

    // The chat actually opened (real stream present for the target conversation).
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()

    const skel = await page.evaluate(() => window.__skel)
    expect(skel.addedName, "overlay painted the tapped row's real name").toBe(name)
    expect(skel.hasShimmer, "overlay carries a shimmer skeleton").toBe(true)
    expect(skel.shown, "ed:conv-shown fired once the real stream landed").toBeGreaterThan(0)

    // And it clears itself — no stranded overlay.
    await expect.poll(() => page.evaluate(() => window.__skel.removed)).toBe(true)
    await expect(page.locator(".ed-nav-skel")).toHaveCount(0)

    await shot(page, testInfo, "instant-nav-dm-opened")
  })

  test("room tap: overlay uses the room name + flat skeleton", async ({ alice, seed }, testInfo) => {
    const page = alice
    // Enter the channel first so the room list is in the sidebar, then tap the general room.
    await page.goto(`/channels/${seed.channel_id}`)
    await connected(page)
    await instrument(page)

    const room = page.locator(
      `a.ed-convo.ed-room[href$="/channels/${seed.channel_id}/r/${seed.general_room_id}"]`,
    )
    await expect(room).toBeVisible()
    const name = (await room.locator(".ed-convo__name").first().textContent()).trim()
    await room.click()

    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.general_room_id}"]`),
    ).toBeVisible()

    const skel = await page.evaluate(() => window.__skel)
    expect(skel.addedName).toBe(name)
    expect(skel.hasShimmer).toBe(true)
    expect(skel.shown).toBeGreaterThan(0)
    await expect.poll(() => page.evaluate(() => window.__skel.removed)).toBe(true)

    await shot(page, testInfo, "instant-nav-room-opened")
  })

  test("skeleton visual (light + dark)", async ({ alice, seed }, testInfo) => {
    const page = alice
    await page.goto("/app")
    await connected(page)
    const dm = page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`)
    await dm.waitFor()
    // Slow the socket round-trip so the real overlay lingers (real dismiss path, just delayed)
    // — long enough to screenshot both themes. No event hacks: this is exactly what a bad
    // connection does, and it's what makes the effect worth having.
    await page.evaluate(() => window.liveSocket.enableLatencySim(3000))
    await dm.click()
    await expect(page.locator(".ed-nav-skel")).toBeVisible()
    await shot(page, testInfo, "skeleton-light")
    await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"))
    await page.waitForTimeout(150)
    await expect(page.locator(".ed-nav-skel")).toBeVisible()
    await shot(page, testInfo, "skeleton-dark")
    await page.evaluate(() => window.liveSocket.disableLatencySim())
  })

  test("overlay mirrors the pane card: ends above the composer, rounded, sm avatar", async ({
    alice,
    seed,
  }, testInfo) => {
    // Desktop geometry only: on mobile the sidebar is hidden while a chat is open, and the
    // overlay goes full-screen instead of mirroring the pane card.
    test.skip(testInfo.project.name.startsWith("mobile"), "desktop-only geometry")
    const page = alice
    // Open A so a real chat (with its composer) is on screen, then tap B.
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await instrument(page)

    const probe = await page.evaluate((sel) => {
      const scroll = document.getElementById("message-scroll").getBoundingClientRect()
      const composer = document.getElementById("composer").getBoundingClientRect()
      document.querySelector(sel).click()
      const ov = document.querySelector(".ed-nav-skel")
      const r = ov.getBoundingClientRect()
      const cs = getComputedStyle(ov)
      const av = ov.querySelector(".ed-nav-skel__head .ed-avatar")
      return {
        bottomGap: Math.abs(r.bottom - scroll.bottom),
        composerClear: composer.top >= r.bottom - 1,
        radius: cs.borderTopLeftRadius,
        avatarSm: !!av && av.classList.contains("ed-avatar--sm"),
        hasFoot: !!ov.querySelector(".ed-nav-skel__foot"),
      }
    }, `#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`)

    expect(probe.bottomGap, "overlay bottom sits at the top of the composer").toBeLessThan(2)
    expect(probe.composerClear, "the real composer stays visible below the overlay").toBe(true)
    expect(probe.radius, "overlay inherits the pane card's rounding").not.toBe("0px")
    expect(probe.avatarSm, "cloned avatar matches the real header's sm size").toBe(true)
    expect(probe.hasFoot, "no composer skeleton when the real composer shows through").toBe(false)
  })

  test("mobile full-screen overlay carries a composer skeleton", async ({ alice, seed }, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only variant")
    const page = alice
    await page.goto("/app")
    await connected(page)
    await instrument(page)
    // Real tap (a synthetic el.click() from evaluate doesn't reach the hook on WebKit);
    // the MutationObserver records the overlay's shape at insertion time.
    await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    const skel = await page.evaluate(() => window.__skel)
    expect(skel.full, "mobile overlay covers the full screen").toBe(true)
    expect(skel.hasFoot, "full-screen overlay draws the composer skeleton").toBe(true)
    expect(skel.anim, "mobile overlay slides in TG-style").toContain("ed-nav-push")
  })

  test("desktop overlay enters with the light drift, not the mobile push", async ({
    alice,
    seed,
  }, testInfo) => {
    test.skip(testInfo.project.name.startsWith("mobile"), "desktop variant")
    const page = alice
    await page.goto("/app")
    await connected(page)
    await instrument(page)
    await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    const skel = await page.evaluate(() => window.__skel)
    expect(skel.anim).toContain("ed-nav-in")
    expect(skel.anim).not.toContain("ed-nav-push")
  })

  test("mobile back: pane slides out over the revealed list, then the patch lands", async ({
    alice,
    seed,
  }, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only back choreography")
    const page = alice
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await page.evaluate(() => {
      window.__back = { popped: false, asideShown: false, railShown: false }
      const main = document.getElementById("chat-dropzone")
      const aside = document.querySelector(".ed-root > aside")
      const rail = document.querySelector("nav.ed-rail")
      new MutationObserver(() => {
        if (main.classList.contains("ed-main-pop")) window.__back.popped = true
      }).observe(main, { attributes: true, attributeFilter: ["class"] })
      new MutationObserver(() => {
        if (!aside.classList.contains("hidden")) window.__back.asideShown = true
      }).observe(aside, { attributes: true, attributeFilter: ["class"] })
      // The channel rail hides via the same @selected class — it must be revealed WITH the
      // aside, not a round-trip later (it popped in and squeezed the list; user report).
      new MutationObserver(() => {
        if (!rail.classList.contains("hidden")) window.__back.railShown = true
      }).observe(rail, { attributes: true, attributeFilter: ["class"] })
    })
    await page.locator("[data-nav-back]").click()
    await expect.poll(() => page.evaluate(() => window.__back.popped)).toBe(true)
    expect(await page.evaluate(() => window.__back.asideShown), "list revealed for the slide").toBe(
      true,
    )
    expect(
      await page.evaluate(() => window.__back.railShown),
      "channel rail revealed together with the list",
    ).toBe(true)
    // The real patch fires after the slide — we land on the list.
    await expect.poll(() => page.url(), { timeout: 8_000 }).toMatch(/\/app$/)
    await expect(page.locator("#conversations")).toBeVisible()
  })

  test("repeat tap on the same chat while in flight is swallowed", async ({ alice, seed }, testInfo) => {
    test.skip(testInfo.project.name.startsWith("mobile"), "uses a synthetic second click (WebKit drops those)")
    const page = alice
    await page.goto("/app")
    await connected(page)
    // Hold the transition open so the second tap lands while the first is still in flight.
    await page.evaluate(() => window.liveSocket.enableLatencySim(2500))
    const sel = `#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`
    const before = await page.evaluate(() => history.length)
    await page.locator(sel).click()
    await expect(page.locator(".ed-nav-skel")).toBeVisible()
    const prevented = await page.evaluate((s) => {
      const link = document.querySelector(s)
      const ev = new MouseEvent("click", { bubbles: true, cancelable: true, button: 0 })
      link.dispatchEvent(ev)
      return ev.defaultPrevented
    }, sel)
    expect(prevented, "second tap swallowed while the first is in flight").toBe(true)
    await page.evaluate(() => window.liveSocket.disableLatencySim())
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    const after = await page.evaluate(() => history.length)
    expect(after - before, "exactly one history entry despite the double tap").toBe(1)
  })

  test("mobile back really slides (the transition runs, not a jump)", async ({
    alice,
    seed,
  }, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only back choreography")
    const page = alice
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await page.locator("[data-nav-back]").click()
    // Sample the pane's computed transform every frame: a real transition passes through
    // mid-flight translateX values; the old rAF-batched class flip sometimes skipped the
    // transition entirely (the "back animation is gone" report).
    const moved = await page.evaluate(
      () =>
        new Promise((resolve) => {
          const main = document.getElementById("chat-dropzone")
          const t0 = performance.now()
          const tick = () => {
            const tr = main && getComputedStyle(main).transform
            if (tr && tr !== "none") {
              const parts = tr.match(/matrix\(([^)]+)\)/)
              const tx = parts ? parseFloat(parts[1].split(",")[4]) : 0
              if (tx > 1 && tx < main.offsetWidth - 1) return resolve(true)
            }
            if (!main || performance.now() - t0 > 700) return resolve(false)
            requestAnimationFrame(tick)
          }
          tick()
        }),
    )
    expect(moved, "pane passes through mid-flight transform values").toBe(true)
    await expect.poll(() => page.url(), { timeout: 8_000 }).toMatch(/\/app$/)
  })

  test("mobile back with reduced motion: plain instant patch, no slide classes", async ({
    alice,
    seed,
  }, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only")
    const page = alice
    await page.emulateMedia({ reducedMotion: "reduce" })
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await page.evaluate(() => {
      window.__popped = false
      const main = document.getElementById("chat-dropzone")
      new MutationObserver(() => {
        if (main.classList.contains("ed-main-pop")) window.__popped = true
      }).observe(main, { attributes: true, attributeFilter: ["class"] })
    })
    await page.locator("[data-nav-back]").click()
    await expect.poll(() => page.url(), { timeout: 8_000 }).toMatch(/\/app$/)
    expect(await page.evaluate(() => window.__popped), "no slide under reduced motion").toBe(false)
    await page.emulateMedia({ reducedMotion: null })
  })

  test("safe-area strips follow the visible screen (mobile)", async ({ alice, seed }, testInfo) => {
    test.skip(!testInfo.project.name.startsWith("mobile"), "mobile-only strip rule")
    const page = alice
    // List visible → the root (which paints the strips) matches the list's surface bg.
    await page.goto("/app")
    await connected(page)
    const onList = await page.evaluate(() => {
      const root = getComputedStyle(document.querySelector(".ed-root")).backgroundColor
      const aside = getComputedStyle(document.querySelector(".ed-root > aside")).backgroundColor
      return { root, aside }
    })
    expect(onList.root, "strips match the list surface").toBe(onList.aside)

    // Chat open → the root matches the chat pane bg again.
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    const onChat = await page.evaluate(() => {
      const root = getComputedStyle(document.querySelector(".ed-root")).backgroundColor
      const main = getComputedStyle(document.getElementById("chat-dropzone")).backgroundColor
      return { root, main }
    })
    expect(onChat.root, "strips match the chat pane").toBe(onChat.main)
    expect(onChat.root).not.toBe(onList.root)
  })

  test("history loads don't rise-in; a live message still does", async ({ alice, bob, seed }, testInfo) => {
    test.skip(testInfo.project.name.startsWith("mobile"), "drives the sidebar with a chat open")
    const page = alice
    await page.goto(`/app/c/${seed.group_id}`)
    await connected(page)
    // Record every row that ever GAINS ed-msg--enter (the rise-in class) from here on.
    await page.evaluate(() => {
      window.__risen = 0
      const mo = new MutationObserver((muts) => {
        for (const m of muts) {
          if (m.type === "attributes" && m.target.classList?.contains("ed-msg--enter")) {
            window.__risen++
          }
        }
      })
      mo.observe(document.getElementById("chat-dropzone"), {
        subtree: true,
        attributes: true,
        attributeFilter: ["class"],
      })
    })

    // Switching conversations streams the whole history in one patch — bulk, no animation
    // (over the instant-nav cache the same rows are already on screen; re-animating them
    // was the "рвано при входе" report).
    await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).click()
    await expect(
      page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`),
    ).toBeVisible()
    await expect(page.locator("#messages .ed-msg").first()).toBeVisible()
    // Precondition: the bulk gate needs >= 4 rows in the patch — if the seed ever shrinks
    // below that, fail HERE with a clear message instead of a confusing risen>0 below.
    expect(
      await page.locator("#messages .ed-msg").count(),
      "seed DM must hold >= 4 messages for the bulk-suppression path",
    ).toBeGreaterThanOrEqual(4)
    expect(
      await page.evaluate(() => window.__risen),
      "a bulk history load must not rise-in",
    ).toBe(0)

    // A LIVE incoming message is a single-row batch and still animates.
    await bob.goto(`/app/c/${seed.dm_id}`)
    await connected(bob)
    await send(bob, `rise-${Date.now()}`)
    await expect
      .poll(() => page.evaluate(() => window.__risen), { timeout: 8_000 })
      .toBeGreaterThan(0)
  })

  test("tapping the already-open chat paints no overlay", async ({ alice, seed }, testInfo) => {
    // On mobile the sidebar is hidden while a chat is open, so the active row can't be tapped.
    test.skip(testInfo.project.name.startsWith("mobile"), "sidebar hidden when a chat is open on mobile")
    const page = alice
    await page.goto(`/app/c/${seed.dm_id}`)
    await connected(page)
    await instrument(page)

    // The open chat's row carries .ed-convo--active — a re-tap is a no-op, so no overlay.
    const active = page.locator(`#conversations a.ed-convo.ed-convo--active`)
    await expect(active).toBeVisible()
    await active.click()
    await page.waitForTimeout(400)

    expect(await page.evaluate(() => window.__skel.addedName)).toBeNull()
    await expect(page.locator(".ed-nav-skel")).toHaveCount(0)
  })
})
