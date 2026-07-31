// Read-receipt diff budget (#513, part of epic #506).
//
// A read receipt flips ✓ → ✓✓ on the sender's own messages. It used to re-fetch and re-stream
// the whole page to do it — fifty fully rendered bubbles for a change that touches, normally,
// one row. And it fires for EVERY incoming message while the chat is open, i.e. exactly in the
// window where the sender is watching their own send land.
//
// The oracle is the wire: bytes of LiveView frames the sender's socket receives while sending
// one message into an actively-read conversation. That is the thing the budget in #506 is
// written against, and it is immune to how fast the machine is.
const { test, expect, send } = require("../helpers/fixtures");

// Measured, before and after the fix, on the same stand:
//
//   before   63 798 B, of which 57 707 B was the whole-page re-stream
//   after    13 899 B, of which  7 808 B is two message rows
//
// The 4 KB hot-path budget in #506 is NOT met by this change alone, and the remainder is
// accounted for rather than hidden: ~3.9 KB is the sender's own echo (the new bubble, which any
// send must pay), ~3.9 KB is the one row whose tick flips, and ~4.3 KB is the sidebar row that
// `refresh_sidebar` re-streams on every read — that last one is #514.
//
// So the threshold here separates the two implementations instead of encoding an aspiration:
// the old whole-page re-stream is far above it, the new one far below.
const BUDGET = 24576;

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

test("sending into an actively-read DM stays inside the diff budget", async ({
  alice,
  bob,
  seed,
}, testInfo) => {
  // Count before navigating: the socket opens during goto.
  let bytes = 0;
  let counting = false;
  let lastFrameAt = 0;
  alice.on("websocket", (ws) => {
    ws.on("framereceived", (f) => {
      const payload = String(f.payload || "");
      // The dev server streams its own logs over a separate phoenix:live_reload channel — 60 KB
      // of them in this window alone. Counting those would measure the tooling, not the app.
      if (payload.includes("phoenix:live_reload")) return;
      lastFrameAt = Date.now();
      if (counting) bytes += Buffer.byteLength(payload);
    });
  });

  // Boundaries by observation, not by the clock. A fixed drain before and a fixed sleep after
  // would both guess: too short and a late frame goes uncounted (a false pass), too long and the
  // test is slow for nothing (#529 review). Quiet means the socket has said nothing for `ms`.
  const quiet = async (ms) => {
    lastFrameAt = lastFrameAt || Date.now();
    for (let waited = 0; waited < 15_000; waited += 100) {
      if (Date.now() - lastFrameAt >= ms) return;
      await alice.waitForTimeout(100);
    }
    throw new Error(`socket never went quiet for ${ms} ms`);
  };

  await ready(alice);
  await ready(bob);
  await openDm(alice, seed);
  await openDm(bob, seed);
  // Let the initial render, presence and any pending receipts drain before measuring.
  await quiet(600);

  const mark = `receipt-${Date.now()}`;
  counting = true;
  await send(alice, mark);

  // Bob has it on screen, so his client has marked the conversation read...
  await expect(bob.locator("#messages", { hasText: mark })).toBeVisible({ timeout: 10_000 });
  // ...and alice's own row has flipped to the read state, which IS the receipt landing. The
  // double tick renders a second check carrying `-mr-2`, a class the single tick never has, so
  // it is an exact signal rather than a guess.
  const row = alice.locator("#messages [data-message-id]", { hasText: mark }).last();
  await expect(row.locator(".-mr-2").first()).toBeVisible({ timeout: 10_000 });
  // Stop only once nothing more is arriving, so a trailing frame cannot be missed.
  await quiet(800);
  counting = false;

  const line = `one send into an actively-read DM: ${bytes} B received by the sender`;
  console.log(line);
  testInfo.annotations.push({ type: "measurement", description: line });

  expect(bytes, `${line} — budget is ${BUDGET} B`).toBeLessThan(BUDGET);
});
