// What a scroll costs (#519, part of epic #506).
//
// The day chip's label went through `new Intl.DateTimeFormat(...)` on every call, and the chip
// updates on every scroll tick for as long as the glide lasts. Constructing an ICU formatter is
// one of the most expensive calls the platform offers, and it was happening per frame.
//
// Two things this stand had to learn the hard way, both worth keeping:
//
//   * A PROGRAMMATIC scroll does not exercise this path at all. The hook only works while
//     `_userScrollUntil` is open, and that window is set by real scroll gestures — `scrollBy`
//     leaves it shut, and the measurement reads a flat zero whatever the code does.
//   * The formatter is only reached for days that are neither today nor yesterday, so the feed
//     has to be scrolled back into real history first. On a fresh seed everything is "today" and
//     the early return hides the cost completely.
//
// Get either wrong and the test measures nothing while looking green.
const { test, expect } = require("../helpers/fixtures");

// Two cached formatters cover every label (this year / another year), so a correct
// implementation constructs at most two — and in a single session, usually zero after the first.
const MAX_FORMATTERS = 2;

test("scrolling does not build a date formatter per frame", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000);

  await alice.goto("/app");
  await alice.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  );
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).first().click();
  await alice.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`).waitFor();
  await alice.waitForTimeout(1000);

  // Pull in history so the feed spans more than one day.
  for (let i = 0; i < 10; i++) {
    await alice.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }));
    await alice.waitForTimeout(300);
  }

  await alice.evaluate(() => {
    // Two counters, and the second one is the point: counting CONSTRUCTIONS alone cannot tell
    // "cached correctly" from "never ran". A zero would look like success either way — which is
    // precisely the trap this file documents and, until now, did not guard against
    // (#535 review). Counting format() calls proves the path was exercised at all.
    window.__fmt = 0;
    window.__formatted = 0;
    const Real = Intl.DateTimeFormat;
    // Count only DAY-shaped formatters — the chip's own. Anything else on the page builds its
    // own (the timestamp hooks format hours and minutes), and a scroll that happens to paginate
    // would then push the count past the threshold for reasons this test is not about
    // (#535 review).
    window.__isDayShape = (opts) => !!opts && !!opts.day && !!opts.month && !opts.hour;
    // `format` is an ACCESSOR on the prototype, not a plain method — assigning over it detaches
    // the internal slot and every call then throws "incompatible receiver". Wrap the getter.
    const desc = Object.getOwnPropertyDescriptor(Real.prototype, "format");
    Object.defineProperty(Real.prototype, "format", {
      configurable: true,
      get() {
        window.__formatted++;
        return desc.get.call(this);
      },
    });
    Intl.DateTimeFormat = function (...args) {
      if (window.__isDayShape(args[1])) window.__fmt++;
      return new Real(...args);
    };
    Intl.DateTimeFormat.prototype = Real.prototype;
    // Put everything back when the measurement is over. Playwright gives each test its own
    // context, so nothing could leak across tests — but a patched global that outlives its
    // purpose is a trap for whoever debugs this page next (#535 review).
    window.__restoreIntl = () => {
      Intl.DateTimeFormat = Real;
      Object.defineProperty(Real.prototype, "format", desc);
    };
  });

  // A REAL wheel gesture: this is what opens the hook's user-scroll window.
  const box = await alice.locator("#message-scroll").boundingBox();
  await alice.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  const TICKS = 30;
  for (let i = 0; i < TICKS; i++) {
    await alice.mouse.wheel(0, i % 2 ? 300 : -300);
    await alice.waitForTimeout(16);
  }
  await alice.waitForTimeout(800);

  const built = await alice.evaluate(() => window.__fmt);
  const formatted = await alice.evaluate(() => window.__formatted);
  await alice.evaluate(() => window.__restoreIntl && window.__restoreIntl());
  const line = `${TICKS} wheel ticks built ${built} date formatters, formatted ${formatted} labels`;
  console.log(line);
  testInfo.annotations.push({ type: "measurement", description: line });

  // The path must have RUN. Without this the whole test is satisfied by a scroll that never
  // reached a labelled day, and "0 formatters" would be a green light for nothing at all.
  expect(formatted, `${line} — the scroll never reached a day needing a label`).toBeGreaterThan(0);

  // Before the fix this was one per tick — 30 for 30. The threshold separates the two
  // implementations rather than describing a wish.
  expect(built, `${line} — a formatter per frame is back`).toBeLessThanOrEqual(MAX_FORMATTERS);

  // And the chip must still say something: a memoised formatter that never formats would also
  // score zero.
  const chip = alice.locator(".ed-date-chip, [data-date-chip]").first();
  if (await chip.count()) {
    await expect(chip).not.toHaveText("");
  }
});
