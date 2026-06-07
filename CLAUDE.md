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
- Quality tooling: **credo**, **sobelow**, **dialyxir**, **mix_audit**.

## Architecture

The app is split into bounded **contexts** under `lib/eden/`, with the web layer
under `lib/eden_web/`. The web layer calls contexts; contexts never call the web
layer. Each schema lives in its owning context. (These contexts are the target
design — built incrementally as features land.)

- **Accounts** — users, authentication, profiles.
- **Chat** — the messaging domain. **Conversations are a first-class entity**, not
  an implicit pair of users:
  - `Conversation` — a thread; the same model backs both 1:1 and group chats.
  - `Membership` — join between a `Conversation` and a user (role, joined_at,
    last_read, etc.). A conversation has many memberships.
  - `Message` — belongs to a conversation and a sender; carries text and/or a
    photo attachment (referenced by storage key, see Storage).
- **Storage** — file/photo persistence behind an **adapter behaviour**
  (`Eden.Storage.Adapter`). Local disk in dev, object storage (S3-compatible) in
  prod, swappable without touching callers. Chat stores only the file **key +
  metadata**, never a concrete storage implementation.

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

## Security follow-ups (tracked)

- **Content-Security-Policy** — there is no CSP yet; `Config.CSP` is temporarily
  ignored in `.sobelow-conf`. When the LiveView UI lands, add a nonce-based CSP to
  the `:browser` pipeline and **remove that ignore entry**.
- **S3-compatible storage adapter** — only `Eden.Storage.Local` exists. Prod uses
  it against `EDEN_UPLOADS_ROOT` (a persistent volume, set in `config/runtime.exs`).
  Build an S3 adapter to satisfy Phase 3's "storage swaps by one config line"; it
  needs `local_path/1` to return `:error` so file serving falls back to streaming
  bytes.
- **Attachment blob cleanup on delete** — `attachments.message_id` is
  `on_delete: :delete_all`, so deleting a message drops the row but **not** the
  stored blobs (`storage_key` + `thumbnail_key`). When message deletion lands,
  delete both objects via `Eden.Storage.delete/1` first, or storage leaks.
