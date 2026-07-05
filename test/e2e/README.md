# test/e2e — Playwright multi-user / multi-device harness

Drives the running dev app (`:4001`) as several simultaneous users across browser engines
and devices. See [`AUDIT.md`](AUDIT.md) for the findings this produced.

## Layout

```
playwright.config.js   5 projects: FF/Chromium/WebKit desktop + iPhone/Pixel mobile
seed.exs               idempotent users (alice/bob/carol) + DM/group/channel/room → .seed.json
global-setup.js        logs each user in once → .auth/<user>.json (session reused everywhere)
helpers/fixtures.js    alice/bob/carol = pages in separate contexts; send(), openMenu(), shot(),
                       per-page console/page-error/bad-response capture, auto-accept dialogs
fixtures/sample.txt    upload fixture (#149 file send)
specs/
  smoke.spec.js          auth + realtime DM
  surfaces.spec.js       DM / group / room / search / settings / channel-list tour
  messaging.spec.js      emoji, reactions, reply-quote, delete-tombstone, file send #149
  messaging-ext.spec.js  forward, mute/unmute, move-to-folder
  structure.spec.js      folders, groups, presence propagation, profiles
  corporate.spec.js      rooms (flat), threads, channel create
  corporate-ext.spec.js  new room, channel members, invite link + redemption
  settings-ext.spec.js   quick-react toggle, theme switch
  resilience.spec.js     disconnect → queue → reconnect → deliver
```

Image-upload flows (photo/album/lightbox) are intentionally not here — see AUDIT.md
"Harness limitations". `fixtures/sample*.png` are kept for manual/future use.

## Run

```
mix run test/e2e/seed.exs                                   # once (or after a DB reset)
npx playwright test --config test/e2e/playwright.config.js  # all projects
npx playwright test --config test/e2e/playwright.config.js --project=mobile-safari smoke.spec.js
```

`@playwright/test` + browsers resolve from `~/node_modules` (no repo install). The dev server
must be on `:4001`.

## CI

This harness is **not** a per-PR gate — realtime browser flows are slow and occasionally
flaky over a live socket, so a red run here doesn't block a merge (green-on-`main` therefore
does **not** mean "e2e passing"). It's run **on demand**: the `E2E (manual)` workflow
(`.github/workflows/e2e.yml`, `workflow_dispatch`) sets up Postgres, seeds, boots the dev app,
and runs a chosen spec on Chromium (default `smoke.spec.js`) — trigger it from the Actions tab.
`package-lock.json` is committed so the Playwright version is pinned across machines.

## Conventions that keep specs robust

- **Wait for connect before acting**: `await page.waitForFunction(() => window.liveSocket?.isConnected())`.
  A LiveView form/composer can be visible before the socket connects; a pre-connect submit is a
  no-op. `send()` already does this.
- **Submit via `requestSubmit`** on `#composer` (fires `phx-submit` regardless of Enter quirks
  that differ between the bubble and flat composers).
- **Open a message menu** with `openMenu(page, msgLocator)` — dispatches `contextmenu` (works on
  desktop + mobile), retries while the just-streamed hook attaches, returns the *visible* menu.
- **Scope to `#messages`** (not bare `getByText`) so you don't match the hidden sidebar preview.
- **Reaction chips** are siblings under the bubble — scope to the `.ed-msg` row.
- `.seed.json`, `.auth/`, `artifacts/`, `test-results/`, `playwright-report/` are gitignored.
