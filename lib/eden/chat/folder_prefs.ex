defmodule Eden.Chat.FolderPrefs do
  @moduledoc """
  Per-user folder preferences. The virtual "All Chats" tab has no `Folder` row,
  so the spot it occupies among the user's folders lives here
  (`all_chats_position`, 0 = first). Written by `Chat.reorder_folders/2`.
  """
  use Ecto.Schema

  schema "chat_folder_prefs" do
    field :all_chats_position, :integer, default: 0

    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
