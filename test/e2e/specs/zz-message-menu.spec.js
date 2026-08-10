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

// Serial: every test here sends into the SAME dm and one of them deletes a message, so running
// them in parallel had them fighting over the same conversation (the pane simply never opened).
test.describe.configure({ mode: "serial" });

async function ready(page) {
  await page.goto("/app");
  // Wait for the app's OWN readiness signal, not just the socket: until the instant-nav hook is
  // armed a click on a sidebar row can be swallowed, and the pane never opens.
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  );
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

test("Reply from the menu moves focus into the composer", async ({ alice, seed }) => {
  // The old markup reached this through JS.focus baked into a per-message phx-click. The shared
  // menu pushes the row's own reply event instead, so the focus move is now the hook's job — and
  // a refactor could drop it without anything looking wrong. Locked here (#528 review).
  await ready(alice);
  await openDm(alice, seed);
  const mark = `reply-focus-${Date.now()}`;
  await send(alice, mark);
  const row = alice.locator("#messages [data-message-id]", { hasText: mark }).last();

  const menu = await openMenu(alice, row);
  await menu.locator('[data-act="reply"]').click();

  await expect(menu).toBeHidden();
  await expect(alice.locator("#composer-body")).toBeFocused();
  // The reply bar above the composer confirms the server got the event for THIS message.
  await expect(alice.locator(".ed-reply-bar").first()).toBeVisible({ timeout: 5000 });
});

test("Delete for everyone asks first, then tombstones the message", async ({ alice, seed }) => {
  // `data-confirm` is a phx-click feature and these items push directly, so the hook asks itself,
  // with the server-rendered text. Assert the prompt actually happens — not just the outcome — or
  // dropping it would go unnoticed (#528 review).
  await ready(alice);
  await openDm(alice, seed);
  const mark = `delete-both-${Date.now()}`;
  await send(alice, mark);
  const row = alice.locator("#messages [data-message-id]", { hasText: mark }).last();

  const menu = await openMenu(alice, row);
  const item = menu.locator('[data-act="delete_for_both"]');
  await expect(item).toBeVisible();
  const question = await item.getAttribute("data-confirm-text");
  expect(question, "the item carries no confirmation text to ask with").toBeTruthy();
  await item.click();

  // Since #518 the question is the app's own sheet, not `window.confirm`. Watching for a browser
  // dialog therefore counted nothing, and — because nobody answered the sheet — the delete never
  // fired either, so both halves of this test were asserting into the void (#579).
  const ask = alice.locator(".ed-ask");
  await expect(ask, "no confirmation was asked before deleting for everyone").toBeVisible();
  await expect(ask).toContainText(question);

  // The menu goes first: the question belongs over the chat, not over a menu on its way out.
  await expect(menu).toBeHidden();

  await ask.locator("[data-ok]").click();
  await expect(alice.locator("#messages", { hasText: mark })).toHaveCount(0, { timeout: 8000 });
});

// A full leftward swipe: past the 56px threshold, axis-dominant, from the trailing edge.
async function swipeReply(page, bubble) {
  const box = await bubble.boundingBox();
  const y = box.y + box.height / 2;
  await page.mouse.move(box.x + box.width - 12, y);
  await page.mouse.down();
  for (const dx of [20, 45, 75, 100]) await page.mouse.move(box.x + box.width - 12 - dx, y);
  await page.mouse.up();
}

test("swipe-to-reply still runs the same path as the menu item", async ({
  alice,
  seed,
}, testInfo) => {
  // The MOUSE drag path is desktop-only: on a touch device the row is dragged by the finger and
  // the hook's recentTouch guard deliberately ignores synthesized mouse events. The same guard
  // sits on the equivalent test in zz-gestures; this one was missing it and failed on
  // mobile-chrome for that reason alone.
  test.skip(/mobile/.test(testInfo.project.name), "desktop drag path");
  // fireReply stopped being a closure and became a hook method (#528 review), and the swipe
  // gestures call it too — so the gesture needs its own check, or the refactor could have
  // broken quote-reply everywhere except the menu. Desktop drag path: bubbles only, leftward
  // and axis-dominant past the 56px threshold.
  await ready(alice);
  await openDm(alice, seed);
  const mark = `swipe-reply-${Date.now()}`;
  await send(alice, mark);
  const bubble = alice.locator("#messages .ed-bubble", { hasText: mark }).last();
  await expect(bubble).toBeVisible();

  const box = await bubble.boundingBox();
  const y = box.y + box.height / 2;
  await alice.mouse.move(box.x + box.width - 12, y);
  await alice.mouse.down();
  for (const dx of [20, 45, 75, 100]) {
    await alice.mouse.move(box.x + box.width - 12 - dx, y);
  }
  await alice.mouse.up();

  await expect(alice.locator(".ed-reply-bar").first()).toBeVisible({ timeout: 5000 });
  await expect(alice.locator("#composer-body")).toBeFocused();
});

