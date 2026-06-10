defmodule Eden.Repo.Migrations.CreateChatFolderPrefs do
  use Ecto.Migration

  def change do
    # Per-user folder preferences. The virtual "All Chats" tab has no
    # chat_folders row, so its position among the folders is stored here.
    create table(:chat_folder_prefs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :all_chats_position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_folder_prefs, [:user_id])
  end
end
