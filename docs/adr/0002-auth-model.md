# ADR: Authentication model — invite-gated, eden-owned identity (#177 superseded)

Status: **accepted strategy** · Supersedes the #177 decision (social SSO via
Google/Discord/Apple) · Related: #172 (org/identity/admin epic),
`docs/rfc-orgs-identity-admin.md`.

This is an Architecture Decision Record. It fixes *how* people get into eden and
who owns their identity — **without** committing new implementation. Almost
nothing here is near-term build work; the value is that every future auth
addition lands on decisions already made instead of reopening them. The one
near-term feature it motivates (admin reset links) is a separate ticket.

---

## Context

- Today eden's auth is **invite-link → username+password**: an admin issues a
  hash-at-rest token (expiry, max-uses, revocation, `FOR UPDATE` redemption),
  the invitee picks an immutable `username` + bcrypt password, sessions ride a
  `UserToken` cookie. No email, no phone, no OAuth, no MFA, no self-serve
  password reset (the only reset path today is operator access to the server).
  ~20 users, all company employees.
- Issue **#177** decided (2026-06-26) to add social SSO — Google, Discord,
  Apple via `ueberauth`. That decision is **not implementable for a RU legal
  entity**: Google and Apple stopped serving OAuth apps of RU businesses in
  January 2025, and Discord is blocked in RU. The realistic providers are
  VK ID, Yandex ID, phone OTP, and corporate SSO (OIDC/SAML/LDAP).
- The upstream systems #177 assumed don't exist either: the Ihi portal is
  **not** an identity provider (cookie session, no OIDC/introspection/userinfo,
  no directory API — see RFC §0), and access to the company's real HR/AD is
  unconfirmed.
- Compliance frames everything: the юрлицо already processes employee PII (HR,
  the Ihi portal), which is the company's existing operator posture. The thing
  that would create a **new** compliance surface — 152-FZ consent flows,
  data-localization (RU-hosted DB), an updated РКН operator notification — is
  **open B2C self-registration** of individuals. Invite-gated B2B onboarding
  (employees, client staff under contract) does not add to the existing
  posture.
- Prod is a single overseas VPS; the standing "no mailer" rule (RU inbox
  delivery from it is unreliable) remains in force, so no email-based auth
  flow is available.

## Decision 1 — eden is the system of record; providers are login channels

The eden `users` table stays the **system of record** for identity. Any future
external provider (VK ID, Yandex ID, corporate OIDC) is a **linkable login
channel**, recorded in an `identities` table keyed `(provider, sub)` and
pointing at an eden user — it answers only "this sub is verified", never owns
profile, roles, or membership. All chat data keeps FK-ing to eden `users`.

- **Not built now.** `hashed_password` stays on `users` as-is; the
  `identities` table is introduced together with the *first* external provider
  (the migration at that point is trivial). Building it "in advance" is
  rejected complexity.
- This matches #172 decision #1 (admin-managed profile lives in eden) and the
  RFC's managed-field model: an external IdP can later *feed* managed fields,
  but eden remains the master.

## Decision 2 — global account + org memberships; auth policy is per-org

One person = **one global eden account** that holds memberships in N
organizations (Discord/Mattermost-style), *not* one account per org
(Slack-style). Isolation between orgs is membership-scoping, not separate
login databases. When orgs land (RFC Phase 3), the org carries the **auth
policy** — which methods grant entry/login for that org (e.g. "corp SSO
required" for the internal org) — while identity stays global. Today's data
needs zero migration for this: current users simply become members of the
first (internal) org.

## Decision 3 — the perimeter is invite-only; no open B2C registration

Everyone enters through the **invite door**: employees today, client staff
(external agents à la Akebono) later — the latter are B2B relationships under
contract, not mass PII collection. There is **no self-serve registration**,
which keeps eden inside the company's existing operator posture: no new
consents, no localization requirement, no РКН delta.

**Hard gate (do not cross casually):** opening B2C self-registration ever
requires, as a package — prod DB moved to RU hosting (242-FZ localization),
consent-to-processing in the registration flow, the юрлицо's РКН operator
notification updated, and a published processing policy. Until someone
consciously signs up for that package, the door stays closed. Phone-OTP auth
(and its SMS budget + anti-fraud surface) existed in the design only to serve
that door — it drops out of the plan entirely.

### Invite issuance scales in layers (trigger-gated, not built now)

1. **Org-scoped invite links** — the invite carries `org_id` + default role;
   redemption creates user + org membership in one transaction. One
   multi-use link per client ("client link", max-uses + expiry).
   *Trigger: first external client signed.*
2. **Delegated issuance** — a client-side coordinator role may mint/revoke
   invites for *their* org only, with caps.
   *Trigger: our admin becomes the bottleneck.*
3. **Automation surface** — a small internal API ("issue invite for org X"),
   fronted by the admin panel and optionally a Telegram bot handing out
   personal single-use links. The bot is a *client* of the API, never the
   core mechanism — the trust decision (who vouches for this person) lives in
   layers 1–2. *Trigger: a client with a real flow of people.*

## Decision 4 — employees keep invite+password; corp-OIDC is a reserved slot

The password door stays primary for employees indefinitely. When a real
corporate IdP materializes (Ihi grows OIDC, or company AD access is granted),
it plugs in as a `corp_oidc` provider in `identities`, JIT-linking by
`(provider, sub)`; the org's auth policy can then require it and passwords can
be retired — with no schema rework. Building an IdP integration *now* (no IdP
exists) and email/magic-link (no mailer, by standing rule) are both rejected.

## Decision 5 — VK/Yandex are an optional login-link, not a registration door

VK ID / Yandex ID replace #177's Google/Discord/Apple, but demoted from
"registration method" to **optional convenience**: an existing invite-created
account may voluntarily link VK/Yandex and use it to log in — which doubles as
**self-service recovery** (forgot password → sign in via linked provider, no
admin involved). Marginal PII delta (the provider `sub`), no phones, no mass
collection. *Trigger: enough external individuals that admin-issued resets
become a burden.*

## Decision 6 — recovery: admin-issued one-time reset links

The near-term (and only near-term) build item: an admin can mint a
**one-time, short-expiry reset link** bound to a specific user — the same
machinery as invites (hashed token, expiry, single use) — and hand it over any
existing channel, exactly like invites are handed today. Replaces the current
"operator runs code on the server" non-flow. Later, linked VK/Yandex (Decision
5) adds the self-service path on top.

## Decision 7 — MFA: TOTP mandatory for admin roles, optional for the rest

TOTP (offline authenticator apps — free, no SMS/email dependency) becomes
**mandatory for roles with admin power** (they can mint reset links for other
accounts — hijacking an admin = hijacking anyone) and **optional** for
everyone else. Individuals entering via linked VK/Yandex inherit the
provider's own MFA. *Built together with the admin panel* (when the asset it
protects — admin power over people — actually exists), not in phase 1. The
org auth-policy schema reserves an `mfa_required` flag from day one.

