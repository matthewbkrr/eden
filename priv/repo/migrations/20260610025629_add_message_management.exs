defmodule Eden.Repo.Migrations.AddMessageManagement do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Tombstone for "delete for both": set, body/attachment cleared, kept as a row.
      add :deleted_at, :utc_datetime
      # Original message a forward was copied from (nil once that original is hard-deleted).
      add :forwarded_from_id, references(:messages, on_delete: :nilify_all)
    end

    create index(:messages, [:forwarded_from_id])

    # "Delete for me": a per-user hide. The message stays for everyone else.
    create table(:message_deletions) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:message_deletions, [:message_id, :user_id])
  end
end
