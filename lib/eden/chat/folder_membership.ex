defmodule Eden.Chat.FolderMembership do
  @moduledoc """
  Join between a `Folder` and a `Conversation`: the conversation is filed in the
  folder. A conversation can be in many folders; unique on the pair. Both sides
  cascade-delete (dropping a folder, a conversation, or the user removes the row).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_folder_memberships" do
    belongs_to :folder, Eden.Chat.Folder
    belongs_to :conversation, Eden.Chat.Conversation

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:folder_id, :conversation_id])
    |> validate_required([:folder_id, :conversation_id])
    |> assoc_constraint(:folder)
    |> assoc_constraint(:conversation)
    |> unique_constraint([:folder_id, :conversation_id],
      name: :chat_folder_memberships_folder_id_conversation_id_index
    )
  end
end
