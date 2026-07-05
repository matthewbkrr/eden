# CONTEXT.md — eden domain glossary

Single-context repo: this is the one glossary; decisions live in `docs/adr/`.
It grows lazily — terms are added when a design session actually resolves
them, not speculatively. Use these words exactly; don't drift to synonyms.

## Identity & access (ADR-0002)

- **Invite (invite link)** — the only way into eden: a hash-at-rest token with
  expiry, max-uses, and revocation, redeemed transactionally (`FOR UPDATE`).
  Registration and channel invites share the pattern.
- **Invite-gated perimeter** — the product decision that there is **no open
  self-registration**; everyone (employees, client staff) enters via an
  invite. This is what keeps eden inside the company's existing PII-operator
  posture (no new 152-FZ consents / localization / РКН delta).
- **B2C gate** — the named price of ever opening self-registration: RU-hosted
  DB, consent flow, updated РКН notification, processing policy. A business
  decision, not an engineering default.
- **System of record** — the eden `users` table. External providers never own
  identity; they only verify logins.
- **Identity (login channel)** — a `(provider, sub)` credential linked to one
  eden user (future `identities` table: `password`, `vk`, `yandex`,
  `corp_oidc`). Introduced with the first external provider, not in advance.
- **Login-link** — voluntarily attaching VK ID / Yandex ID to an existing
  invite-created account, for convenience login and self-service recovery.
  Not a registration method.
- **Org (organization)** — the future tenant boundary above Channels (RFC:
  environments/slugs). One person holds **one global account** with
  memberships in N orgs; isolation is membership-scoping, not separate login
  databases.
- **Auth policy (per-org)** — the org-level setting for which login methods
  grant entry/login there (e.g. "corp SSO required"); reserves `mfa_required`.
- **Client link** — an org-scoped multi-use invite for one client company
  (max-uses + expiry + default role); its redemption creates user + org
  membership in one transaction.
- **Coordinator** — a client-side member with delegated, capped rights to
  mint/revoke invites for their own org only.
- **Reset link** — an admin-issued, one-time, short-expiry token bound to a
  specific user for password recovery; same machinery as invites, handed over
  any existing channel.
- **Deactivation** — an admin sets `users.active = false` (ADR-0002 Decision 8,
  manual half): every session is revoked and login is refused (indistinguishable
  from a wrong password — account state isn't leaked) until an admin
  **reactivates**. Same authority as reset links (a plain admin ↛ a super_admin;
  never yourself). Distinct from **hard delete / erasure** (a separate concern)
  and from the trigger-gated **upstream-IdP auto-deactivation** (Decision 8's
  second half, awaiting a real IdP).

## Messaging (established; see CLAUDE.md for detail)

- **Conversation** — first-class thread entity backing DMs, groups, and rooms.
- **Room** — a `Conversation` with a `channel_id`; corporate layer, flat
  Mattermost-style UI. **Threads are rooms-only.**
- **Channel** — the corporate grouping (≈ Mattermost team) of rooms, with
  `owner | admin | member` roles.
- **Delete for me / delete for both** — per-user hide vs sender-only
  soft-delete tombstone with forward-safe blob cleanup.
- **Forward (carry-and-drop)** — pick a message up onto the composer, drop it
  by sending; multi-select carries an ordered list.

## Notifications (ADR-0001)

- **Notification** — an alert about a new message/reply. A locale-neutral
  **payload** map, produced solely by `Eden.Chat` (`notify_payload/1`) and
  rendered by adapters; its shape is the delivery **contract**, documented in
  one place (`Eden.Notifications` moduledoc).
- **Recipient set** — *who* hears about a message: decided in `Eden.Chat` (the
  #213 gating — sender/left/mute/DND, and thread-followers for a reply), never
  in an adapter. Adapters deliver to an already-correct set.
- **Notification adapter** (`Eden.Notifications.Adapter`) — a delivery transport
  with one `deliver(user_id, payload)` callback, mirroring `Storage.Adapter`.
  Configured as a fan-out list; new transports are new modules, no caller change.
- **Web adapter** (`Eden.Notifications.Web`) — the in-tab transport: broadcasts
  `{:notify, payload}` on the **notify topic** (`user:<id>:notify`) that open
  LiveViews subscribe to. No stored device row — it rides the live connection.
- **Notify topic** — `user:<id>:notify`, separate from the `user:<id>:chat`
  sidebar-sync topic so pages that only want alerts aren't flooded with chatter.
- **Push target** *(planned, ADR-0001)* — a per-user push **device** row
  (`desktop | apns | fcm | rustore | vk`, token NOT NULL). Not yet built; the
  Web adapter has no target row.
