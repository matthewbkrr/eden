defmodule Eden.Repo.Migrations.AddLastActiveAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # When the user last fully disconnected (#102), for "last seen" on offline
      # peers. Nullable: unset until a user's first disconnect after this ships.
      add :last_active_at, :utc_datetime
    end
  end
end
