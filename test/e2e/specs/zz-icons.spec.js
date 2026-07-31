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
    // getBBox(), not getBoundingClientRect(). The outer <svg> keeps whatever width/height the
    // size utility gave it even when <use> resolves to NOTHING — so the box stays honest-looking
    // while the icon paints nothing at all. getBBox() measures the rendered geometry, which is
    // zero exactly in that case. The first version of this test asked the wrong one and passed
    // with a symbol deleted from the sprite (#539 review).
    const sized = icons.filter((i) => {
      try {
        const b = i.getBBox();
        return b.width > 0 && b.height > 0;
      } catch (_e) {
        return false;
      }
    });
    return {
      total: icons.length,
      sized: sized.length,
      firstHref: icons[0]?.querySelector("use")?.getAttribute("href") || null,
    };
  });

  expect(stats.total, "no sprite icons on the page at all").toBeGreaterThan(3);
  expect(stats.sized, `${stats.total - stats.sized} of ${stats.total} icons paint nothing — the sprite reference resolves to no geometry`).toBe(stats.total);
  expect(stats.firstHref, "the <use> reference is missing").toMatch(/icons.*\.svg#hero-/);
  expect(requests.length, "the sprite was never fetched").toBeGreaterThan(0);
  expect(requests.every((s) => s === 200 || s === 304), `sprite responses: ${requests}`).toBe(true);
});

// The hooks that build markup by hand cannot use the `<.icon>` component, so they go through
// `window.edIcon`. That helper needs the sprite URL from the server — prod digests the filename —
// and reads it off `<html data-icons>`. Break either half and every JS-injected icon (the send
// tick, the cancel button, the failed-send warning, the navigation skeleton) turns into a blank
// gap without a single error in the console. This is the same silent failure the sprite invites,
// one layer down.
test("icons injected by hooks paint too", async ({ alice }) => {
  await alice.goto("/app");
  await alice.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 15_000,
  });

  const result = await alice.evaluate(() => {
    if (typeof window.edIcon !== "function") return { error: "window.edIcon is not defined" };

    const host = document.createElement("div");
    // Off the layout but still rendered: `display:none` would zero the geometry for everyone and
    // make this pass on a broken sprite too.
    host.style.cssText = "position:fixed;left:-9999px;top:0";
    document.body.appendChild(host);

    // One per size the hooks actually ask for, so a wrong variant suffix shows up here.
    const names = [
      "hero-check-micro",
      "hero-x-mark-micro",
      "hero-exclamation-circle-micro",
      "hero-exclamation-circle-mini",
      "hero-arrow-left-mini",
      "hero-paper-airplane-micro",
    ];
    host.innerHTML = names.map((n) => window.edIcon(n, "size-4")).join("");

    const blank = names.filter((_, i) => {
      try {
        const b = host.children[i].getBBox();
        return !(b.width > 0 && b.height > 0);
      } catch (_e) {
        return true;
      }
    });

    const href = host.children[0]?.querySelector("use")?.getAttribute("href") || "";
    host.remove();
    return { blank, href, total: names.length };
  });

  expect(result.error, result.error).toBeUndefined();
  expect(
    result.href,
    `the sprite URL never reached the helper (href="${result.href}") — check <html data-icons>`,
  ).toContain("/images/icons.svg");
  expect(
    result.blank,
    `${result.blank.length} of ${result.total} hook-injected icons paint nothing: ${result.blank.join(", ")}`,
  ).toEqual([]);
});
