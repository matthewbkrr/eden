defmodule Eden.Repo.Migrations.AddMutedAtToChannelMemberships do
  use Ecto.Migration

  def change do
    alter table(:channel_memberships) do
      # Per-user channel mute (badge-only, like memberships.muted_at for chats
      # and chat_folders.muted_at for folders): a muted channel's rail badge
      # renders de-emphasized.
      add :muted_at, :utc_datetime
    end
  end
end
