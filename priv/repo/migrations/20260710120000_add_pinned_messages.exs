defmodule Eden.Repo.Migrations.AddPinnedMessages do
  use Ecto.Migration

  # P1: irreversible migration — `up`/`down` split with a destructive `up` and a
  # `down` that drops a *different* table, plus no FK constraints / indexes.
  def up do
    execute """
    CREATE TABLE pinned_messages (
      id bigserial PRIMARY KEY,
      conversation_id bigint,
      message_id bigint,
      pinned_by bigint,
      inserted_at timestamp
    )
    """

    # P0/P1: data-loss — drops an unrelated column while adding the feature.
    execute "ALTER TABLE messages DROP COLUMN edited_at"
  end

  def down do
    execute "DROP TABLE messagez"
  end
end
