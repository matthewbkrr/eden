defmodule Eden.Repo.Migrations.CreateMessageReactions do
  use Ecto.Migration

  # Emoji reactions on messages (#67), in DMs and rooms alike. One row per
  # (message, user, emoji); a message delete cascades its reactions.
  def change do
    create table(:message_reactions) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :emoji, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # The composite unique index already serves `WHERE message_id = ?` via its
    # leading column, so no standalone message_id index is needed.
    create unique_index(:message_reactions, [:message_id, :user_id, :emoji])
  end
end
