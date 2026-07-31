// What typing costs (#521, part of epic #506).
//
// The composer sent `composer_changed` on EVERY character and the server echoed the value back,
// so a short sentence meant two dozen round trips and two dozen patches applied on the main
// thread — while the person was still typing, on a connection where one round trip is ~160 ms.
//
// The oracle is the wire: frames and bytes for one typed sentence. A count, not a feeling.
const { test, expect } = require("../helpers/fixtures");

// Measured on this stand: 24 frames before the fix, 1 after. The threshold separates the two
// implementations rather than encoding an aspiration — a debounce that stopped working would
// go straight back to one frame per character.
const MAX_FRAMES = 6;

test.describe.configure({ mode: "serial" });

test("typing a sentence does not cost a round trip per character", async ({
  alice,
  seed,
}, testInfo) => {
  let received = 0;
  let sent = 0;
  let frames = 0;
  let counting = false;

  alice.on("websocket", (ws) => {
    ws.on("framereceived", (f) => {
      const payload = String(f.payload || "");
      // The dev server streams its own logs over phoenix:live_reload — that is the tooling.
      if (!counting || payload.includes("phoenix:live_reload")) return;
      received += Buffer.byteLength(payload);
      frames++;
    });
    ws.on("framesent", (f) => {
      if (counting) sent += Buffer.byteLength(String(f.payload || ""));
    });
  });

  await alice.goto("/app");
  await alice.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  );
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).first().click();
  await alice.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`).waitFor();
  await alice.waitForTimeout(1200);

  const sentence = "привет, как дела сегодня";
  counting = true;
  await alice.locator("#composer-body").click();
  await alice.keyboard.type(sentence, { delay: 60 });
  await alice.waitForTimeout(1200);
  counting = false;

  const line =
    `typing ${sentence.length} characters: ${sent} B sent, ${received} B received, ${frames} frames`;
  console.log(line);
  testInfo.annotations.push({ type: "measurement", description: line });

  expect(frames, `${line} — one round trip per character is back`).toBeLessThanOrEqual(MAX_FRAMES);

  // The debounce must not swallow the text: what was typed is what the field holds, and it is
  // what a send would carry.
  await expect(alice.locator("#composer-body")).toHaveValue(sentence);
});

test("a send right after typing carries the whole sentence", async ({ alice, bob, seed }) => {
  // The server only learns the value after the debounce, so a fast type-then-send is the case
  // that would break if anything downstream read the text from the server's assign instead of
  // from the field.
  for (const page of [alice, bob]) {
    await page.goto("/app");
    await page.waitForFunction(
      () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
      null,
      { timeout: 15_000 },
    );
    await page.locator(`#conversations a.ed-convo[href$="/app/c/${seed.dm_id}"]`).first().click();
    await page.locator(`#message-scroll[data-conversation-id="${seed.dm_id}"]`).waitFor();
  }

  const text = `fast-send-${Date.now()}`;
  await alice.locator("#composer-body").click();
  await alice.keyboard.type(text, { delay: 10 });
  await alice.keyboard.press("Enter"); // well inside the debounce window

  await expect(bob.locator("#messages", { hasText: text })).toBeVisible({ timeout: 10_000 });
  await expect(alice.locator("#composer-body")).toHaveValue("");
});
