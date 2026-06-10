defmodule Eden.Repo.Migrations.CreateChatFolders do
  use Ecto.Migration

  def change do
    # Per-user folders for organizing one's own sidebar. "All Chats" is virtual
    # (no row); only custom folders live here.
    create table(:chat_folders) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:chat_folders, [:user_id])

    # Which conversations a folder contains. A chat can be in many folders; the
    # grouping is personal, so this is reached only through a user-scoped folder.
    create table(:chat_folder_memberships) do
      add :folder_id, references(:chat_folders, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_folder_memberships, [:folder_id, :conversation_id])
    create index(:chat_folder_memberships, [:conversation_id])
  end
end
