defmodule Eden.Repo.Migrations.AddReplyToToMessages do
  use Ecto.Migration

  # Quote-reply (#71): a message may reference another it quotes. Distinct from
  # threads (`root_id`). `nilify_all` so a hard-deleted target leaves the reply
  # intact (its quote just renders unavailable); a delete-for-both target is a
  # soft tombstone (row survives), so the quote can show "Message deleted".
  def change do
    alter table(:messages) do
      add :reply_to_id, references(:messages, on_delete: :nilify_all)
    end

    create index(:messages, [:reply_to_id])
  end
end
