// Instant cross-LiveView navigation (#445 wave 2) — the app ↔ settings hop is a full
// LiveView remount (navigate), the heaviest transition in the app: a tap changed
// NOTHING on screen for a round-trip. This module answers in one frame, page-level:
//
// - on a qualifying click (or history traversal) it stashes the CURRENT page's
//   rendered root and paints the TARGET page's cached root over the viewport —
//   a pixel replica of its last render — or a neutral shimmer shell when cold;
// - the real navigate proceeds underneath; phx:page-loading-stop (new view mounted)
//   fades the cover out.
//
// Lives OUTSIDE any LiveView (app.js) because the interception must survive the
// remount that kills every colocated hook. Same trust model as the message cache:
// only our own prior server render, display-only (pointer-events: none), scripts
// and ids stripped on adoption, never authoritative — the live page replaces it
// within a round-trip. Caches are window-scoped (die with the tab, never at rest).

const CAP = 4; // pages worth keeping (app, settings — headroom for future targets)

const store = () => (window.__edPageCache = window.__edPageCache || new Map());

// The page class currently ON SCREEN. Kept explicitly (#447 review): popstate fires
// for every in-app history traversal (chat -> chat back), where location alone can't
// tell a cross-world hop from a same-world one — guessing inverted `from` and stashed
// the chat DOM under the settings key, corrupting that cache.
let current = null;

// Page class for a pathname: the two remount-separated worlds we cover today.
function pageKey(path) {
  // Settings first: the authed alias lives UNDER /app (#445) — same page class.
  if (/^\/(app\/)?settings(\/|$)/.test(path)) return "settings";
  if (/^\/(app|channels)(\/|$)/.test(path)) return "app";
  // The admin panel is its own remount-separated world and was the one authed page left out
  // (#521): reaching it showed a blank frame for the whole round trip, with no shimmer and no
  // cached replica on the way back. Same treatment as the other two — window-scoped, dies with
  // the tab, nothing at rest.
  //
  // NOT covered by a test, deliberately: `/admin` is unreachable on the e2e stand, because the
  // `:require_admin` gate sends an admin without TOTP to Settings to enrol first, and the seeded
  // account has no second factor. A test that cannot reach the page can only re-implement this
  // regex and call itself a check — which is the shape of a test that proves nothing.
  if (/^\/admin(\/|$)/.test(path)) return "admin";
  return null;
}

function stash(key) {
  const root = document.querySelector("[data-phx-main]");
  if (!root || !key) return;
  const s = store();
  s.delete(key);
  s.set(key, root.outerHTML);
  while (s.size > CAP) s.delete(s.keys().next().value);
}

let cover = null;
let timer = null;

function dismiss() {
  const ov = cover;
  if (!ov) return;
  clearTimeout(timer);
  cover = null;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    ov.remove();
    return;
  }
  ov.classList.add("ed-page-skel--out");
  let done = false;
  const fin = () => {
    if (!done) {
      done = true;
      ov.remove();
    }
  };
  ov.addEventListener("transitionend", (ev) => {
    if (ev.target === ov && ev.propertyName === "opacity") fin();
  });
  setTimeout(fin, 300);
}

function paint(key) {
  if (cover) {
    cover.remove();
    cover = null;
    clearTimeout(timer);
  }
  // A dismissed cover fades for ~300ms after `cover` is nulled — a rapid re-hop must
  // not stack a second one over it (or leave two for anything asserting on the class).
  document.querySelectorAll(".ed-page-skel").forEach((n) => n.remove());
  const ov = document.createElement("div");
  ov.className = "ed-page-skel";
  ov.setAttribute("aria-hidden", "true");
  const cached = store().get(key);
  let adopted = false;
  if (cached) {
    try {
      const tpl = document.createElement("template");
      tpl.innerHTML = cached;
      const node = tpl.content.firstElementChild;
      node.querySelectorAll("script").forEach((n) => n.remove());
      node.querySelectorAll("[id]").forEach((n) => n.removeAttribute("id"));
      node.removeAttribute("id");
      // The clone must never look like a LiveView root to anything.
      for (const a of Array.from(node.attributes)) {
        if (a.name.startsWith("data-phx")) node.removeAttribute(a.name);
      }
      ov.appendChild(node);
      adopted = true;
    } catch (_e) {
      adopted = false;
    }
  }
  if (!adopted) {
    // Cold shell: neutral page scaffold — top bar + content blocks. Deliberately
    // generic (no copy): it reads as "the next screen is coming up", not as fake UI.
    ov.innerHTML =
      '<div class="ed-page-skel__shell">' +
      '<div class="ed-page-skel__bar"><span class="ed-nav-skel__av ed-skel-shimmer"></span>' +
      '<span class="ed-nav-skel__bubble ed-skel-shimmer" style="width:32%"></span></div>' +
      [56, 72, 44, 64, 38]
        .map(
          (w) =>
            '<div class="ed-page-skel__row"><span class="ed-nav-skel__bubble ed-skel-shimmer" style="width:' +
            w +
            '%"></span></div>',
        )
        .join("") +
      "</div>";
  }
  document.body.appendChild(ov);
  cover = ov;
  timer = setTimeout(dismiss, 15000);
}

export function initInstantPages() {
  // Capture-phase, like the in-LiveView hook: see the tap before anything else.
  document.addEventListener(
    "click",
    (e) => {
      if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = e.target.closest && e.target.closest("a[href]");
      if (!a) return;
      // Links that don't replace THIS document must not strand a cover (#447 review).
      if (e.defaultPrevented) return;
      if (a.target && a.target !== "_self") return;
      if (a.hasAttribute("download")) return;
      const from = pageKey(location.pathname);
      const to = pageKey(a.getAttribute("href"));
      // Only CROSS-page hops (a remount) — in-page navigation is the LiveView
      // hook's territory (rail, chats, sections are patches).
      if (!from || !to || from === to) return;
      stash(from);
      paint(to);
      // No preventDefault: the real navigate must fire.
    },
    true,
  );

  current = pageKey(location.pathname);

  // Browser/Android back between the two worlds gets the same instant answer.
  // Same-world traversals (chat -> chat back is a popstate too) pass through
  // untouched — that's the in-LiveView hook's territory (#447 review).
  window.addEventListener("popstate", () => {
    const to = pageKey(location.pathname);
    if (!to || cover != null || to === current) return;
    // The DOM still shows the page we're LEAVING — stash it under its own key.
    stash(current);
    if (store().has(to)) paint(to);
  });

  window.addEventListener("phx:page-loading-stop", () => {
    current = pageKey(location.pathname);
    if (!cover) return;
    dismiss();
    // Keep the fresh render warm for the next hop (idle: off the settle frame).
    const idle = window.requestIdleCallback || ((f) => setTimeout(f, 200));
    idle(() => stash(pageKey(location.pathname)));
  });
}
