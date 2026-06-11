defmodule Eden.Repo.Migrations.AddRoomsToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # A room is a conversation bound to a channel (nil = DM/group as before);
      # deleting the channel cascades its rooms (blob GC happens app-side).
      add :channel_id, references(:channels, on_delete: :delete_all)
      # Room display name (DMs/groups keep using title/participants).
      add :name, :string
      # Room order within the channel sidebar.
      add :position, :integer, null: false, default: 0
    end

    create index(:conversations, [:channel_id, :position])
  end
end
