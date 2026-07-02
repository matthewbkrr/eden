# RFC: Organizations, identity, and the admin panel

Status: **draft for discussion** · Scope: the "very large features" — multi-org
(environments/slugs), the org-aware profile card, directory-managed identity, and
the admin panel that ties them together.

This is a planning document, not a task. It records the research, the recommended
architecture, and — most importantly — the **decisions a human must make** before
any of it is built. Nothing here is committed to the roadmap yet.

---

## 0. The finding that reframes everything

The premise we started from was: *"eden is a child product of the Ihi portal; corp
email already exists for all employees, so we can sync the profile (name, handle,
position, structure) from Ihi via auth."*

After mapping `~/ihi-portal` (it's also Elixir/Phoenix), that premise is **only
partly true**, and the part that's false changes the plan:

- **Ihi is not an HR/employee directory.** It's a multi-tenant B2B fintech/document
  portal (orders, invoices, counterparties, rates, payments). Its only person table,
  `tenant_users`, has **email + role + tenant + password/TOTP and nothing else** — no
  first/last name, no display name, no `@handle`, no employee number, no avatar, no
  phone, and **no org structure** (no region/ЦФО, no warehouse "Склад Обухово", no
  position/"Должность", no department/block). Every migration that ever touched that
  table was checked; those columns have never existed.
- Ihi has **no SSO/OIDC/SAML** today, no token introspection, no `userinfo`. Auth is a
  cookie session (email + OTP/password + optional TOTP). There **is** an internal
  machine-to-machine API (API keys / a platform shared-token), but it has **no users/
  directory endpoint or scope**.

So the rich card in the Mattermost screenshot (`@ahmedova.zaira`, `ahmedova.zaira@rwb.ru`,
employee `107986`, `ЦФО + Санкт Петербург • Склад Обухово • Руководитель блока`) is
**not coming from Ihi**. It's coming from the company's real HR/Active Directory — the
thing the existing Mattermost is wired to via LDAP/SAML — which **neither Ihi nor eden
touches today**.

**Consequence:** "sync from Ihi" buys us, at most, **login federation + corp email**. It
does **not** supply names, handles, positions, or org structure. Those must come from
somewhere, and deciding *where* is decision #1 below — it's the hinge the whole design
turns on.

---

## 1. "Separate environments and slugs" — decoded

This is the team lead describing **multi-tenancy**, and it's the foundational layer.
Today eden is single-tenant: one flat pool of users, channels, DMs. The requirement
"first only our employees; later external agents (Akebono, …) join, isolated" needs a
boundary above everything else:

- An **Organization** (call it Org / Workspace / Environment — Slack calls it a
  *workspace*, Mattermost a *team*): the company's internal employee space is one Org;
  each external agent (Akebono) is its own Org. Users, channels, rooms, DMs, search —
  all scoped to an Org. An Akebono user must not even be able to *discover* that the
  internal Org's channels or people exist.
- A **slug**: the Org's URL handle, e.g. `chat.ihi.ru/ihi/...` and
  `chat.ihi.ru/akebono/...` (or later subdomains `akebono.chat.ihi.ru`). The slug is how
  routing picks the tenant and is the thing the team lead means by "slugs".

**Where the Org sits:** eden already has a `Channel` context that is essentially a
Mattermost *team* (groups thematic rooms, per-channel `owner|admin|member` roles). An
Org is **one level above** that:

```
Org (tenant, has slug)  →  Channel (≈ Mattermost team)  →  Room (Conversation)  →  Message
                        ↘  Direct conversations (also org-scoped)
```

A `Channel` is the wrong unit for an environment — it has no home for org-level
membership, org-level identity sourcing, or the slug, and Akebono channels must be
invisible to employees, which is an org boundary, not a channel one.

**How to implement the tenancy (recommended): row-level `org_id`, not schema- or
database-per-tenant.** eden is *already* a "scoped by `%Scope{}`" codebase — every query
threads a scope and filters by `user.id`. Adding `org_id` to that is a natural
extension, not a new paradigm. Schema/DB-per-tenant would force `search_path`/prefix
plumbing through code that has none, wreck Ecto's preload/migration ergonomics, cap us
at a few hundred tenants, and make the *cross-org* things we actually want (a global
admin panel, onboarding, maybe future employee↔agent shared rooms) impossible. Slack
itself is row-level by `workspace_id`; we're orders of magnitude below needing more.

The one real risk of row-level is a **forgotten `WHERE org_id = ?`** leaking data across
tenants. Defenses, in order: (1) `org` becomes part of `%Scope{}` and is threaded
everywhere as `user` is today — the explicit contract; (2) a `Repo.prepare_query/3`
backstop that auto-injects the filter with an explicit `skip_org_id` escape hatch for
admin/global queries; (3) composite FKs `(id, org_id)` so a message can't reference a
membership from another org; (4) optionally Postgres RLS if a contract ever demands a
DB-level stop. Resolve the slug → org → membership check **once**, in a module used as
*both* a Plug and a LiveView `on_mount` hook (LiveView patches don't re-run plugs — both
paths must check, and re-check on `handle_params`).

---

## 2. Identity & the profile card

### 2.1 The card (near-term, concrete)

Mirror the Mattermost card, adapted to eden's existing header profile panel (#136):

| Line | Source | Editable by the person? |
|---|---|---|
| Avatar | eden (`avatar_key`) | ✅ self-service (already built) |
| Display name | eden (`display_name`) | ✅ self-service (already built) |
| "Был(а) в сети N мин. назад" (last seen) | eden presence (#102 `last_active_at`) | n/a (derived) |
| Local time | — | **skip for now** (per you) |
| `@handle` (`surname.name`, +disambiguators) | **directory / admin** | ❌ never self-set |
| Corp email (`ahmedova.zaira@rwb.ru`) | **directory / admin** (or Ihi) | ❌ never self-set |
| Employee tag (`107986`) | — | **not needed** (per you) |
| "Должность" (was "Структура") | **directory / admin** | ❌ never self-set |

The principle, straight from Mattermost's security-first model: **a person never edits
their own handle / email / position** — those are *managed* (by the directory, or by an
admin). Only display name, avatar, and bio are self-service. eden's `profile_changeset`
already only allows `display_name`/`bio`; we keep it exactly and add a **separate,
admin-/sync-only changeset** for the managed fields.

Note on the Mattermost screenshot's "Структура" line specifically: in Mattermost the
plain free-text job title is the **Position** field, while the richer multi-part
"ЦФО • Склад • Руководитель блока" line is the newer **Custom Profile Attributes**
(admin-defined, typed, admin-managed-by-default, optionally LDAP/SAML-linked). For eden
we collapse this to a single **"Должность"** managed text field now, and can grow into a
small set of admin-defined attributes later without a breaking change.

### 2.2 The model change (provenance per field)

Add to `users` (managed = written only by the sync/admin layer, never by a user form):

- `handle` — the canonical `surname.name`; note this is **distinct from the current
  `username` login**. Decision #4 below: replace, alias, or coexist.
- `corp_email`, `position` (Должность), `external_id` (the upstream key, nullable),
  `identity_source` (`ihi | directory | local`), `directory_synced_at`, `active`.
- A `managed_by` notion (`:user | :directory | :admin`) so the UI knows what to lock and
  a future sync can flip a field read-only without a migration.

Keep `display_name`, `bio`, `avatar_key` exactly as self-service.

### 2.3 Where the managed data comes from (decision #1, the hinge)

Three options; we likely end up with a blend, but the *primary* source must be chosen:

- **(a) Integrate with the company's real HR/Active Directory** (the source Mattermost
  already uses) via LDAP/SAML/OIDC + directory sync. Highest fidelity (handles,
  positions, structure, deactivation-on-leave all flow automatically), but depends on
  getting access/credentials to that system and is the most build.
- **(b) eden + the admin panel become the system of record** for chat identity: HR/admins
  enter handle/email/position in eden's admin UI; no upstream dependency. Fastest to
  ship, fully under our control, but it's manual data entry and can drift from HR.
- **(c) Hybrid:** Ihi (or a future SSO) federates *login + corp email*; the admin panel
  owns handle/position/structure until/unless a real directory integration lands.

Recommendation: **start with (b)/(c)** — make eden's admin panel the system of record now
(it unblocks the card + roles + onboarding immediately and needs no external access), and
design the managed-field layer so a real directory sync (a) can take over those fields
later read-only. **This is the decision to take to the team lead**, because "sync from
Ihi" as originally imagined isn't available.

### 2.4 SSO / login (separable from profile data)

Auth federation is a *separate* axis from profile data and can come later. When it does:
Ihi (or the company IdP) as an **OIDC provider**, eden as a relying party
(`oidcc`, OpenID-certified, client-only — exactly eden's role); JIT-provision on first
login; refresh managed fields on each login; a webhook or nightly reconcile to handle
"employee left" deactivation (JIT alone never deactivates). Until then eden keeps its
invite-based login. A shared session cookie is a possible stopgap but brittle and
doesn't generalize to external orgs — not recommended beyond a bridge.

---

## 3. External agents (Akebono) & guests

External agents are a second Org with `identity_source = local` and `kind =
external_agent`. They have **no upstream identity**, so:

- Provisioned via eden's **existing invite flow** (hashed tokens, expiry, max-uses,
  `FOR UPDATE` redemption — already built), scoped to the agent's `org_id`; redemption
  creates the user + the org membership in one transaction.
- Their `handle` is **admin-assigned and namespaced** (e.g. `akebono.surname.name`) to
  avoid collisions with employees; `position`/email are admin-set or omitted; display
  name/avatar/bio stay self-service. Same "never self-edit your handle" invariant, just
  with the eden admin as the authority instead of a directory.

Within an Org, Mattermost's **Guest** role maps cleanly onto eden's *existing* access
model: a guest gets no `general` auto-join, can't *discover* rooms (eden already makes
rooms link-/invite-earned per room), and can only DM people they share a room with
(reuse `get_shared_user/2`, which already authorizes DM visibility by shared
conversation). Add a `:guest` role + a GUEST badge when we need intra-org externals.
(Org-level isolation handles inter-company separation; the guest role handles
"external person inside one Org".)

