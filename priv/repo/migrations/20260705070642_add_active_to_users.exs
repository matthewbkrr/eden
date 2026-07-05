defmodule Eden.Repo.Migrations.AddActiveToUsers do
  use Ecto.Migration

  # Manual user deactivation (#251, ADR-0002 Decision 8). Expand-only: a NOT NULL
  # boolean with a `true` default — Postgres backfills existing rows to `true`, so
  # everyone stays active until an admin explicitly deactivates them. Reversible
  # (drop column).
  def change do
    alter table(:users) do
      add :active, :boolean, default: true, null: false
    end
  end
end
