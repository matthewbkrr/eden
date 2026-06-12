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
    # Rooms (corporate layer): a conversation bound to a channel. Referenced by
    # id, not an assoc — channels live in the Channels context.
    field :channel_id, :id
    field :name, :string
    field :position, :integer, default: 0
    # Room access (#41): "open" (any link auto-joins) | "private" (admin add /
    # invite / knock). Nil for DMs/groups. `general` is always "open".
    field :visibility, :string, default: "open"

    # Computed for the conversation list (set by Chat.list_conversations/1).
    field :unread_count, :integer, virtual: true, default: 0
    field :last_message_body, :string, virtual: true
    # The last message's attachment kind (image|video|file) or nil, for the
    # sidebar preview line.
    field :last_message_kind, :string, virtual: true
    # Whether the scoped user muted this chat — directly or via a muted folder.
    field :muted, :boolean, virtual: true, default: false

    # Stable order so an unnamed group's title (built from member names) and the
    # member list don't reshuffle each time the list is re-preloaded.
    has_many :memberships, Eden.Chat.Membership, preload_order: [asc: :id]
    has_many :messages, Eden.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :is_group])
    |> validate_length(:title, max: 100)
  end

  @max_room_name 60
  @visibilities ~w(open private)

  @doc "Changeset for channel rooms (name is the room's identity)."
  def room_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:name, :position, :visibility])
    # Whitespace-only params become a nil change (Ecto's empty_values) — the
    # trim must tolerate nil so validate_required reports the blank.
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: @max_room_name)
    |> validate_inclusion(:visibility, @visibilities)
  end

  def max_room_name, do: @max_room_name
  def visibilities, do: @visibilities
end
