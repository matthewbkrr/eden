defmodule Eden.Chat.FolderPrefs do
  @moduledoc """
  Per-user chat preferences (one row per user) — the bits of personal chat state
  with no natural home on another row:

    * `all_chats_position` — the virtual "All Chats" tab has no `Folder` row, so
      the spot it occupies among the user's folders lives here (0 = first).
      Written by `Chat.reorder_folders/2`.
    * `quick_reactions` — the user's personal quick-react row (#67); `nil` means
      "use the default set". Written by `Chat.set_quick_reactions/2`.
  """
  use Ecto.Schema

  schema "chat_folder_prefs" do
    field :all_chats_position, :integer, default: 0
    field :quick_reactions, {:array, :string}

    belongs_to :user, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