---

## 4. The admin panel — why it falls out of all this

Once handle/email/position/org-membership/roles are **not self-editable**, *someone*
must manage them — that someone is the admin panel (Mattermost's "System Console",
scaled down). It's not a nice-to-have; it's the necessary consequence of the managed-
identity model. It owns:

1. **People:** create/deactivate, set handle/email/position, assign org + roles, reset
   access. (For directory-sourced orgs these become read-only "synced from …".)
2. **Orgs/environments:** create an Org, set its `slug`, `kind` (internal / external
   agent), `identity_source`; onboard an external agent and issue its invites.
3. **Roles & structure:** org/channel role assignment; later, the org-structure /
   custom-attribute schema.
4. **Later:** directory/SSO config (LDAP/SAML/OIDC), guest-access toggle.

Authorization tiers (mirror Mattermost + eden's existing `owner|admin|member`):
**super-admin** (cross-org, manages environments — likely platform staff) → **org
admin** → channel `owner|admin` → member → guest. Build it **thin and scoped** first
(per-org admin covers most), add the cross-org super-admin surface only for onboarding
environments.

This is the "admin panel that flows from this" referenced earlier — it's the management
plane for everything that employees can't set themselves.

---

## 5. Recommended phasing

Each phase ships independently and de-risks the next. Nothing here is started.

- **Phase 0 — decisions (this RFC).** Resolve decisions #1–#7 below with the team lead.
- **Phase 1 — managed-identity fields + the profile card.** Add `handle`, `corp_email`,
  `position`, `managed_by` to `users`; a managed-only changeset; render the
  Mattermost-style card (handle/email/Должность + last-seen) in the existing #136 panel,
  read-only. **No tenancy/SSO yet** — single Org implied. Ships the visible win fast.
- **Phase 2 — the admin panel (system of record).** A scoped admin UI to manage people +
  the managed fields + roles. Makes Phase 1's data maintainable. (#165 group roles is a
  natural sub-part / can fold in here.)
