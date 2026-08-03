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

// The other half of what a glide costs: forced layout. `getBoundingClientRect` after any style
// write flushes layout, and the chip did one for the scroller, one per separator and ~8 more for a
// binary search over the rows — every frame, for the whole length of a momentum glide.
//
// A count, not a frame time: the epic's budget is stated in milliseconds, but milliseconds on a
// loaded stand are noise. The number of reads is deterministic and moves only when the code does.
const instrumentLayout = (page) =>
  page.addInitScript(() => {
    window.__layout = { rect: 0, scrollHeight: 0 };
    const rect = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = function () {
      window.__layout.rect++;
      return rect.call(this);
    };
    // `scrollHeight` is the other forced flush that matters here: reading it right after writing
    // `scrollTop` is what a per-frame pin does, and each pair is a synchronous layout of the feed.
    const d = Object.getOwnPropertyDescriptor(Element.prototype, "scrollHeight");
    if (d && d.get) {
      Object.defineProperty(Element.prototype, "scrollHeight", {
        ...d,
        get() {
          window.__layout.scrollHeight++;
          return d.get.call(this);
        },
      });
    }
  });

test("a glide does not re-measure the feed every frame", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000);
  await instrumentLayout(alice);

  await alice.goto("/app");
  await alice.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  );
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).first().click();
  await alice.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`).waitFor();
  await alice.waitForTimeout(1000);

  for (let i = 0; i < 10; i++) {
    await alice.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }));
    await alice.waitForTimeout(300);
  }

  const rows = await alice.evaluate(() => document.querySelectorAll("#messages > *").length);
  await alice.evaluate(() => (window.__layout.rect = 0));

  // A REAL wheel gesture, for the same reason the test above needs one: the chip only works
  // inside the hook's user-scroll window, and a programmatic scroll leaves that window shut.
  const box = await alice.locator("#message-scroll").boundingBox();
  await alice.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  const TICKS = 30;
  for (let i = 0; i < TICKS; i++) {
    await alice.mouse.wheel(0, i % 2 ? 300 : -300);
    await alice.waitForTimeout(16);
  }
  await alice.waitForTimeout(800);

  const reads = await alice.evaluate(() => window.__layout.rect);
  const line = `${rows} rows, ${TICKS} wheel ticks: ${reads} getBoundingClientRect`;
  console.log(line);
  testInfo.annotations.push({ type: "measurement", description: line });

  // Measured before the fix on this stand: 865-995 for these thirty ticks. The chip answers from
  // an index it builds once per glide now, so the count is bounded by the rebuilds, not by frames.
  expect(reads, `${line} — the feed is being measured every frame again`).toBeLessThan(200);
});

// Cheaper is only worth having if it is still right. The label is now derived from a cached index
// of day boundaries rather than by measuring rows, so this checks the answer against the feed
// itself: the chip must name the day of the topmost row actually on screen.
test("the chip names the day of the topmost visible row", async ({ alice, seed }) => {
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
  for (let i = 0; i < 10; i++) {
    await alice.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }));
    await alice.waitForTimeout(300);
  }

  const box = await alice.locator("#message-scroll").boundingBox();
  await alice.mouse.move(box.x + box.width / 2, box.y + box.height / 2);

  const seen = [];
  for (let i = 0; i < 12; i++) {
    await alice.mouse.wheel(0, 420);
    await alice.waitForTimeout(90);

    const check = await alice.evaluate(() => {
      const scroller = document.getElementById("message-scroll");
      const chip = scroller.querySelector("#date-chip");
      if (!chip || !chip.classList.contains("is-visible")) return null;
      // The topmost row whose bottom is below the viewport top — read straight from the DOM,
      // independently of the index the hook keeps.
      const top = scroller.getBoundingClientRect().top + 4;
      const row = [...document.querySelectorAll("#messages > [data-ts]")].find(
        (r) => r.getBoundingClientRect().bottom > top,
      );
      if (!row) return null;
      const d = new Date(Number(row.dataset.ts) * 1000);
      return {
        chip: chip.textContent.trim(),
        day: d.getDate(),
        month: d.getMonth(),
      };
    });
    if (check) seen.push(check);
  }

  expect(seen.length, "the chip never appeared during the scroll").toBeGreaterThan(2);

  // The label carries the day number for anything older than yesterday; Today/Yesterday are words.
  const wrong = seen.filter((s) => {
    const isWord = !/\d/.test(s.chip);
    return !isWord && !s.chip.includes(String(s.day));
  });
  console.log(`chip labels: ${[...new Set(seen.map((s) => s.chip))].join(" | ")}`);
  expect(
    wrong,
    `the chip named a different day than the row on screen: ${JSON.stringify(wrong)}`,
  ).toEqual([]);
});

// Typing is a patch storm: every keystroke fires phx-change, and every hook on the page gets its
// beforeUpdate/updated callbacks whether or not anything it owns changed. Two of them walk whole
// lists — the feed's scroll-pinning hook and the sidebar's reorder animation — so the cost of a
// keystroke is measured here rather than assumed.
test("a keystroke does not walk the feed and the sidebar", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000);
  await instrumentLayout(alice);

  await alice.goto("/app");
  await alice.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  );
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).first().click();
  await alice.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`).waitFor();
  await alice.waitForTimeout(1200);

  // At scale, or the claim is untested: the cost being measured is per-row work, and a fresh feed
  // holds fifty rows.
  for (let i = 0; i < 10; i++) {
    await alice.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }));
    await alice.waitForTimeout(300);
  }
  await alice.evaluate(() =>
    document.getElementById("message-scroll")?.scrollTo({ top: 10 ** 7 }),
  );
  await alice.waitForTimeout(500);

  const size = await alice.evaluate(() => ({
    rows: document.querySelectorAll("#messages > *").length,
    chats: document.querySelectorAll("#conversations > *").length,
  }));

  const input = alice.locator("#composer-body");
  await input.click();
  await alice.waitForTimeout(300);
  await alice.evaluate(() => (window.__layout.rect = 0));

  const KEYS = 10;
  await input.type("abcdefghij", { delay: 60 });
  await alice.waitForTimeout(500);

  const reads = await alice.evaluate(() => window.__layout.rect);
  const perKey = Math.round((reads / KEYS) * 10) / 10;
  const line = `${size.rows} rows + ${size.chats} chats, ${KEYS} keystrokes: ${reads} getBoundingClientRect (${perKey}/key)`;
  console.log(line);
  testInfo.annotations.push({ type: "measurement", description: line });

  await input.fill("");

  // A keystroke changes one attribute on one input. Measuring every chat row and every message row
  // to find that out is work nobody asked for; the threshold is set from what the fixed path does,
  // not from a wish.
  expect(perKey, `${line} — a keystroke is measuring the lists`).toBeLessThan(20);
});

