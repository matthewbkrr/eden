defmodule Eden.Chat.Conversation do
  @moduledoc """
  A conversation thread. The same model backs both 1:1 and group chats:
  `is_group` distinguishes them and `title` is used for groups (1:1s render the
  other participant's name). `last_message_at` is a denormalized sort key for the
  conversation list, updated when a message is sent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    field :title, :string
    field :is_group, :boolean, default: false
    field :last_message_at, :utc_datetime

    has_many :memberships, Eden.Chat.Membership
    has_many :messages, Eden.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :is_group])
    |> validate_length(:title, max: 100)
  end
end
