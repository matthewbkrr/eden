// The sidebar's context menus, after they stopped being rendered per row (#508, epic #506).
//
// Every chat row and every room row used to carry its own hidden `<div class="ed-menu">`. Measured
// on this stand: 60% of the chat list's DOM nodes and 59% of its bytes; in a 37-room channel,
// 1221 nodes and 240 KB where 337 nodes and 87 KB do. `Chat.list_conversations/2` has no LIMIT, so
// that grew with the account rather than with the screen.
//
// One shared menu per kind now, configured on open from the row's data-*. That trade is only safe
// if the configuring actually happens, which is what this file is about: not "a menu exists" but
// "the right menu, pointed at the right row, and its items reach the server".
const { test, expect, send, ready: sharedReady } = require("../helpers/fixtures")

// Wait for the menu to be OPEN, not for a fixed slice of time: these menus are opened by a hook
// on a real gesture, and a stand under load can take longer than any number picked in advance
// (#541 review). Playwright treats the `hidden` attribute as invisible, so this is exactly the
// condition the assertions care about.
const openMenu = async (page, selector, menuId) => {
  await page.locator(selector).first().click({ button: "right" })
  await page.locator(`#${menuId}`).waitFor({ state: "visible" })
}

// A connected socket is not a working menu: the row has to exist AND its hook has to be mounted,
// or a right-click lands on plain markup and nothing opens. `__edInstantNavReady` is the app's own
// "hooks are up" signal — dropping it in favour of "the row is in the DOM" made the second test
// time out here, which is the shape of every fixed-delay bug, just without the delay.
const ready = async (page, rowSelector) => {
  // The shared helper, not a local copy of half of it: .ContextMenu is a DEFERRED hook, and
  // openMenu() above right-clicks exactly once with no retry, so a gesture that lands before the
  // second bundle opens nothing and the wait below times out on a menu no one armed (#579).
  await sharedReady(page)
  await page.locator(rowSelector).first().waitFor()
}

const visibleItems = (page, id) =>
  page.evaluate(
    (menuId) =>
      [...document.getElementById(menuId).querySelectorAll("button")]
        .filter((b) => !b.hidden && b.offsetParent !== null)
        .map((b) => b.innerText.trim()),
    id,
  )

test.describe.configure({ mode: "serial" })

test("a chat menu is configured for the row that opened it", async ({ alice, seed }, testInfo) => {
  await alice.goto("/app")
  await ready(alice, ".ed-convo-wrap")

  const cost = await alice.evaluate(() => {
    const list = document.getElementById("conversations")
    return {
      rows: list.querySelectorAll(".ed-convo-wrap").length,
      nodes: list.querySelectorAll("*").length,
      inside: list.querySelectorAll("[data-menu]").length,
      bytes: new TextEncoder().encode(list.innerHTML).length,
    }
  })
  const line = `chat list: ${cost.rows} rows, ${cost.nodes} nodes, ${cost.bytes} B, ${cost.inside} inline menus`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })

  // The point of the change, stated as the thing that regresses: a menu back inside the list.
  expect(cost.inside, `${line} — per-row menus are back in the chat list`).toBe(0)

  // A 1:1 offers "Delete chat" (reversible — messaging back re-opens it); a group offers
  // "Leave group" instead, which is not. Getting that backwards is the failure the shared menu
  // makes possible, because both items exist in the same node.
  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`, "convo-menu")
  const dmItems = await visibleItems(alice, "convo-menu")
  expect(dmItems).toContain("Delete chat")
  expect(dmItems).not.toContain("Leave group")

  const ids = await alice.evaluate(() =>
    [...document.querySelectorAll("#convo-menu [phx-click]")].map((b) =>
      b.getAttribute("phx-value-id"),
    ),
  )
  expect(new Set(ids), "menu items point at more than one conversation").toEqual(
    new Set([String(seed.dm_id)]),
  )

  await alice.keyboard.press("Escape")
  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.group_id}"]`, "convo-menu")
  const groupItems = await visibleItems(alice, "convo-menu")
  expect(groupItems).toContain("Leave group")
  expect(groupItems).not.toContain("Delete chat")
})

