// Gesture ownership, behavioural half (#515, part of epic #506).
//
// The CSS half — which axis each surface claims — is pinned in test/eden_web/gesture_css_test.exs.
// What that cannot check is the two things the hook does at runtime: promoting a row to its own
// compositor layer ONLY while it is being dragged, and refusing to arm the edge-swipe while a
// modal owns the screen.
const { test, expect, send } = require("../helpers/fixtures");

test.describe.configure({ mode: "serial" });

async function ready(page) {
  await page.goto("/app");
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

test("a row is promoted for the drag and demoted after it", async ({ alice, seed }, testInfo) => {
  // The mouse-drag path is the desktop one; on a touch device the row is dragged by the finger
  // instead, and the hook's recentTouch guard deliberately ignores synthesized mouse events.
  test.skip(/mobile/.test(testInfo.project.name), "desktop drag path");
  // A static `will-change: transform` on rows would mean a compositor layer per rendered row —
  // ~200 of them. So the hook sets it when the drag starts and clears it in reset(), and this
  // test pins both edges: leaving it set would be the same cost, just harder to notice.
  await ready(alice);
  await openDm(alice, seed);
  const mark = `drag-${Date.now()}`;
  await send(alice, mark);
  const bubble = alice.locator("#messages .ed-bubble", { hasText: mark }).last();
  await expect(bubble).toBeVisible();

  const willChange = () => bubble.evaluate((el) => getComputedStyle(el).willChange);
  expect(await willChange(), "a row is promoted before anyone touched it").toBe("auto");

  const box = await bubble.boundingBox();
  const y = box.y + box.height / 2;
  await alice.mouse.move(box.x + box.width - 12, y);
  await alice.mouse.down();
  await alice.mouse.move(box.x + box.width - 12 - 20, y);
  await alice.mouse.move(box.x + box.width - 12 - 45, y);

  expect(await willChange(), "the dragged row was never promoted").toBe("transform");

  await alice.mouse.move(box.x + box.width - 12 - 100, y);
  await alice.mouse.up();

  await expect
    .poll(willChange, { timeout: 3000, message: "the row stayed promoted after the gesture" })
    .toBe("auto");
});

test("the edge swipe does not arm itself under an open modal", async ({ alice, seed }, testInfo) => {
  // Needs a touch-capable context: the edge-swipe recogniser only listens for real touches.
  test.skip(!/mobile-chrome/.test(testInfo.project.name), "touch path, CDP-driven");
  // The lightbox is a native <dialog>, and the chat header BEHIND it stays in the DOM — so
  // [data-nav-back] was still found and the edge-swipe armed under the photo, ready to navigate
  // a page the viewer cannot see.
  await ready(alice);
  await openDm(alice, seed);

  // Any open dialog stands in for the lightbox: the guard is about modality, not about photos,
  // and this keeps the test independent of what the seed happens to contain.
  await alice.evaluate(() => {
    const d = document.createElement("dialog");
    d.id = "probe-modal";
    document.body.appendChild(d);
    d.showModal();
  });

  const before = alice.url();

  // REAL touches through CDP. A synthetic TouchEvent built in the page does not reach this
  // recogniser at all — the first version of this test passed with the guard REMOVED, i.e. it
  // proved nothing. Same technique the nav-races stand uses for exactly that reason.
  const cdp = await alice.context().newCDPSession(alice);
  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: 4, y: 300 }] });
  for (const x of [40, 90, 160, 240]) {
    await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: 300 }] });
  }
  await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await alice.waitForTimeout(700);

  expect(alice.url(), "the edge swipe navigated from under a modal").toBe(before);
  expect(
    await alice.evaluate(() => !!document.getElementById("probe-modal")?.open),
    "the modal was closed by a gesture that should not have been armed",
  ).toBe(true);

  await alice.evaluate(() => document.getElementById("probe-modal")?.remove());
});
