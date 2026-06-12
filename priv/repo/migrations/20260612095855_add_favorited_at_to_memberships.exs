defmodule Eden.Repo.Migrations.AddFavoritedAtToMemberships do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      # Per-user room favorite (#42): favorited rooms float to the top of the
      # channel sidebar as an "Favorites" block. Lives on the membership row —
      # per (conversation, user), like mute.
      add :favorited_at, :utc_datetime
    end
  end
end
