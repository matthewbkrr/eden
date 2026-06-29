const { test, expect, send } = require("../helpers/fixtures")

// #155 VERIFY: Mattermost-flat rooms collapse consecutive same-author runs — the first message
// of a run shows the author header (avatar + name + time), subsequent ones from the same sender
// (within @compact_window_s = 5min) render compact (no head, no avatar). A different author, or
// a >5min gap, breaks the run. Covers all three feed paths: live server insert, author-change
// break, and the initial server render (mark_compact) after a reload.
const room = (seed) => `/channels/${seed.channel_id}/r/${seed.general_room_id}`

const rowState = (page, text) =>
  page
    .locator("#messages .ed-flat", { hasText: text })
    .first()
    .evaluate((el) => ({
      compact: el.classList.contains("ed-flat--compact"),
      hasHead: !!el.querySelector(".ed-flat__head"),
      hasAvatar: !!el.querySelector(".ed-flat__avatar-btn"),
    }))

test("rooms collapse consecutive same-author runs; author change breaks them (#155)", async ({
  alice,
  bob,
  seed,
}) => {
  await alice.goto(room(seed))
  await bob.goto(room(seed))
  await alice.waitForSelector("#messages", { timeout: 15000 })

  // Unique-per-run markers so each row is addressable regardless of prior room history
  // (the room persists across retries / reseeds; a fixed tag would collide).
  const tag = `c155-${Date.now().toString(36)}`
  const a1 = `${tag}-alpha`,
    a2 = `${tag}-bravo`,
    a3 = `${tag}-charlie`
  const b1 = `${tag}-delta`,
    a4 = `${tag}-echo`

  // Break any accumulated same-author run first (the shared room persists messages across
  // runs): a separator from Bob guarantees Alice's a1 below starts a FRESH run, so its author
  // header must show regardless of who posted last.
  const sep = `${tag}-sep`
  await send(bob, sep)
  await expect(alice.locator("#messages .ed-flat", { hasText: sep })).toBeVisible({ timeout: 10000 })

  // 1. Alice sends 3 in a row → live-insert path. First heads, rest collapse.
  await send(alice, a1)
  await expect(alice.locator("#messages .ed-flat", { hasText: a1 })).toBeVisible({ timeout: 10000 })
  await send(alice, a2)
  await expect(alice.locator("#messages .ed-flat", { hasText: a2 })).toBeVisible({ timeout: 10000 })
  await send(alice, a3)
  await expect(alice.locator("#messages .ed-flat", { hasText: a3 })).toBeVisible({ timeout: 10000 })

  expect(await rowState(alice, a1)).toEqual({ compact: false, hasHead: true, hasAvatar: true })
  expect(await rowState(alice, a2)).toEqual({ compact: true, hasHead: false, hasAvatar: false })
  expect(await rowState(alice, a3)).toEqual({ compact: true, hasHead: false, hasAvatar: false })

  // 2. Bob sends → author change → his row is NOT compact (run broken).
  await send(bob, b1)
  await expect(alice.locator("#messages .ed-flat", { hasText: b1 })).toBeVisible({ timeout: 10000 })
  expect(await rowState(alice, b1)).toEqual({ compact: false, hasHead: true, hasAvatar: true })

  // 3. Alice sends again after Bob → her new run starts fresh → NOT compact.
  await send(alice, a4)
  await expect(alice.locator("#messages .ed-flat", { hasText: a4 })).toBeVisible({ timeout: 10000 })
  expect(await rowState(alice, a4)).toEqual({ compact: false, hasHead: true, hasAvatar: true })

  // 4. Reload → initial server render (mark_compact). The same collapse must persist
  //    (proves it's not just the live-insert path).
  await alice.reload()
  await alice.waitForSelector("#messages", { timeout: 15000 })
  await expect(alice.locator("#messages .ed-flat", { hasText: a3 })).toBeVisible({ timeout: 10000 })
  expect(await rowState(alice, a1)).toEqual({ compact: false, hasHead: true, hasAvatar: true })
  expect(await rowState(alice, a2)).toEqual({ compact: true, hasHead: false, hasAvatar: false })
  expect(await rowState(alice, a3)).toEqual({ compact: true, hasHead: false, hasAvatar: false })
  expect(await rowState(alice, b1)).toEqual({ compact: false, hasHead: true, hasAvatar: true })
})
