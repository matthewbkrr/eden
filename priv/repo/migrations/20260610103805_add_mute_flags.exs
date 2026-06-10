defmodule Eden.Repo.Migrations.AddMuteFlags do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      # Per-user chat mute: set = muted (suppressed from badge emphasis).
      add :muted_at, :utc_datetime
    end

    alter table(:chat_folders) do
      # Folder mute: mutes the whole grouping (folders are per-user already).
      add :muted_at, :utc_datetime
    end
  end
end
