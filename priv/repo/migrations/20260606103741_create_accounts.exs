defmodule Eden.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    # citext gives case-insensitive unique usernames without manual lower() indexes.
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users) do
      add :username, :citext, null: false
      add :display_name, :string, null: false
      add :hashed_password, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])

    create table(:invites) do
      add :hashed_token, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :max_uses, :integer, null: false, default: 1
      add :used_count, :integer, null: false, default: 0
      add :revoked_at, :utc_datetime
      add :inviter_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invites, [:hashed_token])
    create index(:invites, [:inviter_id])
  end
end
