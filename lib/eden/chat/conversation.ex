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
    # Storage key of the processed group photo (#178, set by Chat.set_group_avatar/3),
    # or nil → initials fallback. Mirrors users/channels avatar_key.
    field :avatar_key, :string
    field :last_message_at, :utc_datetime
    # Rooms (corporate layer): a conversation bound to a channel. Referenced by
    # id, not an assoc — channels live in the Channels context.
    field :channel_id, :id
    field :name, :string
    field :position, :integer, default: 0
    # Room access (#41): "open" (any link auto-joins) | "private" (admin add /
    # invite / knock). Only consulted for channel rooms; DMs/groups carry the
    # default "open" as dead data (never read). `general` is always "open".
    field :visibility, :string, default: "open"
    # The channel's Town Square: always open, undeletable, auto-joined on
    # channel entry. One source of truth for the join/undeletable/open guards.
    field :is_general, :boolean, default: false

    # Computed for the conversation list (set by Chat.list_conversations/1).
    field :unread_count, :integer, virtual: true, default: 0
    field :last_message_body, :string, virtual: true
    # The last message's first-attachment kind (image|video|file) or nil, for the
    # sidebar preview line.
    field :last_message_kind, :string, virtual: true
    # How many attachments that message carries (#58) — drives "N photos" in the
    # preview; 0/1 render as a single item.
    field :last_message_attachment_count, :integer, virtual: true, default: 0
    # Whether the scoped user muted this chat — directly or via a muted folder.
    field :muted, :boolean, virtual: true, default: false
    # Whether the scoped user favorited this room (#42) — set by list_rooms.
    field :favorite, :boolean, virtual: true, default: false

    # Stable order so an unnamed group's title (built from member names) and the
    # member list don't reshuffle each time the list is re-preloaded.
    has_many :memberships, Eden.Chat.Membership, preload_order: [asc: :id]
    has_many :messages, Eden.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :is_group])
    # Same sanitizer as the rename path (title_changeset): a crafted create-title
    # with an embedded NUL would otherwise reach Postgres and raise Postgrex.Error
    # instead of yielding a clean value (#267).
    |> update_change(:title, &normalize_title/1)
    |> validate_length(:title, max: 100)
  end

  @doc "Changeset for renaming a group (#165, owner/admin). A blank title clears it → auto name."
  def title_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title])
    |> update_change(:title, &normalize_title/1)
    |> validate_length(:title, max: 100)
  end

  defp normalize_title(nil), do: nil

  defp normalize_title(title) do
    case title |> String.replace("\0", "") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
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
    |> validate_general_stays_open(conversation)
  end

  # The epic's core invariant (#41): general is always open — auto-joined on
  # channel entry, so it must never become private (a crafted rename payload
  # could otherwise flip it; the UI doesn't offer it, this is the backstop).
  defp validate_general_stays_open(changeset, %__MODULE__{is_general: true}) do
    validate_change(changeset, :visibility, fn :visibility, value ->
      if value == "open", do: [], else: [visibility: "general is always open"]
    end)
  end

  defp validate_general_stays_open(changeset, _conversation), do: changeset

  def max_room_name, do: @max_room_name
  def visibilities, do: @visibilities
end
