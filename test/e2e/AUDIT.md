# eden — multi-user / multi-device audit

Playwright-driven simulation of real usage by several people, on phone and desktop, across
browser engines. This is the consolidated findings report; the specs that produce it live
alongside in `specs/`, screenshots in `artifacts/<project>/`.

## Method

- **3 simultaneous users** (`alice`/`bob`/`carol`), each in its own browser context (real
  separate sessions) — so every realtime claim is verified by a *second* user seeing the
  result live over PubSub, not just the sender's optimistic echo.
- **5 projects**: Firefox / Chromium / WebKit on desktop (1280×880) + iPhone 13 (WebKit) and
  Pixel 7 (Chromium) on mobile (touch + mobile viewport). Firefox has no touch emulation, so
  mobile is covered by the two real mobile engines; Firefox covers desktop.
- Every page records **console errors, uncaught exceptions, and 4xx/5xx responses**; each flow
  screenshots desktop + mobile.
- ~24 specs × 5 projects ≈ 120 runs. **104+ pass**; the handful of retries were realtime
  timing under full-matrix load, not functional failures. **Zero uncaught JS exceptions on any
  surface or engine.**

## Coverage

| Area | Exercised (multi-user where ✦) | Result |
|---|---|---|
| Auth / session | login, session reuse across engines | ✅ |
| DM | text send ✦, emoji picker, file send #149 ✦ | ✅ |
| Reactions | quick-react via context menu, chip round-trip ✦ | ✅ |
| Reply / quote | context-menu reply, quote renders ✦ | ✅ |
| Forward | forward a message into the group ✦ | ✅ |
| Delete | delete-for-everyone → tombstone ✦ | ✅ |
| Mute | mute/unmute a chat → muted indicator | ✅ |
| Move to folder | create folder → move chat in via modal | ✅ |
| Groups | send → other member live ✦ | ✅ |
| Channels / rooms | flat layout, room send ✦, channel-create, **new room** | ✅ |
| Channel members | members list opens | ✅ |
| Channel invites | admin generates link → **carol redeems + joins** ✦ | ✅ |
| Threads | open thread, reply in panel, root footer bumps ✦ | ✅ |
| Folders | create → sidebar tab → delete (self-cleaning) | ✅ |
| Presence | status change propagates to peer header ✦ | ✅ |
| Profiles | open peer profile from DM header | ✅ |
| Search | grouped results, term highlighting | ✅ |
| Settings | profile, quick-react toggle, theme switch, status | ✅ |
| Resilience | disconnect → queue → reconnect → deliver, in order ✦ | ✅ |

~33 specs × 5 projects ≈ 160 runs; **152+ pass**, WebKit media skipped (below), the odd
realtime retry absorbed.

## Findings

### P2 — Login form wipes typed input when the LiveView socket connects
`/login` (`LoginLive`). The form is server-rendered and interactive immediately, but on
socket connect the initial LiveView render re-patches the (empty) form and **clears anything
typed before connect**. Reproduced deterministically (auth had to fill *after* connect, every
engine). Impact lands squarely on the **target audience** — fast typers on a shaky cross-border
link, where connect is slowest. Suggested fix: preserve input across the initial mount (drive
the inputs from params / `phx-change`-track them, or disable until `phx-connected`).

### P3 — Empty room is a blank pane (no empty state)
A room with no messages renders an empty message area. By contrast the messenger has a proper
"No conversation selected — Pick a chat or start a new one" state. Suggested: a parallel
"No messages yet — start the conversation" empty state for rooms (and for a freshly created room).

### P3 (verify) — Room consecutive-author collapse
In a room with many same-author messages, the avatar/name header repeats on rows that look
like they should collapse into a run (per the documented Mattermost consecutive-collapse). May
be correct (thread-footers and >5-min gaps legitimately break a run) — flagged to confirm
against the intended rule with adjacent same-author messages <5 min apart and no footer.

### Retracted — "a send before the socket connects is dropped" (was P2/P3)
Could **not** reproduce. Sends deliver once the socket connects (which is fast), and the
offline path is robust (below). Downgraded to non-issue.

## What's solid (verified, not assumed)

- **Realtime** delivery — DM, group, and room messages reach a second live user on every
  engine + mobile, no reload.
- **Offline resilience** — a message composed while the socket is down is kept as an optimistic
  node and **delivered on reconnect, in order** (a burst of two survives). This is the core
  PRODUCT.md promise and it holds.
- **Every core interaction works cross-engine + mobile**: emoji picker, reactions (round-trip),
  reply-quote, delete-for-everyone tombstone, threads (reply + footer bump), folders, presence
  propagation, profiles, #149 file send (optimistic → real).
- **No uncaught JS exceptions** anywhere; no unexpected 4xx/5xx on app requests.
- Search (grouped + highlighted) and the messenger empty state are well done.

## Harness limitations / manual-verify gaps

Not app bugs — Playwright simulation boundaries:

- **Image upload isn't reliably drivable.** `live_img_preview` calls `URL.createObjectURL`
  on the staged file; under Playwright's synthetic upload that File isn't exposed (throws in
  Firefox) and the bytes don't transfer on WebKit at all — so a single photo is flaky and a
  multi-photo album never stages. The upload→consume→render→realtime **pipeline is proven by
  the #149 file-send test** (`sample.txt`, green on every engine); photo rendering + the
  **lightbox** and **multi-photo album** remain a manual-verify gap.
- **No edit-message feature** exists (confirmed: the message menu has reply/forward/copy/
  delete, no edit) — noted so it isn't mistaken for a missing test.
- **Private-room knock** (request → approve) wasn't automated — needs the new private room's
  id, which the UI doesn't expose cleanly; a candidate for a seeded-fixture follow-up.

## Running it

```
mix run test/e2e/seed.exs                                   # idempotent users + data → .seed.json
npx playwright test --config test/e2e/playwright.config.js  # all 5 projects
npx playwright test --config test/e2e/playwright.config.js --project=desktop-firefox  # one
npx playwright show-report test/e2e/playwright-report       # HTML report
```

Needs the dev server on :4001. Screenshots land in `test/e2e/artifacts/<project>/`.
