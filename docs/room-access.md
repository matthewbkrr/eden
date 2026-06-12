# Room access (epic #41)

Design doc for the room-access epic. **Channels are never closed**: any link
into a channel auto-joins it (you land in `general`). Rooms beyond `general`
are earned per room, and the sidebar only ever lists rooms you're a member of —
rooms are discovered through links, not browsing.

Shipped in **3 phases** (decided 2026-06-12):

- **PR-A — foundation (this PR).** `conversations.visibility`, room creation
  with a visibility, and the pure access verdict + design doc. **No behavior
  change, no destructive migration** — the app works exactly as before.
- **PR-B — behavior + migration.** `join_room/2` (channel join materializes
  `general` only), auto-join on open-room links, the knock window on
  private-room links, web wiring (`handle_params`), and the destructive
  migration (reset non-`general` memberships → everyone re-enters under the new
  rules; all rooms become `open`). Reversible by schema, not by data; prod is
  not yet deployed, so this is a dev-only effect documented in that PR.
- **PR-C — knock + invites.** System messages with actions (request →
  admin «Добавить» → join), private-room invite tokens, the internal-add
  matrix.

## Data model

`conversations.visibility :: "open" | "private"` (default `"open"`). Only
consulted for channel rooms; DMs/groups carry the default as dead data.
`general` is always `"open"` and undeletable.

- **open** (`#`): a plain link to the room or any of its messages **auto-joins**
  (channel first if needed) and lands you there. No invite tokens — the plain
  link *is* the invite.
- **private** (🔒): a plain link lands you in the channel with a **knock**
  window; entry without knocking is an admin add or an admin-created invite
  token.

## Access matrix (rev. 3)

The web layer (PR-B) first ensures **channel** membership — an idempotent join
to `general`, since channels are never closed — then acts on the **room**
verdict from `Chat.resolve_room_access/1`:

| room_member? | visibility | verdict      | effect                                   |
|--------------|------------|--------------|------------------------------------------|
| true         | any        | `:member`    | open the room                            |
| false        | open       | `:open_join` | auto-join the room, then open            |
| false        | private    | `:knock`     | land in the channel, show the knock window |

Channel-membership is orthogonal to the verdict — it only adds a preceding
idempotent `general` join. So a non-channel-member following an open-room link
joins the channel **and** the room; following a private-room link joins the
channel, then knocks.

`resolve_room_access/1` is pure (no DB) and lives in `Eden.Chat`; PR-B gathers
the facts (`room_member?`, `visibility`) and performs the side effects.

## Invite & internal-add (PR-C)

- **Channel invite token** (exists): joins the channel; now functionally a
  shareable plain link (expiry / max-uses still gate redemptions).
- **Private-room invite token** (admin-created, hash-only, mirrors channel
  invites): grants `general` + the room in one transaction — the no-knock fast
  path. Open rooms get no tokens.
- **Internal add** (no acceptance step): private rooms — channel admins only;
  open rooms — admin add too; the picker may search the whole platform (a
  non-channel user gets `general` + the room). A private-room member without
  admin rights can only share the plain link — the recipient knocks.

## Knock-to-join (PR-C, private rooms only)

Explicit «Запросить вступление» button (no auto-send on visit). It posts a
**system message into the private room** ("Пользователь X отправил запрос на
вступление") with an inline «Добавить» button for channel admins. Accepting
adds the membership and flips the message to an accepted state. One pending
request per (user, room); repeat presses show "Запрос отправлен". After
acceptance the requester's sidebar updates live.

### System messages with actions (new infrastructure, PR-C)

A message subtype — no human sender, a `system` kind + metadata (action,
requester_id, status `pending|accepted`) — rendered flat with the action
button; state survives reloads; rides the same realtime stream. Schema, button
authorization, both-layout rendering, and "X joined" follow-ups are detailed
when PR-C lands.

## No-leak invariants (verified each phase)

A non-member sees a room (open or private) in **neither** the sidebar, search,
nor badges. Open-room permalinks auto-join; private-room permalinks knock — they
never reveal contents pre-membership.