// The other half of the gesture (#393/R062): what must NOT open a reply. A swipe recogniser that
// only ever gets tested on the motion it is supposed to catch will happily catch everything — and
// the cost lands on the two motions people make constantly over a message: selecting text, and
// scrolling the feed.
//
// Only the reply half is asserted. Whether the drag still SELECTS is not observable here: a
// synthetic mouse drag does not drive native selection in this harness at all — probed with a
// plain horizontal drag inside a bubble whose computed `user-select` is `auto`, which also came
// back empty (#581 review). Claiming it in a title would have been a promise the test cannot keep.
test("a vertical drag over a message does not open a reply", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/mobile/.test(testInfo.project.name), "desktop drag path");
  await ready(alice);
  await openDm(alice, seed);

  const mark = `swipe-neg-${Date.now()}`;
  await send(alice, mark);
  const bubble = alice.locator("#messages .ed-bubble", { hasText: mark }).last();
  await expect(bubble).toBeVisible();

  const box = await bubble.boundingBox();
  const x = box.x + box.width - 12;

  // Axis-dominant DOWN, past the same distance that would open a reply sideways.
  await alice.mouse.move(x, box.y + 4);
  await alice.mouse.down();
  for (const dy of [20, 45, 75, 100]) await alice.mouse.move(x, box.y + 4 + dy);
  await alice.mouse.up();

  await expect(
    alice.locator(".ed-reply-bar").first(),
    "a vertical drag opened the reply bar — text selection and scrolling would both quote by accident",
  ).toBeHidden();

  // `toBeHidden` is also satisfied by a gesture layer that is simply dead, which would make this
  // whole test a green light over a broken feature (#581 review). So the same message is then
  // swiped for real: if the recogniser answers that, the silence above was a decision.
  await swipeReply(alice, bubble);
  await expect(
    alice.locator(".ed-reply-bar").first(),
    "the recogniser did not answer a real swipe either — the negative above proved nothing",
  ).toBeVisible({ timeout: 5000 });
});

test("a short sideways nudge does not reach the reply threshold", async ({
  alice,
  seed,
}, testInfo) => {
  test.skip(/mobile/.test(testInfo.project.name), "desktop drag path");
  await ready(alice);
  await openDm(alice, seed);

  const mark = `swipe-short-${Date.now()}`;
  await send(alice, mark);
  const bubble = alice.locator("#messages .ed-bubble", { hasText: mark }).last();
  await expect(bubble).toBeVisible();

  const box = await bubble.boundingBox();
  const y = box.y + box.height / 2;

  // Half the 56px threshold: the gesture is deliberately hard to trigger by accident, and the
  // number that makes it so is worth a test of its own.
  await alice.mouse.move(box.x + box.width - 12, y);
  await alice.mouse.down();
  for (const dx of [10, 20, 28]) await alice.mouse.move(box.x + box.width - 12 - dx, y);
  await alice.mouse.up();

  await expect(
    alice.locator(".ed-reply-bar").first(),
    "half a swipe opened a reply — the threshold is not being applied",
  ).toBeHidden();

  // Same reason as above: a threshold that rejects everything is not a threshold. Cross it.
  await swipeReply(alice, bubble);
  await expect(
    alice.locator(".ed-reply-bar").first(),
    "a full swipe opened nothing either — the gesture path is dead, so the nudge proved nothing",
  ).toBeVisible({ timeout: 5000 });
});

test("an open menu survives a server patch of the pane", async ({ alice, bob, seed }) => {
  // The menu is server markup (`hidden`, unpositioned) that the CLIENT takes over on open. Without
  // `phx-update="ignore"` any patch of this LiveView put that markup back: the menu blinked out
  // with `close()` never running, so `active` still pointed at the row, the document listeners
  // stayed armed and focus never came home. Traffic in ANOTHER chat was enough — it only has to
  // move an unread badge (#579).
  await ready(alice);
  await openDm(alice, seed);
  const mark = `patch-${Date.now()}`;
  await send(alice, mark);
  const row = alice.locator("#messages [data-message-id]", { hasText: mark }).last();

  const menu = await openMenu(alice, row);
  const placed = await menu.evaluate((m) => m.style.top);
  expect(placed, "the menu opened without being positioned").toBeTruthy();

  // A message into the GROUP, which alice is not looking at: her sidebar badge moves and nothing
  // else. Deliberately not a message into THIS chat — that scrolls the stream to the bottom, and a
  // scroll closes the menu on purpose, which would hide the bug this test is for.
  const badge = alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"] .ed-badge`);
  const before = (await badge.count()) ? await badge.first().innerText() : "";
  await bob.goto(`/app/c/${seed.group_id}`);
  await bob.waitForFunction(() => window.liveSocket?.isConnected());
  await send(bob, `patch-from-bob-${Date.now()}`);
  await expect(badge.first(), "the sidebar never patched — nothing was proven").not.toHaveText(
    before,
    { timeout: 12_000 },
  );

  await expect(menu, "a patch elsewhere in the page closed the menu").toBeVisible();
  expect(await menu.evaluate((m) => m.style.top), "the patch wiped the menu's position").toBe(
    placed,
  );

  // Still a working menu, not just a visible one.
  await menu.locator('[data-act="enter_select"]').click();
  await expect(alice.locator(".ed-selbar")).toBeVisible();
});
