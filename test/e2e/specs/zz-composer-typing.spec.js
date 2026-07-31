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
  let lastFrameAt = 0;

  alice.on("websocket", (ws) => {
    ws.on("framereceived", (f) => {
      const payload = String(f.payload || "");
      // The dev server streams its own logs over phoenix:live_reload — that is the tooling.
      if (payload.includes("phoenix:live_reload")) return;
      lastFrameAt = Date.now();
      if (!counting) return;
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

  // Boundaries by observation, not by the clock: a fixed wait before would leave initial traffic
  // in the count, and a fixed wait after could stop before the debounce flushed — the count would
  // then look better than reality (#534 review). Quiet means no frame for `ms`.
  const quiet = async (ms) => {
    lastFrameAt = lastFrameAt || Date.now();
    for (let waited = 0; waited < 20_000; waited += 100) {
      if (Date.now() - lastFrameAt >= ms) return;
      await alice.waitForTimeout(100);
    }
    throw new Error(`socket never went quiet for ${ms} ms`);
  };

  await quiet(700);

  const sentence = "привет, как дела сегодня";
  counting = true;
  await alice.locator("#composer-body").click();
  const typedAt = Date.now();
  await alice.keyboard.type(sentence, { delay: 60 });

  // Wait for the debounced flush to ARRIVE first, then for silence. Waiting for silence alone
  // returns immediately when the debounce has suppressed everything — the flush is still 250 ms
  // away — and the count comes back as zero, i.e. flattering nonsense. The first version of this
  // test did exactly that and reported "0 frames" with a straight face.
  for (let waited = 0; lastFrameAt <= typedAt && waited < 10_000; waited += 100) {
    await alice.waitForTimeout(100);
  }
  await quiet(700);
  counting = false;

  expect(frames, "no frame arrived at all — the measurement window missed the flush").toBeGreaterThan(0);

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
