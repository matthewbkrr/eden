defmodule Eden.Repo.Migrations.CreateChat do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :title, :string
      add :is_group, :boolean, null: false, default: false
      add :last_message_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create table(:memberships) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      add :last_read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:conversation_id, :user_id])
    create index(:memberships, [:user_id])

    create table(:messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :sender_id, references(:users, on_delete: :nilify_all)
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:conversation_id, :inserted_at])
  end
end
