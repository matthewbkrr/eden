# ADR: Notification delivery beyond the browser (#218)

Status: **accepted strategy, not yet built** · Part of the notifications epic (#212).

This is an Architecture Decision Record. It fixes *how* eden will deliver a
notification when the open web page can't (the browser is closed) and on mobile —
**without** committing the implementation. The browser layer (#213 gating, #214
per-user prefs, #215 sound, #217 desktop, #216 tab badge) already ships; this records
where the remaining channels go and why, so the work lands as adapters on a stable
seam instead of ad-hoc integrations. Implementation follows in separate tickets.

---

## Context

The shipped layer only fires while an eden tab is open and connected: the server
gates recipients in `Eden.Chat` (#213 — self / muted / DND / non-followers dropped)
and broadcasts a locale-neutral `{:notify, payload}` on the user's topic; the open
LiveView turns that into a sound / OS notification per the viewer's toggles.

Two gaps remain, both "the page can't deliver":

1. **Closed browser / no tab open.** Nothing is listening, so nothing fires.
2. **Mobile.** No native app exists; a backgrounded mobile browser is effectively a
   closed browser.

The constraint that shapes both is the same one that made eden **invite-link auth
with no mailer**: eden runs from an overseas VPS, and delivery into Russia through
foreign intermediaries is unreliable. Any push path that depends on a service that's
degraded or blocked in RU is a non-starter as the *only* path.

## Decision 1 — Closed browser → a native desktop app, not Web Push

When no tab is open, delivery is the job of a future **native desktop application**
(Electron or Tauri), **not** Web Push + Service Worker.

- The desktop app holds a persistent connection to the same Phoenix channel the web
  client uses and raises **native OS notifications** — the same `{:notify}` payload,
  a different renderer. It reuses the entire server gating; only the transport and the
  OS-notification call are new.
- **Why not Web Push / Service Worker:** Web Push routes through the browser vendors'
  push services (Mozilla autopush, Apple, and **Google FCM for Chrome**). That drags
  the same foreign-intermediary / Google-Play-Services dependency back in, plus a
  Service Worker + VAPID + subscription-lifecycle surface — for a worse result than a
  process we control end-to-end. A desktop app also unlocks niceties Web Push can't
  (tray presence, badge counts, deep links, auto-launch).

This was an explicit product decision: closed-browser delivery is the desktop app's
job, full stop.

## Decision 2 — Mobile is per-platform, not "Firebase for everything"

- **iOS → APNs directly.** Apple Push Notification service is free, has no Google
  dependency, and works in RU. eden's backend signs a JWT and calls the APNs HTTP/2
  endpoint itself.
- **Android → FCM by default, with a RuStore Push / VK Push SDK fallback.** FCM is
  free but is delivered by **Google Play Services**, which is absent or degraded on a
  meaningful share of RU Android devices (Huawei, GMS-less builds, de-Googled ROMs) —
  the same overseas-dependency failure mode eden already designs around. So FCM is the
  default channel and **RuStore Push** (or VK Push SDK) is the fallback for devices
  where FCM can't deliver. The device tells us at registration which channel it can use.

There is **no "Firebase for everything."** We never adopt Firebase as a platform.

### Cost — clearing up the "Firebase is expensive" concern

Raised by leadership; worth recording the answer. **FCM and APNs push messages are
free** (no per-message fee, effectively unlimited). The parts of Firebase that cost
money are Firestore, Cloud Functions, and Auth/other managed services — none of which
we use. eden's own Phoenix backend calls the **FCM HTTP v1** and **APNs HTTP/2**
endpoints directly, so there is no Firebase platform bill and no managed-service
lock-in. The cost objection does not apply to the push transport itself.

## Architecture — one context, an adapter behaviour

Mirror the proven `Eden.Storage` seam (`Eden.Storage.Adapter`, swappable local-disk /
S3 without touching callers).

```
Eden.Chat  --(already gated #213)-->  Eden.Notifications  --fan out-->  adapters
                                            |                              |
                                      notification_targets          Notifications.Adapter
                                      (per-user PUSH devices,       ├─ Web (in-tab)  ← live socket, no stored row
                                       token NOT NULL)              ├─ Desktop (native app)
                                                                    ├─ APNs  (iOS)
                                                                    ├─ FCM   (Android, default)
                                                                    └─ RuStore / VK (Android, fallback)
```

- **`Eden.Notifications` context.** The single place that takes an
  already-gated notification and decides which of a user's **targets** to deliver to.
  Chat stays unaware of transports; Notifications stays unaware of *who* should hear
  (Chat already decided that). The current in-tab path becomes the **Web adapter** —
  the first implementation of the same behaviour, so today's code is the reference, not
  a special case.
- **`Notifications.Adapter` behaviour.** `deliver(target, payload)` per transport,
  exactly like `Storage.Adapter`. New transports are new modules + config, no caller
  changes. The locale-neutral payload already broadcast on the user topic is the
  contract the adapters render.
- **`notification_targets` table** — one row per user **push device**:
  `user_id`, `kind` (`desktop | apns | fcm | rustore | vk`), `token` (the device's
  push token / id, **`NOT NULL`**), `enabled`, `last_seen_at`, timestamps; unique on
  `(user_id, kind, token)`. A user has many (phone + laptop + desktop app).
  Registration writes a row; stale/invalid tokens (APNs/FCM report them) are pruned.
  The in-tab **Web** adapter has **no** stored row here — it has no device token and
  delivers over the live LiveView/PubSub connection — so the table is push-only and
  `token` is never null. (That matters: a nullable token would defeat the unique index,
  since Postgres treats NULLs as distinct, letting duplicate web rows accumulate.) This
  is the only new persistent state the strategy requires.

### What is reused, unchanged

- **Gating (#213).** Recipient selection — mute / DND / focus / thread-following —
  stays in `Eden.Chat`. Adapters deliver to an *already-correct* recipient set; they
  never re-decide who.
- **Per-user prefs (#214).** `notify_sound` / `notify_desktop` extend to per-kind
  toggles on the same `chat_folder_prefs` row (e.g. `notify_push`) when push lands.
- **The "no badge past mute" / focus-suppression invariants** apply before the payload
  ever reaches Notifications, so every transport inherits them for free.

## Consequences

- **Positive.** One seam, many transports; RU-resilient by construction (APNs direct +
  RuStore fallback, no single Google chokepoint); no Firebase platform adoption or
  bill; the desktop app reuses ~all server logic; the in-tab path is just the first
  adapter, so the abstraction is validated on day one.
- **Costs / risks.** A native desktop app is real client work (packaging, signing,
  auto-update per OS). Maintaining **two** Android channels (FCM + RuStore/VK) is
  ongoing surface. APNs/FCM credential and token-lifecycle management is operational
  work. Mobile ultimately needs **native apps** (or at least a thin wrapper) to hold
  push tokens — a backgrounded mobile web page can't.
- **Neutral.** None of this changes the shipped browser behavior; it's purely additive
  behind the new context.

## Rollout (future tickets, not this ADR)

1. `Eden.Notifications` context + `Notifications.Adapter` behaviour + the
   `notification_targets` table; refactor today's in-tab delivery into the **Web
   adapter** (no behavior change — validates the seam).
2. **Desktop app** (Tauri/Electron) + a Desktop adapter (or it simply rides the Web
   adapter's channel and renders natively).
3. **iOS:** native app / wrapper that registers an APNs token; APNs adapter.
4. **Android:** FCM adapter (default) + RuStore/VK adapter (fallback); device declares
   its channel at registration.

Each is its own ticket with its own DoD. This document is the contract they build to.
