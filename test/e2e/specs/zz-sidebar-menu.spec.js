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
const { test, expect } = require("../helpers/fixtures")

const openMenu = async (page, selector) => {
  await page.locator(selector).first().click({ button: "right" })
  await page.waitForTimeout(300)
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
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(1000)

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
  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`)
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
  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.group_id}"]`)
  const groupItems = await visibleItems(alice, "convo-menu")
  expect(groupItems).toContain("Leave group")
  expect(groupItems).not.toContain("Delete chat")
})

test("muting from the shared menu reaches the server and the label follows", async ({
  alice,
  seed,
}) => {
  await alice.goto("/app")
  await alice.waitForFunction(() => window.liveSocket?.isConnected() && window.__edInstantNavReady)
  await alice.waitForTimeout(1000)

  const row = () => alice.locator(`.ed-convo-wrap[data-id="${seed.dm_id}"]`).first()
  const wasMuted = (await row().getAttribute("data-muted")) === "1"
  if (wasMuted) {
    await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`)
    await alice.locator('#convo-menu button[phx-click="toggle_mute"]').click()
    await expect(row()).not.toHaveAttribute("data-muted", "1")
  }

  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`)
  expect(await visibleItems(alice, "convo-menu")).toContain("Mute")

  // A real click, not a pushEvent: the items keep plain `phx-click` markup precisely so that
  // LiveView (and `data-confirm`) still own them, and only `phx-value-id` is rewritten. If that
  // rewrite failed, the event would arrive with no id and nothing would change.
  await alice.locator('#convo-menu button[phx-click="toggle_mute"]').click()
  await expect(row()).toHaveAttribute("data-muted", "1")

  // Re-opening must re-read the row: the label is now the other one.
  await openMenu(alice, `.ed-convo-wrap[data-id="${seed.dm_id}"]`)
  expect(await visibleItems(alice, "convo-menu")).toContain("Unmute")

  await alice.locator('#convo-menu button[phx-click="toggle_mute"]').click()
  await expect(row()).not.toHaveAttribute("data-muted", "1")
})

test("a room menu carries that room's link and hides delete for general", async ({
  alice,
  seed,
}, testInfo) => {
  await alice.goto(`/channels/${seed.channel_id}`)
  await alice.waitForFunction(() => window.liveSocket?.isConnected())
  await alice.waitForTimeout(1500)

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
  await openMenu(alice, `.ed-room-wrap[data-id="${seed.general_room_id}"]`)
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
  await openMenu(alice, `.ed-room-wrap[data-id="${other}"]`)
  expect(await visibleItems(alice, "room-menu")).toContain("Delete room")
})
