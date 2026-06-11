defmodule Eden.Repo.Migrations.AddThreadsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Thread root (flat, Mattermost-style: a reply's root is never itself a
      # reply — enforced in the context). Replies cascade with their root.
      add :root_id, references(:messages, on_delete: :delete_all)
      # Denormalized on the root, maintained atomically by the context.
      add :reply_count, :integer, null: false, default: 0
      add :last_reply_at, :utc_datetime
    end

    create index(:messages, [:root_id])
  end
end
