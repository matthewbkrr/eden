defmodule Eden.Chat.Folder do
  @moduledoc """
  A per-user chat folder: a personal grouping of conversations in the owner's
  sidebar. Folders never affect other members. "All Chats" is virtual (no row);
  only custom folders are persisted. `position` orders the folder tabs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_name 40

  schema "chat_folders" do
    field :name, :string
    field :position, :integer, default: 0

    # Per-folder unread total, computed for the tab badge (Chat.list_folders/1).
    field :unread_count, :integer, virtual: true, default: 0

    belongs_to :user, Eden.Accounts.User
    has_many :folder_memberships, Eden.Chat.FolderMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:name, :position])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name)
  end

  def max_name, do: @max_name
end
