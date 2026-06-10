defmodule Eden.Repo.Migrations.AddLeftAtToMemberships do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      # Per-user "delete chat": the conversation is hidden from this member's list
      # until new activity clears it; the row stays so it can re-surface.
      add :left_at, :utc_datetime
    end
  end
end
