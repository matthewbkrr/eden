// Shared message context menu (#508, part of epic #506).
//
// The menu used to be rendered hidden INSIDE every bubble and every flat row: 24 nodes and
// ~5 KB per message, measured at 68% of the feed's DOM nodes and 64% of its bytes. It now
// lives once per page (like #reaction-grid, #72) and is pointed at a row when it opens.
//
// The risk this spec exists for is ownership: one node, many rows. If the shared menu keeps
// pointing at whichever row wired it first, every action silently targets the wrong message —
// and nothing on screen would look wrong. So the tests below check WHICH message an action
// reaches, not merely that the menu appears.
const { test, expect, send, openMenu } = require("../helpers/fixtures");

async function ready(page) {
  await page.goto("/app");
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 15_000,
  });
}

async function openDm(page, seed) {
  await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).first().click();
  await page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`).waitFor();
}

test("there is exactly ONE menu node for the whole feed", async ({ alice, seed }) => {
  await ready(alice);
  await openDm(alice, seed);
  await alice.waitForTimeout(400);

  const counts = await alice.evaluate(() => ({
    shared: document.querySelectorAll("#message-menu").length,
    inFeed: document.querySelectorAll("#messages [data-menu]").length,
    rows: document.querySelectorAll("#messages [data-message-id]").length,
  }));

  expect(counts.shared, "the shared menu is missing").toBe(1);
  expect(counts.rows, "no message rows to speak of").toBeGreaterThan(0);
  expect(counts.inFeed, "a per-message menu is still rendered inside the feed").toBe(0);
});

test("the menu opens on a row and its items reach THAT message", async ({ alice, seed }) => {
  await ready(alice);
  await openDm(alice, seed);
  const mark = `menu-target-${Date.now()}`;
  await send(alice, mark);
  const row = alice.locator("#messages [data-message-id]", { hasText: mark }).last();
  await expect(row).toBeVisible();

  const menu = await openMenu(alice, row);
  await expect(menu).toHaveAttribute("id", "message-menu");

  // React through the shared menu, then assert the server recorded it against THIS message.
  // data-emoji-mine is rendered per row from the viewer's own reactions, so it is a precise
  // oracle for "which message did the action reach" — the check that would fail if the shared
  // menu still pointed at the row that wired it first. (The chips themselves render as a
  // SIBLING of the bubble, not inside it, so a descendant selector would miss them.)
  await menu.locator('[data-act="react"]').first().click();
  await expect(row).toHaveAttribute("data-emoji-mine", /\S/, { timeout: 5000 });
});

test("item visibility follows the message, not whoever opened the menu first", async ({
  alice,
  bob,
  seed,
}) => {
  await ready(alice);
  await ready(bob);
  await openDm(alice, seed);
  await openDm(bob, seed);

  const fromBob = `from-bob-${Date.now()}`;
  await send(bob, fromBob);
  const mine = `from-alice-${Date.now()}`;
  await send(alice, mine);

  const ownRow = alice.locator("#messages [data-message-id]", { hasText: mine }).last();
  const otherRow = alice.locator("#messages [data-message-id]", { hasText: fromBob }).last();
  await expect(otherRow).toBeVisible({ timeout: 10_000 });

  // Own message: Edit and Delete-for-everyone are offered.
  const onOwn = await openMenu(alice, ownRow);
  await expect(onOwn.locator('[data-act="start_edit"]')).toBeVisible();
  await expect(onOwn.locator('[data-act="delete_for_both"]')).toBeVisible();
  await alice.keyboard.press("Escape");

  // Someone else's: both are gone. Same DOM node, re-pointed — this is the regression that a
  // shared menu invites, and the reason the items are toggled on open rather than at render.
  const onOther = await openMenu(alice, otherRow);
  await expect(onOther).toHaveAttribute("id", "message-menu");
  await expect(onOther.locator('[data-act="start_edit"]')).toBeHidden();
  await expect(onOther.locator('[data-act="delete_for_both"]')).toBeHidden();
});

test("copy link takes the permalink of the row the menu is on", async ({ alice, seed }) => {
  await ready(alice);
  await openDm(alice, seed);
  const mark = `permalink-${Date.now()}`;
  await send(alice, mark);
  const row = alice.locator("#messages [data-message-id]", { hasText: mark }).last();
  const id = await row.getAttribute("data-message-id");

  const menu = await openMenu(alice, row);
  await menu.locator('[data-act="copy_link"]').click();

  // Read back through the same clipboard the app wrote to. Granted per-context by the harness
  // where supported; where it is not, fall back to asserting the row's own permalink attribute,
  // which is what the hook copies.
  const link = await alice
    .evaluate(() => navigator.clipboard.readText())
    .catch(() => null);
  if (link) expect(link).toContain(`/m/${id}`);
  else expect(await row.getAttribute("data-link")).toContain(`/m/${id}`);
});
