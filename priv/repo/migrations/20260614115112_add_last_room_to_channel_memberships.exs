defmodule Eden.Repo.Migrations.AddLastRoomToChannelMemberships do
  use Ecto.Migration

  # Remember the last-opened room per (user, channel) (#81) so re-entering a
  # channel reopens it instead of the "pick a room" empty state. Nilified if the
  # room is deleted; a room the user lost access to is filtered out at read time
  # (Chat.entry_room_ids/2), falling back to the channel's general room.
  def change do
    alter table(:channel_memberships) do
      add :last_room_id, references(:conversations, on_delete: :nilify_all)
    end
  end
end
