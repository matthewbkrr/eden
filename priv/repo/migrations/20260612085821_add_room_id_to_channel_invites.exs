defmodule Eden.Repo.Migrations.AddRoomIdToChannelInvites do
  use Ecto.Migration

  def change do
    alter table(:channel_invites) do
      # A room invite (#41): nil for a plain channel invite; set for a private-
      # room invite, whose redemption joins the channel (general) AND this room
      # in one transaction. Cascades if the room is deleted.
      add :room_id, references(:conversations, on_delete: :delete_all)
    end

    create index(:channel_invites, [:room_id])
  end
end