- **Phase 3 — Orgs & slugs (multi-tenancy).** Introduce the `Org` entity + `org_id` on
  everything + slug routing + the `%Scope{}`/`prepare_query` scoping + the data
  migration that puts all existing data into the `internal` Org. The big structural lift;
  do it once Phases 1–2 prove the identity model.
- **Phase 4 — external agents + guests.** Onboard the first external Org via the admin
  panel + invite flow; add the `:guest` role + badge.
- **Phase 5 — directory/SSO (optional, when access exists).** OIDC login + directory sync
  flips managed fields to directory-sourced read-only; deactivation reconcile.

---

## 6. Decisions needed (take these to the team lead)

1. **Where does org/profile data come from** — the company's real HR/AD (option a), the
   eden admin panel as system of record (b), or hybrid (c)? *This blocks the final shape.*
   (Recommendation: b/c now, design for a later.)
2. **Tenancy model** confirmation: row-level `org_id` (recommended) vs hard isolation
   (schema/DB-per-tenant) — does any external agent contractually require physical data
   separation?
3. **Slug shape**: path prefix `/:slug/...` now (recommended), subdomains later? Any
   reserved slugs / naming rules from the team lead?
4. **`handle` vs `username`**: eden's login is `username` ([a-z0-9_]); the directory
   handle is `surname.name`. Replace, alias, or coexist — and how to migrate today's
   users into the internal Org?
