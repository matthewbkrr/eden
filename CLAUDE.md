# CLAUDE.md — eden

Project rules and conventions for eden, a realtime messenger (text + photos)
built on Elixir/Phoenix. This file holds **project decisions**; low-level
Elixir/Phoenix/LiveView/Ecto coding rules live in [`AGENTS.md`](AGENTS.md) and
must also be followed.

## Stack & versions

- **Elixir** `~> 1.19` (local: 1.19.5) on **Erlang/OTP** 29 locally, **OTP 28** in CI
  (the line officially supported by Elixir 1.19 — see `.github/workflows/ci.yml`).
- **Phoenix** 1.8 · **Phoenix LiveView** 1.1 · **Bandit** HTTP server.
- **Ecto** + **PostgreSQL 16**.
- Realtime via **Phoenix Channels / LiveView** + **Phoenix.PubSub**.
- **Req** for HTTP (never httpoison/tesla/httpc). **No mailer / no email** —
  auth is invite-link based by design (delivery from an overseas VPS to RU
  inboxes is unreliable); never add Swoosh or any email dependency.
- **Tailwind v4** + **esbuild** for assets.
- Media: **`:image`/vix** (bundled libvips, no system dep) for image thumbnails +
  avatar processing. **`ffmpeg`/`ffprobe`** (system dependency — in the Docker
  runtime image and the CI test job) for video poster frames + duration, shelled
  out via `System.cmd`. Video tests are tagged `:ffmpeg` and skipped where the
  binary is absent.
- Quality tooling: **credo**, **sobelow**, **dialyxir**, **mix_audit**.

## Architecture

The app is split into bounded **contexts** under `lib/eden/`, with the web layer
under `lib/eden_web/`. The web layer calls contexts; contexts never call the web
layer. Each schema lives in its owning context. (These contexts are the target
design — built incrementally as features land.)

