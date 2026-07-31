// Icons must actually render from the sprite (#511, part of epic #506).
//
// A sprite fails silently: a missing symbol, a 404 on the file, or a broken <use> reference all
// produce an EMPTY box rather than an error. Nothing in the build catches that — which is why the
// check here is that an icon occupies space and its sprite request succeeded.
const { test, expect } = require("../helpers/fixtures");

test("icons paint from the sprite, and the sprite is actually served", async ({ alice }) => {
  const requests = [];
  alice.on("response", (r) => {
    if (/icons.*\.svg/.test(r.url())) requests.push(r.status());
  });

  await alice.goto("/app");
  await alice.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 15_000,
  });
  await alice.waitForTimeout(1200);

  const stats = await alice.evaluate(() => {
    // Only icons that are actually RENDERED. The page carries plenty of hidden chrome — the
    // shared message menu, modals — and an icon inside display:none legitimately measures zero;
    // counting those made the first version of this test fail on 53 perfectly good icons.
    const icons = [...document.querySelectorAll("svg.ed-icon")].filter(
      (i) => i.getClientRects().length > 0,
    );
    const sized = icons.filter((i) => {
      const r = i.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    });
    return {
      total: icons.length,
      sized: sized.length,
      firstHref: icons[0]?.querySelector("use")?.getAttribute("href") || null,
    };
  });

  expect(stats.total, "no sprite icons on the page at all").toBeGreaterThan(3);
  expect(stats.sized, `${stats.total - stats.sized} icons collapsed to zero size`).toBe(stats.total);
  expect(stats.firstHref, "the <use> reference is missing").toMatch(/icons.*\.svg#hero-/);
  expect(requests.length, "the sprite was never fetched").toBeGreaterThan(0);
  expect(requests.every((s) => s === 200 || s === 304), `sprite responses: ${requests}`).toBe(true);
});
