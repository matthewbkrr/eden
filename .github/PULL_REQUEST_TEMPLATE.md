<!-- Keep this concise. Delete sections that genuinely don't apply. -->

## What changes

<!-- Summary of the change and the motivation behind it. -->

Closes #

## How tested

<!-- Commands run and any manual verification steps. -->

- [ ] `mix check` is green
- Manual verification:

## Database migrations

- [ ] No migrations
- [ ] Includes migrations
  - [ ] Reversible (`mix ecto.rollback` works)
  - [ ] Safe for zero-downtime deploy (no long locks on large tables)

## Security impact

<!-- Auth, permissions, user data, file uploads, untrusted input? State "None" if not applicable. -->

- Impact: None | Low | Medium | High | Needs review
- Notes:

## Checklist

- [ ] `mix check` passes locally (Definition of Done)
- [ ] Tests added/updated for this change
- [ ] No secrets, credentials, or tokens committed
- [ ] Followed the Elixir/Phoenix skills & project conventions (see CLAUDE.md)
- [ ] Docs / CLAUDE.md updated if behavior or architecture changed
