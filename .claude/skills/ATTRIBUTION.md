# Vendored skills — attribution

The `*-thinking` and `using-elixir-skills` skills in this directory are vendored
from a third-party project, not authored here.

- **Source:** https://github.com/georgeguimaraes/claude-code-elixir
- **Path in source:** `plugins/elixir/skills/`
- **Commit:** `36ce0002f65b41d8c040a578c394049b1e7fea14`
- **License:** Apache License 2.0 — see `LICENSE.claude-code-elixir` in this directory.
- **Copyright:** © 2025 George Guimarães

Vendored skills (kept verbatim):

- `elixir-thinking` — mental models for writing Elixir (vs OOP).
- `phoenix-thinking` — Phoenix / LiveView architecture & lifecycle.
- `ecto-thinking` — Ecto, schemas, changesets, contexts.
- `otp-thinking` — OTP primitives (GenServer/Supervisor/Task/…).
- `using-elixir-skills` — router that points at the skill above to use first.

> `oban-thinking` from the upstream package is intentionally **not** vendored
> (Oban is not a dependency yet). The `using-elixir-skills` router still lists an
> Oban row; it is inert until Oban is added. To add it later, copy that one
> folder from the source repo.

To update: re-copy the folders from the source repo at a newer commit and bump
the commit SHA above.