// Sending glued the feed to the bottom with a requestAnimationFrame loop that ran for a fixed
// 1200ms, reading `scrollHeight` and writing `scrollTop` on every frame — up to ~72 synchronous
// layouts of a 565-row feed, landing exactly when media is decoding and the composer is resizing.
// The stages it was covering all change a height, and there are already two ResizeObservers
// watching those heights.
test("a send does not pin the feed frame by frame", async ({ alice, seed }, testInfo) => {
  test.setTimeout(120_000);
  await instrumentLayout(alice);

  await alice.goto("/app");
  await alice.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected() && window.__edInstantNavReady,
    null,
    { timeout: 15_000 },
  );
  await alice.locator(`#conversations a.ed-convo[href$="/app/c/${seed.group_id}"]`).first().click();
  await alice.locator(`#message-scroll[data-conversation-id="${seed.group_id}"]`).waitFor();
  await alice.waitForTimeout(1200);
  for (let i = 0; i < 6; i++) {
    await alice.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 0 }));
    await alice.waitForTimeout(250);
  }
  await alice.evaluate(() => document.getElementById("message-scroll")?.scrollTo({ top: 10 ** 7 }));
  await alice.waitForTimeout(400);

  const rows = await alice.evaluate(() => document.querySelectorAll("#messages > *").length);
  const body = `cost-${Date.now()}`;
  await alice.locator("#composer-body").click();
  await alice.locator("#composer-body").fill(body);
  await alice.evaluate(() => (window.__layout = { rect: 0, scrollHeight: 0 }));
  await alice.keyboard.press("Enter");

  // The whole window the loop used to run for, plus room for the row to arrive.
  await alice.waitForTimeout(1500);

  const cost = await alice.evaluate(() => ({ ...window.__layout }));
  const line = `${rows} rows, one send: ${cost.scrollHeight} scrollHeight reads, ${cost.rect} getBoundingClientRect`;
  console.log(line);
  testInfo.annotations.push({ type: "measurement", description: line });

  // The message still has to land at the bottom — a cheap pin that does not pin is worse than the
  // loop it replaced.
  const landed = await alice.evaluate((text) => {
    const scroller = document.getElementById("message-scroll");
    const rows = [...document.querySelectorAll("#messages > [data-ts]")];
    const mine = rows.filter((r) => r.textContent.includes(text)).pop();
    if (!mine) return { found: false };
    const r = mine.getBoundingClientRect();
    const s = scroller.getBoundingClientRect();
    return { found: true, visible: r.bottom <= s.bottom + 2 && r.top >= s.top - 2 };
  }, body);
  expect(landed.found, "the sent message never appeared").toBe(true);
  expect(landed.visible, `${line} — the sent message is not on screen`).toBe(true);

  expect(cost.scrollHeight, `${line} — the send is still pinning frame by frame`).toBeLessThan(25);
});
