defmodule Eden.Repo.Migrations.AddUsersDeletedAt do
  use Ecto.Migration

  # #303: permanent account deletion by anonymization. `deleted_at` marks a row whose
  # PII/credentials have been scrubbed (distinct from #251 `active=false`, which is
  # reversible). The row survives so its messages stay attributed; it's filtered out of
  # rosters/pickers. Reversible: dropping the column only loses the marker.
  def change do
    alter table(:users) do
      add :deleted_at, :utc_datetime
    end
  end
end
