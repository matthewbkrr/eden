defmodule Eden.Repo.Migrations.CreateThreadMemberships do
  use Ecto.Migration

  def change do
    create table(:thread_memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :root_id, references(:messages, on_delete: :delete_all), null: false
      add :following, :boolean, null: false, default: true
      add :last_viewed_at, :utc_datetime
      add :unread_replies, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # One row per (user, thread root). The composite also serves the
    # list-followed-threads-for-user query (user_id is the prefix).
    create unique_index(:thread_memberships, [:user_id, :root_id])
    # Increment-on-reply fans out over all followers of a root.
    create index(:thread_memberships, [:root_id])
  end
end