## Decision 8 — deactivation is manual until an upstream exists

With no upstream IdP there is nothing to sync from: an admin deactivates a
user (`users.active` = false) and all session tokens are deleted. When
corp-OIDC lands, add a reconcile ("employee left upstream → deactivate") —
JIT login alone never deactivates anyone (RFC §2.4).

**Manual half — done (#251).** `Accounts.deactivate_user/2` · `reactivate_user/2`
(admin-scoped, same authority as reset links, no self-action) set `users.active`
and revoke every session; login is refused at the password check, the session-token
gate, and the TOTP step, without leaking account state. The **upstream reconcile**
half stays trigger-gated on a real corp-OIDC IdP (not built).

## Consequences

- **Positive.** Zero new dependencies and zero new compliance surface today;
  #177's dead-end direction is formally closed; every future addition
  (identities, org policy, TOTP, corp-OIDC, VK/Yandex) lands additively on
  decisions made here — no rework, no re-litigating. The 20 existing users
  migrate by doing nothing.
- **Costs / risks.** Recovery stays admin-mediated until Decision 5's trigger
  fires (acceptable at current scale, linear pain with growth). Passwords
  without MFA remain the weakest link until the admin panel + TOTP ship —
  mitigated by the invite-only perimeter and small user count. The B2C gate
  means the product consciously forgoes open individual sign-up; revisiting
  that is a business decision with a named price, not an engineering default.
- **Neutral.** Nothing shipped changes; today's login/registration code is
  untouched by this ADR.

## Rejected alternatives (and why)

| Alternative | Why rejected |
|---|---|
| **#177: social SSO via Google/Discord/Apple** | Unavailable/blocked for a RU legal entity since Jan 2025 — undeliverable as decided. This ADR supersedes it. |
| External IdP as identity master (eden mirrors) | No IdP exists to be master; conflicts with #172 admin-managed profile; two-master split for employees vs individuals; sync-clobber risk. |
| One account per org (Slack-style) | Breaks "one identity base": a person in two orgs = duplicate accounts/credentials; future cross-org rooms become federation; Slack itself is the cautionary tale. |
| Open B2C self-registration now | Triggers the full 152-FZ package (RU hosting, consents, РКН). Rejected as a default; documented as a gated, priced decision. |
| Phone-OTP auth | Only served the B2C door; carries SMS budget, anti-fraud surface, and sensitive phone PII. Dropped with the door. |
| Email + password / magic-link | Standing "no mailer" rule (RU deliverability from overseas VPS); adds infra to replicate what invite links already do. |
| Build corp-SSO / AD integration now | No OIDC provider or confirmed AD access exists; months of cross-team work for ~20 users. Reserved as a slot instead. |
| `identities` table built in advance | Premature — trivial to introduce with the first real provider; until then it's dead schema. |
| Telegram bot as the core invite mechanism | A bot is a delivery channel, not a trust model; the vouching decision lives in org-scoping + delegation. Bot allowed later as a thin front over the issuance API. |

## Rollout

Only one ticket follows near-term: **admin reset links** (Decision 6).
Everything else waits for its trigger, listed inline above. This document is
the contract those future tickets build to.
