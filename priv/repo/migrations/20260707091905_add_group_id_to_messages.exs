defmodule Eden.Repo.Migrations.AddGroupIdToMessages do
  use Ecto.Migration

  # Telegram-style file grouping (TG-attachments epic): the files of one send share a
  # server-minted `group_id` so consecutive rows render as one merged bubble, while each
  # file stays its own message (per-file delete/forward/reply survive). Photo albums keep
  # the one-message-N-attachments model, so their rows carry no group_id.
  #
  # The overwhelming majority of messages are ungrouped, so the index is PARTIAL — it only
  # holds grouped rows (fast "other rows of this group" / "notify-once" lookups) without
  # bloating on the NULL common case.
  def change do
    alter table(:messages) do
      add :group_id, :uuid
    end

    create index(:messages, [:conversation_id, :group_id], where: "group_id IS NOT NULL")
  end
end