5. **SSO timing**: build OIDC from the start, or ship invite-login + admin panel first and
   federate later? (Recommendation: later.)
6. **Cross-org interaction**: will external agents ever share a room / DM employees
   (Slack "shared channels")? Cheap to decide now, expensive later — it sets how strict
   the `org_id` filter is.
7. **Deactivation**: how do we learn an employee left (webhook from HR/Ihi, nightly
   reconcile, manual in admin)?

---

## 7. What's unavoidable regardless of the team-lead decisions

The seven decisions in §6 are about **how** and **when**, not **whether**, for a core
the product requirements already fix ("managed identity the user can't self-edit";
"external agents join later, isolated"). The following is on the critical path no matter
how the decisions land — safe to design and start **now**:

1. **Managed vs self-service field split.** In every option (HR/AD, admin-as-system-of-
   record, or hybrid) the `@handle` / corp email / position are **not** self-edited. So we
   always need those columns on `users` plus a **managed-only changeset** separate from
   `profile_changeset` (which stays `display_name`/`bio`). Decision #1 only changes *who
   calls* that write path (a sync job, the admin UI, or both) — not that it exists or that
   the fields are locked from the user. Decision #4 only changes the field's *name/
   migration*, not the need.
2. **Handle generation + uniqueness** (`surname.name` + disambiguators on collision; a
   namespace like `akebono.` for externals). External agents have *no* upstream directory
   in any scenario, so eden must mint + enforce unique handles itself for them — that logic
   is needed regardless of where employee handles come from.
3. **The profile card UI** — avatar + display name + last-seen + handle + email + Должность,
   managed fields read-only, in the existing #136 panel. The layout is source-agnostic; only
   the data feeding it varies.
4. **A minimal admin / management plane.** By definition managed fields need a non-user
   writer; and external agents (a firm requirement) have no directory, so an admin must
   assign their handle / membership / role and onboard their Org. Even a full-AD world still
   needs admin for orgs, externals, roles, and deactivation overrides. The *scope* grows if
   admin is the system of record; a baseline is needed either way.
5. **The Org / environment boundary + org-scoping.** "External agents, isolated from
   employees" is a stated requirement, not one of the open decisions — so *some* Org entity
   and scoping every query by it is required once agents arrive. Decisions #2/#3/#6 change
   the *mechanism* (row-level vs schema, path vs subdomain, sharing or not), not whether the
   boundary exists. (Not needed for the very first employees-only release; unavoidable the
   moment a second Org does.)
6. **Group roles & removal (#165)** — already on the backlog; the `owner|admin|member` +
   kick + "removed → it disappears" pattern is needed for groups *and* is the exact template
   the admin panel and org membership reuse.

**Gated on a decision — do NOT start until answered:**
- AD/LDAP/SAML directory sync → only if #1 = (a) real directory.
- OIDC / SSO login → only if #5 = "now".
- Schema-/DB-per-tenant plumbing → only if #2 = hard isolation (else row-level, the default).
- Subdomains + per-tenant TLS → only if #3 = subdomains (else path `/:slug/`).
- Cross-org shared channels → only if #6 = yes.
- Upstream deactivation transport (webhook/SCIM) → #7 + whether an upstream exists at all.

**Upshot:** the unavoidable core (items 1–4, 6) is also the *early* work — Phase 1 and the
start of Phases 2–3. We can build it now; the decisions gate only the integration-heavy
tail (sync, SSO, hard isolation, subdomains, cross-org). Designing the managed-field layer
with a `managed_by` provenance flag means a later AD sync just *takes over* those fields
read-only, with no breaking migration.

## 8. What eden already has that we reuse (good news)

- `%Scope{}` everywhere → `org` slots in cleanly.
- `Channel` ≈ Mattermost team, with `owner|admin|member` roles + membership-scoped auth +
  `{:removed_from_channel}` → the pattern to mirror for org membership + #165 group roles.
- Per-room access (`resolve_room_access`, link-/invite-earned, `private` knock) +
  `get_shared_user/2` (DM visibility by shared conversation) → the guest model.
- Invite flow (hashed tokens, expiry, max-uses, `FOR UPDATE`) → external-agent
  provisioning.
- Presence/last-seen (#102) → the card's "был в сети".
- The #136 profile panel → where the card renders.

The structural distance from "single-tenant employee chat" to "multi-org, directory-
managed identity, admin-managed" is real but mostly *additive* — the messaging core
doesn't change.