test("muting from the shared menu reaches the server and the label follows", async ({
  alice,
  seed,
}) => {
  await alice.goto("/app")
  await ready(alice, ".ed-convo-wrap")

  const row = () => alice.locator(`.ed-convo-wrap[data-id="${seed.dm_id}"]`).first()
  const wasMuted = (await row().getAttribute("data-muted")) === "1"
  if (wasMuted) {
    await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`, "convo-menu")
    await alice.locator('#convo-menu button[phx-click="toggle_mute"]').click()
    await expect(row()).not.toHaveAttribute("data-muted", "1")
  }

  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`, "convo-menu")
  expect(await visibleItems(alice, "convo-menu")).toContain("Mute")

  // A real click, not a pushEvent: the items keep plain `phx-click` markup precisely so that
  // LiveView (and `data-confirm`) still own them, and only `phx-value-id` is rewritten. If that
  // rewrite failed, the event would arrive with no id and nothing would change.
  await alice.locator('#convo-menu button[phx-click="toggle_mute"]').click()
  await expect(row()).toHaveAttribute("data-muted", "1")

  // Re-opening must re-read the row: the label is now the other one.
  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`, "convo-menu")
  expect(await visibleItems(alice, "convo-menu")).toContain("Unmute")

  await alice.locator('#convo-menu button[phx-click="toggle_mute"]').click()
  await expect(row()).not.toHaveAttribute("data-muted", "1")
})

test("a room menu carries that room's link and hides delete for general", async ({
  alice,
  seed,
}, testInfo) => {
  await alice.goto(`/channels/${seed.channel_id}`)
  await ready(alice, ".ed-room-wrap")

  const cost = await alice.evaluate(() => {
    const rows = [...document.querySelectorAll(".ed-room-wrap")]
    const host = rows[0].parentElement
    return {
      rooms: rows.length,
      nodes: host.querySelectorAll("*").length,
      inside: host.querySelectorAll("[data-menu]").length,
      bytes: new TextEncoder().encode(host.innerHTML).length,
    }
  })
  const line = `room list: ${cost.rooms} rows, ${cost.nodes} nodes, ${cost.bytes} B, ${cost.inside} inline menus`
  console.log(line)
  testInfo.annotations.push({ type: "measurement", description: line })
  expect(cost.inside, `${line} — per-row menus are back in the room list`).toBe(0)

  // The general room can never be deleted, and that is the one per-room fact the shared menu
  // still resolves client-side.
  await openMenu(alice, `.ed-room-wrap[data-id="${seed.general_room_id}"]`, "room-menu")
  const general = await alice.evaluate(() => ({
    link: document.querySelector("#room-menu [data-copy-link]").dataset.link,
    items: [...document.querySelectorAll("#room-menu button")]
      .filter((b) => !b.hidden && b.offsetParent !== null)
      .map((b) => b.innerText.trim()),
    ids: [
      ...new Set(
        [...document.querySelectorAll("#room-menu [phx-click]")].map((b) =>
          b.getAttribute("phx-value-id"),
        ),
      ),
    ],
  }))

  expect(general.link).toContain(`/r/${seed.general_room_id}`)
  expect(general.ids).toEqual([String(seed.general_room_id)])
  expect(general.items, "the general room is offering a delete it cannot honour").not.toContain(
    "Delete room",
  )

  // Any other room in the same channel does offer it — otherwise the assertion above would pass
  // on a menu that simply never shows delete.
  const other = await alice.evaluate(
    (generalId) =>
      [...document.querySelectorAll(".ed-room-wrap")]
        .map((n) => n.dataset.id)
        .find((id) => String(id) !== String(generalId)) || null,
    seed.general_room_id,
  )
  test.skip(!other, "the channel has only a general room on this stand")

  await alice.keyboard.press("Escape")
  await openMenu(alice, `.ed-room-wrap[data-id="${other}"]`, "room-menu")
  expect(await visibleItems(alice, "room-menu")).toContain("Delete room")
})

test("an open room menu survives a patch: still placed, still armed, still works", async ({
  alice,
  bob,
  seed,
}) => {
  // #room-menu is the one shared menu that stays patchable: its admin items are behind a server
  // gate on the channel role, so `phx-update="ignore"` would freeze them (a channel owner who
  // arrives from /app would lose room administration for the session). It defends itself with
  // .MenuKeepOpen instead.
  //
  // Asserting that the menu is still VISIBLE is not enough, and that weaker test is what shipped
  // first: a patch also wipes everything fillSidebar() wrote — every `phx-value-id`, the
  // `data-needs` visibility, the copy link — so the first version of the hook brought the menu
  // back disarmed, every id reading `null`, which is worse than the vanish it replaced (#579
  // review). Assert the wiring, and then use it.
  await alice.goto(`/channels/${seed.channel_id}`)
  await ready(alice, ".ed-room-wrap")

  const row = () => alice.locator(`.ed-room-wrap[data-id="${seed.general_room_id}"]`).first()
  await openMenu(alice, `.ed-room-wrap[data-id="${seed.general_room_id}"]`, "room-menu")
  const menu = alice.locator("#room-menu")

  const wiring = () =>
    alice.evaluate(() => {
      const m = document.getElementById("room-menu")
      return {
        top: m.style.top,
        ids: [...m.querySelectorAll("[phx-click]")].map((b) => b.getAttribute("phx-value-id")),
        link: m.querySelector("[data-copy-link]")?.dataset.link || "",
      }
    })

  const before = await wiring()
  expect(before.top, "the menu opened without being positioned").toBeTruthy()
  expect(before.ids.length, "no items to point at a row").toBeGreaterThan(0)
  expect(before.ids.every((id) => id === String(seed.general_room_id))).toBe(true)
  expect(before.link, "the copy item has no room link").toContain(String(seed.general_room_id))

  // Alice created this channel in the seed, so she administers it. These are the items a frozen
  // subtree would have cost her.
  expect(
    await visibleItems(alice, "room-menu"),
    "the owner is not being offered room administration at all",
  ).toContain("Add members")

  // An ordinary patch of alice's page: bob writes into the DM, which moves the rail's messenger
  // badge. Through `send()`, not a raw requestSubmit — the helper waits for .SendQueue to have
  // mounted, and its own comment records that submitting at `isConnected()` is how nine specs here
  // were silently failing.
  const badge = alice.locator(".ed-rail__badge").first()
  const unread = (await badge.count()) ? await badge.innerText() : ""
  await bob.goto(`/app/c/${seed.dm_id}`)
  await send(bob, `room-menu-patch ${Date.now()}`)

  // WAIT for the patch to land before asserting anything about the menu. Without this the first
  // sample of the poll below can read the untouched DOM, which equals `before` by construction —
  // a green tautology that exercises none of MenuKeepOpen. The badge is server-coalesced
  // (@badge_coalesce_ms), so "the send returned" is not the same moment as "alice re-rendered"
  // (#579 review).
  await expect(badge, "the patch never reached alice — nothing below is proven").not.toHaveText(
    unread,
    { timeout: 12_000 },
  )

  await expect(menu, "a patch closed the open room menu").toBeVisible()
  await expect
    .poll(wiring, { message: "the patch left the menu on screen but disarmed", timeout: 12_000 })
    .toEqual(before)
  expect(
    await visibleItems(alice, "room-menu"),
    "the patch dropped the owner's admin items",
  ).toContain("Add members")

  // And it still reaches the server for the RIGHT room — the point of carrying phx-value-id.
  const muted = (await row().getAttribute("data-muted")) === "1"
  await alice.locator('#room-menu button[phx-click="toggle_mute"]').click()
  if (muted) {
    await expect(row()).not.toHaveAttribute("data-muted", "1")
  } else {
    await expect(row()).toHaveAttribute("data-muted", "1")
  }

  // Put it back: this room is the shared seed's general room, and a spec that leaves state behind
  // is how the accumulation this issue is about starts. (It also hid this test's own bug: the row
  // renders `data-muted={@room.muted && "1"}`, so unmuted means the attribute is ABSENT — there is
  // no "0" — and asserting one passed only because a previous run had left the room muted. The
  // rest of this file already uses the absent form; #579 review caught the one place that did not.)
  await openMenu(alice, `.ed-room-wrap[data-id="${seed.general_room_id}"]`, "room-menu")
  await alice.locator('#room-menu button[phx-click="toggle_mute"]').click()
  if (muted) {
    await expect(row()).toHaveAttribute("data-muted", "1")
  } else {
    await expect(row()).not.toHaveAttribute("data-muted", "1")
  }
})
