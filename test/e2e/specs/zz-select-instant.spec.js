// The selection tick must not wait for the server (#521, part of epic #506).
//
// The selection lives on the server and the tick was painted only when its diff arrived, so a
// tap produced NOTHING until the round trip completed — and selecting five messages meant five
// taps that each looked ignored. The optimistic paint is safe because sync() repaints from
// `data-selected` on the next patch: a wrong guess corrects itself and cannot persist.
const { test, expect, send, openMenu } = require("../helpers/fixtures");

test.describe.configure({ mode: "serial" });

test("the tick appears on the tap, before the server answers", async ({ alice, seed }, testInfo) => {
  await alice.goto("/app");
  await alice.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  );
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).first().click();
  await alice.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`).waitFor();

  const mark = `select-instant-${Date.now()}`;
  await send(alice, mark);
  const row = alice.locator("#messages [data-message-id]", { hasText: mark }).last();
  await expect(row).toBeVisible();

  // Enter select mode through the menu, as a person would.
  const menu = await openMenu(alice, row);
  await menu.locator('[data-act="enter_select"]').click();
  await expect(alice.locator("#selbar")).toBeVisible({ timeout: 8000 });

  // Tap a second row and read the tick back in the SAME task, before any server frame can have
  // been processed. If the paint waited for the diff, this is where it would still be false.
  const pressedImmediately = await alice.evaluate(() => {
    const hits = [...document.querySelectorAll("#messages .ed-select-hit")];
    const target = hits.find((h) => h.getAttribute("aria-pressed") !== "true");
    if (!target) return null;
    target.click();
    return target.getAttribute("aria-pressed");
  });

  testInfo.annotations.push({
    type: "measurement",
    description: `aria-pressed right after the tap: ${pressedImmediately}`,
  });

  // Two assertions, not one: `null` means there was nothing to tap, and reporting THAT as "the
  // tick waited for the server" would send the next reader hunting a regression that is not
  // there (#536 review).
  expect(pressedImmediately, "no unselected row to tap — the fixture did not set the test up")
    .not.toBeNull();

  expect(pressedImmediately, "the tick waited for the server").toBe("true");

  // And the server still owns the truth: the count catches up.
  await expect(alice.locator("#selbar")).toContainText(/2/, { timeout: 8000 });
});