- **Accounts** — users, authentication, profiles. A profile is editable
  `display_name` + `bio` (`profile_changeset`) plus an avatar: the upload is
  processed (center-cropped square JPEG, metadata stripped) and persisted through
  **Storage** as `avatar_key`. `username` is both the login **and** the public
  `@tag`; it is **self-chosen and renameable** (`username_changeset` /
  `update_username/2`, #173 — re-validated unique, sessions survive since tokens
  reference the user id). **Managed identity fields** (`corp_email`, `position`
  (Должность), `structure`, + the `external_id`/`identity_source`/`managed_by`/
  `directory_synced_at` sync seams, #173) are **admin-/sync-owned**: written ONLY
  through `managed_changeset` / `apply_managed_fields/3` (admin-scoped, `admin?`-checked
  in the context #262 — the admin panel #174 or a future directory sync), never the
  user's profile form — the split is the eden-as-
  system-of-record model of ADR-0002/#172. Users also carry a global **platform
  role** (`member | admin | super_admin`, #174) — distinct from the per-channel
  `owner|admin|member` roles; it gates the admin panel and is set only via
  `set_user_role/3` (super-admin-only; the **last** super_admin can't be removed —
  locked `FOR UPDATE` — so admin can never be locked out; a `role` CHECK constraint
  backs the changeset). `admin?/1` is the gate predicate. The **admin panel**
  (`/admin`, `EdenWeb.AdminLive`, `:require_admin` on_mount — enforced at mount;
  AdminLive is patch-free so mount covers it, a future patch route must re-check — and a
  mid-session demotion ejects the actor to `/settings` via
  their own `{:user_updated}`, since on_mount doesn't re-run, #262) is where admins edit
  people's managed fields (`apply_managed_fields/3`) and a super_admin assigns roles
  (`set_user_role/3`); a shielded link surfaces it in Settings for admins only.
  **Passwords & recovery** (#232): a user changes their password in Settings
  (`change_password/3` verifies the current one, then **revokes every session** —
  the UI signs them back in) or hits "log out everywhere" (`revoke_all_user_sessions/1`);
  an admin mints a one-time **reset link** from `/admin` (`create_password_reset/1`)
  redeemed at `/reset/:token` (`reset_password_with_token/2` — `FOR UPDATE`,
  single-use, revokes sessions). Every hash-at-rest token flow (invites + reset)
  shares `Eden.Tokens` (generate/hash). Still no email.
  **Deactivation** (#251, ADR-0002 Decision 8 manual half): an admin flips
  `users.active` from `/admin` (`deactivate_user/2` — sets `active=false` **and**
  `revoke_all_user_sessions/1`, so live sessions are booted via the #256
  `:sessions_revoked` signal and the person can't log back in; `reactivate_user/2`
  restores it). Login is refused in three places — `get_user_by_username_and_password/2`
  (indistinguishable from a wrong password, state not leaked), `get_user_by_session_token/1`
  (defense-in-depth for a surviving token), and the TOTP second-factor step — and a
  deactivated user can't be issued a reset link. Same authority as reset links
  (`can_reset_password?/2`: a plain admin ↛ a super_admin; never yourself). The
  **upstream-IdP auto-deactivation** half of Decision 8 stays trigger-gated (no IdP yet).
  **Permanent deletion / anonymization** (#303, right-to-erasure): deactivation is
  reversible, deletion is not. `delete_user_permanently/2` (admin, from `/admin` behind a
  two-step confirm; same authority; never yourself; the **last super_admin is locked**)
  scrubs all PII, credentials, avatar and platform role, replaces `hashed_password` with a
  random hash (the column is NOT NULL), frees the `@tag` (`deleted-<id>` — hyphen, so no
  collision with a real handle), sets `active=false`, and stamps `users.deleted_at`, all in
  one `FOR UPDATE` transaction; sessions are revoked and the avatar blob reclaimed after
  commit. The **row survives** so the person's messages stay attributed as «Удалённый аккаунт»
  (shared history isn't holed — the anonymize-not-cascade choice); deleted rows are filtered
  from `list_users`/`list_other_users`/`create_conversation`/room+channel adds, `reactivate_user/2`
  refuses them, and a pending knock from a since-deleted requester is auto-declined (never
  re-added). After the Accounts scrub, the web layer calls `Chat.scrub_deleted_user_content/1`
  (contexts don't reach into each other) to scrub the **denormalized** name from system-message
  `meta` (knock requester, member add/remove — the latter carry `user_id` for this) and purge
  the person's private folders. Reuses the #251 login/session gates via `active=false`.
  **TOTP two-factor** (#250, ADR-0002 Decision 7): a user enrolls in Settings
  (`setup_totp/1` → scan QR / manual key → `activate_totp/3` confirms a code, reveals
  one-time **backup codes**); at sign-in an enrolled user's password step stashes a
  short-lived pending marker and hands off to a **second-factor challenge**
  (`/login/totp`, `EdenWeb.TotpLive` → `UserSessionController.totp/2`) before any
  session token is issued — a stolen password alone can't get in. `verify_totp/2`
  (RFC-6238 via **`nimble_totp`**, replay-blocked by `totp_last_used_at`) or
  `consume_backup_code/2` completes login; the challenge POST shares the #236 login
  throttle. The secret is **encrypted at rest** through `Eden.Vault` (hand-rolled
  AES-256-GCM, key from env — never the DB). `disable_totp/2` needs a valid code and
  is **refused for admins** — their factor is **mandatory**: the `:require_admin`
  on_mount gate bounces an admin without TOTP to Settings to enroll before any admin
  power is reachable. Lost-device recovery is admin-mediated — `admin_reset_totp/2`
  (same authority as reset links: a plain admin can't touch a super_admin) clears a
  person's factor from `/admin`, after which an admin target must re-enroll at the gate.
  **Registration hardening** (#306): the invite acceptance form (`EdenWeb.InviteLive`)
  requires a **repeat-password** confirmation (`validate_confirmation(:password, required:
  true)` in `registration_changeset`) and both password fields carry a **show/hide toggle**
  (`ed_password_field` + the `.PasswordReveal` colocated hook, whose `updated/0` re-applies
  the client-owned reveal state after each validate patch). After a successful sign-up the
  new user is routed through a **post-signup 2FA onboarding step** (`/welcome/two-factor`,
  `EdenWeb.WelcomeTotpLive`) — an offer to enroll now (reusing `setup_totp`/`activate_totp`)
  or **skip** to the app; it forwards any `user_return_to`, re-validated local via
  `EdenWeb.SafePath.local_path/2` (RFC-3986 parse, shared with `LocaleController`).
- **Chat** — the messaging domain. **Conversations are a first-class entity**, not
  an implicit pair of users:
  - `Conversation` — a thread; the same model backs both 1:1 and group chats.
    **Delete chat** (`delete_conversation/2`) is per-user: it sets the member's
    `left_at` to hide the thread from their list (`list_conversations/1` filters
    `left_at`). For a **1:1**, new activity clears `left_at` so the chat
    re-surfaces (messaging someone back re-opens it); **leaving a group is
    permanent** (`resurface_direct/1` only un-hides non-group threads, and
    `notify_members/1` skips members who left). The mark-left + last-member check
    + GC run in one transaction; when the last member has left the conversation is
    **garbage-collected** — the DB cascades messages/memberships/attachments and
    the orphaned blobs are deleted via the shared `delete_unreferenced_blobs/1`
    (blobs a forward elsewhere still references are spared).
  - `Membership` — join between a `Conversation` and a user (role, joined_at,
    last_read, `left_at` for per-user chat deletion, etc.). A conversation has
    many memberships.
  - `Message` — belongs to a conversation and a sender; carries text and/or an
    ordered **album** of `Attachment`s (referenced by storage key, see Storage).
    Lifecycle: **delete for me** hides it for one user (`message_deletions` join,
    filtered out of `list_messages/3`); **delete for both** (sender only)
    soft-deletes via `deleted_at`, removing the message for everyone, and cleans up
    every attachment's unshared blobs; **forward** copies it into another conversation
    (re-referencing the same blobs in order, `forwarded_from_id` for attribution) —
    `forward_message/4` takes any conversation the user belongs to (DM, group, **or room**)
    and, with a `root_id`, drops the copy **inside a thread** as a reply (bumping the root +
    follow tracking, like `create_reply`). The UI is **carry-and-drop** (Mattermost-style,
    not a target modal): "Forward" picks the message up (a plaque on the composer, `pending_forward`),
    the `.ForwardCarry` hook mirrors the id to sessionStorage so the plaque survives navigation
    across DMs/rooms/channels (each mount re-hydrates via `forward_rehydrate`), and Send drops it —
    from the main composer into the open conversation, from the thread composer into that thread.
    **Multi-select** (Telegram-style) reuses this: the context-menu "Select" opens a selection
    mode over the main stream (`selection` MapSet, server-owned; the `.SelectSync` hook reflects
    it onto `phx-update="stream"` rows, which don't re-render on a plain assign change), with a
    bottom action bar — **Forward** (carries the whole ordered selection, `pending_forward` is a
    list; `forward_message/4` per id), **Copy** (assembled client-side within the click gesture,
    Firefox-safe), and **Delete** (a confirm sheet: "for everyone" only when every selected
    message is the user's own, `delete_messages_for_both/2` re-checks authorship per message).
    **edit** (`#164`, author-only) revises a message's text or, for a
    media message, replaces its album AND/OR caption (`edit_message` / `edit_message_media`
    — keep/drop existing attachments + append new, order preserved, forward-safe blob
    cleanup; rejects a tombstone/system message), stamping `edited_at` (no window,
    Telegram-style — the UI shows "(edited)" + time) and broadcasting `{:message_edited}`
    which restreams the row everywhere (thread vs main routed by `root_id`); a text
    message edits inline in the composer (banner + pre-fill — a thread reply in the
    thread composer, targeted so the two composers never cross-fill; attaching media while
    editing a text message CONVERTS it into a media message via `edit_message_media`, the
    edit text becoming the caption), a media message opens the edit-media modal (removable
    existing tiles + an add-photos tile + the caption);
    **quote-reply** (`#71`, `reply_to_id` self-ref — distinct from
    threads' `root_id`) renders a tappable quote of the referenced message above
    the body (DMs + rooms), composed via swipe-left, the room toolbar's reply
    arrow, or the context-menu "Reply"; `reply_to_id` is set by the context only
    after validating the target is in the same conversation and visible to the
    sender (`valid_reply_to_id/3`), `nilify_all` on hard delete, "Message deleted"
    on a tombstone; a reply defers from the optimistic `SendQueue` hook to the
    server path so the quote rides the send. A `/app/c/:id/m/:message_id` permalink
    deep-links to a message.
    Bodies render a **safe markdown subset** (`EdenWeb.Markup` — #60): leading
    `#`/`##`/`###` headings, inline `**bold**`/`*italic*`/`` `code` `` and bare-URL
    links, emitted as escaped iodata (whitelist tags only, no HTML-injection path);
    previews/snippets strip the markers. The composer has a built-in emoji picker.
    **Reactions** (`MessageReaction`, #67) are emoji a member toggles on a message
    (`toggle_reaction/3`; one row per member+emoji, `unique_index`); raw rows are
    preloaded and aggregated to chips in the web layer so each viewer computes
    "mine" from their own id. The emoji is validated against a closed set
    (`MessageReaction.allowed/0`) since the `react` event is client-supplied.
    Reacting is reachable only from the **message context menu** (right-click /
    long-press, Telegram-style) — a quick-react row + a "more" chevron that opens
    one **shared full-emoji grid popover** (`#reaction-grid`, the `.ReactionGrid`
    hook — #72: one per page, not a 39-button grid hidden in every message) —
    never a per-message hover affordance (that reflows the bubble). The quick-react
    row is **per-user**: each member picks
    their own in Settings (`Chat.set_quick_reactions/2`, stored in
    `chat_folder_prefs.quick_reactions`; `nil` = the default set). Chips render
    under the message in both DM bubbles and Mattermost-flat rooms; a change
    broadcasts `{:reaction_changed, message}` so all clients recompute (a reply's
    reaction routes only to the open thread panel, never the main stream). The
    soft-delete tombstone clears a message's reactions.
  - `Attachment` — **a message has many** (`#58`; ordered by `position`, lone
    sends are just an album of one), each classified by **magic bytes** into a
    `kind` (`image | video | file | audio`), never the client content-type.
    `create_album_message/4` stores up to 10 sources atomically (rolling back every
    blob if any fails) and enqueues media processing per image/video. Images and
    video render inline (image lightbox — paging across the album's photos; in-app
    `<video>` with a poster + Range seeking); anything else is a downloadable file
    with a sanitized original name. Multiple attachments render as a media grid
    (`album_view`) with files stacked below; the composer stages them in a
    thumbnail tray (multi-select + clipboard paste) with the input as the caption.
    The `:media` Oban worker fills each preview asynchronously (image thumbnail, or
    video poster + duration via ffmpeg). **Pixel dimensions are read synchronously at
    create** for both images (header) and video (`ffprobe`, best-effort with a
    `{nil, nil}` fallback where ffmpeg is absent) so the just-sent row reserves its
    box and never "pops to size"; the worker still confirms them on its pass. Per-kind
    upload caps and a decompression-bomb guard are enforced server-side.
  - `Folder` / `FolderMembership` — **per-user, Telegram-style chat folders**: a
    personal grouping of the owner's sidebar that never affects other members.
    `Folder` (name, `position`) is created/renamed/reordered/deleted in Settings;
    `FolderMembership` is the folder↔conversation join (a chat can be in many
    folders). **"All Chats" is virtual** (no row) — movable among the tabs but not
    deletable; its spot is stored per user in `chat_folder_prefs.all_chats_position`
    (`FolderPrefs`, written by `reorder_folders/2` via the `"all"` sentinel).
    `list_conversations/2` takes an optional `folder_id` (the folder is joined on
    `user_id`, so a foreign id yields nothing); `list_folders/1` carries a
    per-folder unread badge. Folder changes broadcast `:folders_changed` on the
    user topic. Left/hidden chats (`left_at`) drop out of folder views; a GC'd
    conversation cascades its folder rows. **Mute is per-user and badge-only**
    (no push/sound exists): `memberships.muted_at` mutes a chat,
    `chat_folders.muted_at` mutes a folder; a chat muted directly or via ANY
    muted folder stops counting toward every folder badge (its own unread stays
    tracked but renders de-emphasized), and un-muting a folder never un-mutes
    directly-muted chats. The corporate layer extends this:
    `channel_memberships.muted_at` mutes a whole channel from the rail's context
    menu; `Eden.Channels.list_channels/1` carries a per-channel **rail badge**
    aggregating the user's joined-room unreads (via `Chat.channel_unread_counts/1`,
    directly-muted rooms excluded, replies never counted), and a muted channel's
    badge renders de-emphasized. Rooms can't enter folders (guarded in
    `toggle_conversation_folder/3`), so room unread never leaks into folder badges.
  - **Search** (`search/2`, rooms via `search_rooms/3` #43) — conversations by
    participant display name / username (or group title) and messages by body,
    all scoped through the user's non-left memberships (deleted/hidden messages
    never match; min 2 chars, 20 per group). Message bodies use a **trigram**
    match (#56, `body_match/1` shared by DM + room search): escaped `ILIKE
    '%term%'` substring **plus** word-similarity (`<%`) typo tolerance for
    metacharacter-free terms ≥ 4 chars — both served by the
    `messages_body_trgm_idx` GIN `gin_trgm_ops` index (a BitmapOr, no sequential
    scan), so literal `%`/`_` searches keep exact semantics while typos still
    match. Conversation names/titles stay plain `ILIKE` (a small set). FTS /
    relevance ranking (stemming) remains the documented Option-A follow-up. The
    sidebar search bar renders grouped results; a message result deep-links via
    the permalink (scroll-to + highlight).
  - **Profile visibility is authorized here, not in the web layer:**
    `get_shared_user/2` returns another user only when the scoped user shares a
    conversation with them (otherwise `:not_found`). The chat header reads
    profiles from already-authorized, preloaded memberships.
- **Channels** — the corporate layer (epic #26): a `Channel` (≈ Mattermost team /
  Discord server) groups thematic chat rooms and carries per-user
  `Membership` roles (`owner | admin | member`; the creator becomes owner).
  Authorization mirrors Chat: every function takes a `%Scope{}` and is scoped
  by membership — non-members get `:not_found` (existence not leaked), members
  lacking the required role get `:forbidden`. Channel-scoped events broadcast
  on `channel:<id>` (subscribe only after `get_channel/2`); rail-level changes
  ping each member's `user:<id>:channels` topic with `:channels_changed`.
  **Rooms** (thematic chats) are `Conversation` rows with a `channel_id` — the
  whole message machinery applies unchanged. Rooms stay out of the DM
  sidebar/folders/search and per-user delete; room CRUD is admin-only via
  `Eden.Channels` (each channel is born with an `is_general` "general" room —
  always open, undeletable, auto-joined); channel deletion reclaims room
  attachment blobs forward-safely. **Last room (#81)**: opening a room records
  `channel_memberships.last_room_id` (`Channels.record_last_room/3`); the rail
  links each channel to its **entry room** — that last room if the user is still
  a member, else `general` (`Chat.entry_room_ids/2`, carried on
  `list_channels/1`) — so re-entering a channel reopens where you left off
  instead of the empty state. Bare `/channels/:id` still shows the room list (so
  mobile "back" lands there). **Room access (#41)**: a channel join
  materializes `general` only (`Chat.join_general`); other rooms are earned per
  room, and the sidebar lists only rooms you're in (link-discovered, never
  browsed). `conversations.visibility` is `open` (any link auto-joins via
  `resolve_room_access` → `join_room`) or `private` (🔒 — a link shows a
  **knock** window: `Channels.request_room_join` posts a deduped join-request
  **system message** — `messages.kind="system"` + `meta` jsonb, no sender —
  that admins approve with `approve_room_join`, or an admin adds directly with
  `add_room_members`, or shares a **room invite token** that grants
  `general` + the room in one redemption). Channels themselves are never
  closed: any authenticated user auto-joins by visiting a channel link
  (`Channels.ensure_member`). The web layer is ChatLive's channel mode (`/channels/...`
  routes) — one message pane for DMs and rooms. **Access**: members are added internally (admin+ picks
  eden users; membership + room materialization commit in one transaction) or
  via **invite links** mirroring registration invites (hash-only tokens,
  expiry, optional max uses, `FOR UPDATE` redemption at
  `/channels/join/:token`; the login flow preserves the link via
  `user_return_to`). Removal matrix: owner > admin > member; the owner leaves
  only after `transfer_ownership/3` (or deletes the channel); removed users'
  sessions get `{:removed_from_channel, id}` and navigate away. **Threads** are a
  **rooms-only** feature (flat, Mattermost-style) — the personal messenger
  (DMs/groups) has no thread UI, and `Chat.create_reply/3` / `list_thread/2`
  reject a non-room root (`ensure_threaded/1`). A reply's `root_id` points at a
  non-reply root carrying denormalized `reply_count`/`last_reply_at`; replies stay
  out of the main stream, sidebar previews, and unread badges (footer count
  instead); a root with replies refuses delete-for-both; reply permalinks open the
  thread panel. **Collapsed reply threads (#57)**: per-user thread following +
  per-thread unread, modeled on Mattermost. `ThreadMembership`
  (`thread_memberships`, one row per `(user, root)`) carries `following`,
  `last_viewed_at`, `unread_replies`. A reply auto-follows its sender and pulls
  the root's author in on the first reply (`ensure_following` — never undoing an
  explicit unfollow), then increments `unread_replies` for every other follower
  (`track_reply/2`, one transaction); opening a thread (`mark_thread_read/2`) or
  re-following never clobbers another's count. `thread_unread_counts/2` /
  `list_followed_threads/2` are room-scoped and per-user; the web layer seeds a
  per-thread "N unread" footer pill + a Threads-list panel (RHS aside, reusing the
  thread panel) opened from a room-toolbar button with an unread-thread badge, and
  a follow bell in the thread header — all live over the existing `{:thread_reply}`
  broadcast plus `{:thread_updated}`/`{:message_deleted}` (reply/root deletion
  re-settles the count + list) and a `{:thread_read}` user-topic ping (multi-tab).
  No global cross-room inbox; rooms-only, like threads themselves. Thread unread is
  **deliberately independent of room mute** — it never feeds the channel rail or
  folder badges (those filter `is_nil(root_id)`), only the in-room toolbar for a
  thread you explicitly followed, so muting a room doesn't silence a followed
  thread (matches Mattermost; the eden "no badge past mute" invariant is about
  rail/folder badges). Following is **not backfilled**: pre-existing threads gain
  followers only on their next reply (a root author/replier from before the
  feature isn't retroactively subscribed).
  **Room message UI is Mattermost-flat** (avatar · name · time rows,
  consecutive same-author runs collapse, hover quick-actions, facepile thread
  footer, RHS panel / mobile full-screen) — DMs keep bubbles.
- **Storage** — file/photo persistence behind an **adapter behaviour**
  (`Eden.Storage.Adapter`). Local disk in dev, object storage (S3-compatible) in
  prod, swappable without touching callers. Callers store only the file **key +
  metadata**, never a concrete storage implementation — chat attachments
  (`Message`) and account avatars (`avatar_key`) both go through it.
- **Notifications** — notification delivery behind an **adapter behaviour**
  (`Eden.Notifications.Adapter`), mirroring Storage (ADR-0001, #235). `Eden.Chat`
  decides **who** hears (the #213 gating — sender/left/mute/DND, thread-followers
  for a reply, and **channel-mute** via `Eden.Channels.muted_user_ids/1`, #271; one
  `notify_recipient_ids` with a shared `common_gates`) and builds a locale-neutral
  **payload**; `Eden.Notifications.deliver/2` fans that already-gated set out over the
  configured adapters. Today the only transport is the in-tab
  **`Eden.Notifications.Web`** adapter — broadcasts `{:notify, payload}` on
  `user:<id>:notify` (separate from the `:chat` sidebar-sync topic, #272), which open
  LiveViews subscribe to via `EdenWeb.NotifyHook` on **every** authed page (the only
  gate left there is per-session **focus** — "am I looking at this chat now"; #271
  moved channel-mute server-side, so room notifications now deliver everywhere). The
  payload shape (the delivery **contract**) is documented once in the
  `Eden.Notifications` moduledoc. Planned push transports (native desktop app / APNs
  / FCM / RuStore-VK) and the `notification_targets` device table are deferred to
  later ADR-0001 tickets — new adapter modules on this same seam, no caller change.

## Commands

- `mix setup` — install deps, create & migrate the DB, build assets.
- `mix phx.server` (or `iex -S mix phx.server`) — run the app locally.
- `mix test` — run the suite (auto-creates & migrates the test DB).
- `mix check` — **the full quality gate** (runs in `MIX_ENV=test`):
  `format --check-formatted` → `compile --warnings-as-errors` → `credo --strict`
  → `sobelow --config` → `deps.audit` → `test`.
- `mix dialyzer` — type checking (separate from `mix check`; first run builds the PLT).
- `mix ecto.gen.migration <name>` — create a migration (correct timestamp/conventions).

## Definition of Done

A change is done only when, before opening/merging a PR:

1. **`mix check` is green** locally — this is the gate.
2. **`mix dialyzer` is green** (CI enforces it too).
3. Tests cover the new behavior.
4. The PR template checklist is completed (migrations reversible, no secrets,
   security impact assessed, docs/CLAUDE.md updated if architecture changed).

## Code review priority rubric

Reviewers tag every finding with a priority.

**Block merge (must be resolved):**
- **P0** — security vulnerability, auth/permission bypass, data loss or
  corruption, secret committed, broken/irreversible migration, app crash.
- **P1** — correctness bug, missing tests for core logic, breaking schema/API
  change without a migration path, significant performance regression, violation
  of context boundaries (web ↔ context, cross-context reach-in).

**Non-blocking (comments / suggestions):**
- **P2** — maintainability: naming, structure, minor perf, missing edge-case tests.
- **P3** — style nits, docs wording, subjective preferences.

P0/P1 must be addressed before merge; P2/P3 are advisory.

## Skills (must use)

Skills are vendored in `.claude/skills/` (so they travel with the repo) or come
from installed plugins. Use them as follows — this is **not optional**.

### Elixir/Phoenix code — always consult the thinking skills first

For **any** work that writes or changes Elixir code (`.ex`/`.exs`), invoke the
relevant thinking skill **before** exploring or editing — the skills tell you
what patterns and anti-patterns to look for. The `using-elixir-skills` router
maps the task to the right one:

- `elixir-thinking` — language idioms, structuring modules, pattern matching, `with`.
- `phoenix-thinking` — LiveView/Plug/PubSub, controllers, the mount lifecycle.
- `ecto-thinking` — schemas, changesets, contexts, queries, migrations, preloads.
- `otp-thinking` — GenServer/Supervisor/Task/Registry, concurrency, fault tolerance.

(`oban-thinking` is referenced by the router but not vendored — see
`.claude/skills/ATTRIBUTION.md`. Note **Oban IS a dependency**: it runs in the
supervision tree (`lib/eden/application.ex`) with a `:media` queue
(`Eden.Chat.ThumbnailWorker`) and a daily `Oban.Plugins.Cron` job
(`Eden.Accounts.TokenPruner`, #238). Prefer an Oban worker + Cron for periodic /
background work over a hand-rolled GenServer sweep.)

### UI / frontend work — use the design skills

For any UI (LiveView templates, components, HEEx/Tailwind, pages, styling):

- **`frontend-design`** — building new components, pages, or app UI.
- **`impeccable`** — designing, auditing, polishing, or iterating on existing UI
  (typography, color, spacing, motion, accessibility, UX copy).

### Other rules

- Follow the usage rules in [`AGENTS.md`](AGENTS.md). Note: the stock
  `mix precommit` advice there is superseded by **`mix check`** as this project's gate.
- Respect context boundaries and the storage-adapter abstraction described above.

## Deployment (Phase 5)

Production runs as an **OTP release** in a thin Docker image (multi-stage
`Dockerfile`, Erlang/OTP 28 on Debian bookworm — matches CI).

- `bin/server` — start the supervised app (sets `PHX_SERVER=true`).
- `bin/migrate` — run migrations via `Eden.Release.migrate/0` (no Mix in prod).
- `GET /healthz` — liveness probe, answered in the endpoint before the router
  (cheap, no DB). TLS terminates at Caddy (no app-level `force_ssl`, #85), so the
  probe hits plain HTTP without a redirect.
- Required runtime env (see `config/runtime.exs`): `DATABASE_URL`,
  `SECRET_KEY_BASE`, `PHX_HOST`, **`EDEN_VAULT_KEY`** (encrypts TOTP secrets at rest,
  #250 — a dedicated secret, independent of `SECRET_KEY_BASE` and kept stable, or
  stored TOTP secrets become undecryptable); `EDEN_UPLOADS_ROOT` for the uploads
  volume; `PORT` optional. **`PHX_SCHEME`/`PHX_PORT`** (#85) make the public URL
  http-by-IP or https-by-domain without a recompile — the same release flips
  phases by env (they drive URL generation + the LiveView socket `check_origin`).
- CI's **release-smoke** job builds the prod release and runs migrations through
  it, so prod-only compile/runtime-config regressions are caught before deploy.
- **Deploy kit (#85, `deploy/`)**: `docker-compose.yml` (app + Postgres 16 +
  local `uploads` volume) behind **Caddy** (reverse proxy + auto-TLS, `:80` for
  the IP phase → `chat.ihi.ru` for the domain phase via `SITE_ADDRESS`), an
  `.env.example`, a `backup.sh` (pg_dump, keep-14), and `README.md` runbook
  (Debian 12). CD is `.github/workflows/deploy.yml` — manual `workflow_dispatch`:
  build image → push to GHCR → SSH `pull` + `bin/migrate` + `up -d`. Media stays
  on the local volume; swap to R2/S3 via `EDEN_S3_*` env with no code change.
- Still server-dependent (do at deploy time): log shipping, prod metrics/alerts,
  shipping backups off-box.

## Security follow-ups (tracked)

- ~~**Content-Security-Policy**~~ — **resolved** (#54): `EdenWeb.CSP` sets a
  per-request nonce-based policy on the `:browser` pipeline (scripts nonce-locked;
  `style-src` allows inline for the pervasive `style=""` attributes; `img-src`
  allows `data:`/`blob:`). The `Config.CSP` sobelow ignore is **kept but
  re-justified as a false positive** — sobelow only recognizes CSP set via
  `put_secure_browser_headers`, not a custom per-request nonce plug; presence is
  covered by `EdenWeb.CSPTest`.
- ~~**S3-compatible storage adapter**~~ — **resolved** (#55): `Eden.Storage.S3`
  speaks the S3 REST API over Req with hand-rolled AWS SigV4 (`Eden.Storage.SigV4`,
  no SDK — verified against the AWS spec's example vector), path-style, working
  against AWS S3 / R2 / MinIO / B2. It omits `local_path/1`, so the facade returns
  `:error` and file serving streams the bytes. Swap is one config line, env-driven
  in `config/runtime.exs` (`EDEN_S3_BUCKET` present → adapter becomes S3); the
  default stays `Eden.Storage.Local` against `EDEN_UPLOADS_ROOT`.
- ~~**Attachment blob cleanup on delete**~~ — **resolved** by message "delete for
  both": `delete_message_for_both/2` deletes the `storage_key` + `thumbnail_key`
  blobs (after the tombstone commits, and only if no forwarded copy still
  references them). Any new delete path must do the same.
- ~~**Rate-limit login + invite endpoints**~~ — **resolved** (#236): `Eden.RateLimit`
  is a hand-rolled fixed-window limiter (no dep — a GenServer owns one public ETS
  table, callers hit it with an atomic `:ets.update_counter`, a periodic sweep GCs
  stale buckets). The `EdenWeb.RateLimit` plug throttles the signed-out credential
  POSTs **per client IP** — `/users/log_in` (10/5min) and `/invite/:token` (30/5min)
  — halting over-limit requests before the auth path with a flash. Keys on
  `conn.remote_ip`, which is the real client only because the endpoint trusts
  `x-forwarded-for` (added to `Plug.RewriteOn`) and Caddy overwrites that header
  with the true peer (`deploy/Caddyfile`). Failed logins are logged (username + IP,
  no password). **Off in test** (`config :eden, EdenWeb.RateLimit, enabled: false`)
  so the suite's many logins don't self-throttle; the limiter + plug are unit-tested
  directly. Larger blast-radius controls (per-username lockout, captcha) are
  deferred — see the issue.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues (`matthewbkrr/eden`, via the `gh` CLI); external
PRs are NOT a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their default names (`needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`, `wontfix`) — distinct from the existing
type/priority axes (`bug`/`feature`, `P0:`–`P3:`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root + ADRs in `docs/adr/`.
See `docs/agents/domain.md`.
