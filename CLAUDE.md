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
  **Storage** as `avatar_key`; `username` stays immutable (it is the login).
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
    every attachment's unshared blobs; **forward** copies it into another
    conversation (re-referencing the same blobs in order, `forwarded_from_id` for
    attribution). A `/app/c/:id/m/:message_id` permalink deep-links to a message.
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
    long-press, Telegram-style) — a quick-react row + a "more" chevron that expands
    the full emoji grid in place — never a per-message hover affordance (that
    reflows the bubble). The quick-react row is **per-user**: each member picks
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
    video poster + duration/dimensions via ffmpeg). Per-kind upload caps and a
    decompression-bomb guard are enforced server-side.
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
  - **Search** (`search/2`) — conversations by participant display name /
    username (or group title) and messages by body, all scoped through the
    user's non-left memberships (deleted/hidden messages never match). Plain
    escaped `ILIKE '%term%'` (min 2 chars, 20 per group) — right-sized for this
    scale; the FTS/pg_trgm upgrade path is documented in issue #12. The sidebar
    search bar renders grouped results; a message result deep-links via the
    permalink (scroll-to + highlight).
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
  attachment blobs forward-safely. **Room access (#41)**: a channel join
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
  thread panel. **Room message UI is Mattermost-flat** (avatar · name · time rows,
  consecutive same-author runs collapse, hover quick-actions, facepile thread
  footer, RHS panel / mobile full-screen) — DMs keep bubbles.
- **Storage** — file/photo persistence behind an **adapter behaviour**
  (`Eden.Storage.Adapter`). Local disk in dev, object storage (S3-compatible) in
  prod, swappable without touching callers. Callers store only the file **key +
  metadata**, never a concrete storage implementation — chat attachments
  (`Message`) and account avatars (`avatar_key`) both go through it.

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

(`oban-thinking` is referenced by the router but not vendored — Oban isn't a
dependency yet; see `.claude/skills/ATTRIBUTION.md`.)

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
  (cheap, no DB), excluded from `force_ssl`.
- Required runtime env (see `config/runtime.exs`): `DATABASE_URL`,
  `SECRET_KEY_BASE`, `PHX_HOST`; `EDEN_UPLOADS_ROOT` for the uploads volume;
  `PORT` optional.
- CI's **release-smoke** job builds the prod release and runs migrations through
  it, so prod-only compile/runtime-config regressions are caught before deploy.
- Still server-dependent (do at deploy time): domain + TLS (reverse-proxy),
  Postgres backups, log shipping, prod metrics/alerts.

## Security follow-ups (tracked)

- ~~**Content-Security-Policy**~~ — **resolved** (#54): `EdenWeb.CSP` sets a
  per-request nonce-based policy on the `:browser` pipeline (scripts nonce-locked;
  `style-src` allows inline for the pervasive `style=""` attributes; `img-src`
  allows `data:`/`blob:`). The `Config.CSP` sobelow ignore is **kept but
  re-justified as a false positive** — sobelow only recognizes CSP set via
  `put_secure_browser_headers`, not a custom per-request nonce plug; presence is
  covered by `EdenWeb.CSPTest`.
- **S3-compatible storage adapter** — only `Eden.Storage.Local` exists. Prod uses
  it against `EDEN_UPLOADS_ROOT` (a persistent volume, set in `config/runtime.exs`).
  Build an S3 adapter to satisfy Phase 3's "storage swaps by one config line"; it
  needs `local_path/1` to return `:error` so file serving falls back to streaming
  bytes.
- ~~**Attachment blob cleanup on delete**~~ — **resolved** by message "delete for
  both": `delete_message_for_both/2` deletes the `storage_key` + `thumbnail_key`
  blobs (after the tombstone commits, and only if no forwarded copy still
  references them). Any new delete path must do the same.
