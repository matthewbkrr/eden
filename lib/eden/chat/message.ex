defmodule Eden.Chat.Message do
  @moduledoc """
  A message in a conversation. Belongs to its conversation and to a `sender`
  (a user) — the name/avatar are rendered from the preloaded sender, never copied
  into the row, so profile changes stay additive. `conversation_id` and
  `sender_id` are set programmatically by the context, not cast from user input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_body 4000
  # Idempotency keys are UUIDs (36 chars); cap well above that and reject anything
  # larger so a malformed/hostile value can't bloat the row or overflow the
  # unique index (Postgres btree entries are size-limited, and an oversize value
  # would otherwise raise instead of failing gracefully).
  @max_client_id 64

  schema "messages" do
    field :body, :string
    # Client-generated idempotency key (UUID). See the migration / Chat dedup.
    field :client_id, :string
    # "Delete for both" tombstone: when set, body/attachment are cleared and the
    # row renders as "Message deleted".
    field :deleted_at, :utc_datetime
    # Set the first time the author edits the text/caption (#164); the UI shows
    # "(edited)" + this time. No edit window (Telegram-style).
    field :edited_at, :utc_datetime

    belongs_to :conversation, Eden.Chat.Conversation
    belongs_to :sender, Eden.Accounts.User
    # Self-reference: the original this message was forwarded from (if any).
    belongs_to :forwarded_from, Eden.Chat.Message
    # Self-reference: the message this one quotes (quote-reply, #71). Set by the
    # context after validation (same conversation, visible) — never cast from
    # params. Distinct from `root_id` (threads).
    belongs_to :reply_to, Eden.Chat.Message
    # Albums (#58): a message carries an ordered list of attachments (one for a
    # plain photo/file send, several for an album). Always preload/render via
    # this list — ordered by `position` so the grid is deterministic.
    has_many :attachments, Eden.Chat.Attachment, preload_order: [asc: :position]
    # Emoji reactions (#67); raw rows, aggregated to chips (emoji → count + mine)
    # in the web layer so each viewer computes "mine" from their own id.
    has_many :reactions, Eden.Chat.MessageReaction

    # Threads (flat, Mattermost-style): a reply points at its root; the root
    # carries denormalized counters maintained by the context.
    belongs_to :root, Eden.Chat.Message
    field :reply_count, :integer, default: 0
    field :last_reply_at, :utc_datetime
    # Set when building room lists: collapse the avatar/name header for
    # consecutive same-author messages (flat layout). Never persisted.
    field :compact, :boolean, virtual: true, default: false

    # "user" | "system". A system message (no human sender) carries its payload
    # in `meta` (e.g. %{"action" => "join_request", "requester_id" => id,
    # "requester_name" => name, "status" => "pending"}). #41 knock flow.
    field :kind, :string, default: "user"
    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc "Max body length in codepoints; oversized sends are split into parts (#68)."
  def max_body, do: @max_body

  @doc "Whether this is a system message (no human sender; renders from `meta`)."
  def system?(%__MODULE__{kind: "system"}), do: true
  def system?(%__MODULE__{}), do: false

  @doc "Whether the message has been deleted for everyone (tombstoned)."
  def deleted?(%__MODULE__{deleted_at: nil}), do: false
  def deleted?(%__MODULE__{}), do: true

  @doc "Changeset for a text message: a non-blank body is required."
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :client_id])
    |> update_change(:body, &sanitize/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body, count: :codepoints)
    |> validate_length(:client_id, max: @max_client_id)
    |> dedup_constraint()
  end

  @doc """
  Changeset for a photo message: the body (caption) is optional and defaults to
  an empty string — the attachment is the content.
  """
  def photo_changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :client_id])
    |> update_change(:body, &sanitize/1)
    |> ensure_body()
    |> validate_length(:body, max: @max_body, count: :codepoints)
    |> validate_length(:client_id, max: @max_client_id)
    |> dedup_constraint()
  end

  @doc """
  Changeset for an edit (#164): re-sanitizes the body like a create. A text-only
  message requires a non-blank body (blanking it = delete instead); a message with
  attachments may blank its caption. `edited_at` is stamped by the context. Expects
  `message.attachments` preloaded to pick the rule.
  """
  def edit_changeset(message, attrs) do
    has_media? = match?([_ | _], message.attachments)

    message
    |> cast(attrs, [:body])
    |> update_change(:body, &sanitize/1)
    |> then(&if(has_media?, do: ensure_body(&1), else: validate_required(&1, :body)))
    |> validate_length(:body, max: @max_body, count: :codepoints)
  end

  # Surfaces the (sender_id, client_id) unique index as a changeset error the
  # context can recognise as a duplicate resend.
  defp dedup_constraint(changeset) do
    unique_constraint(changeset, :client_id, name: :messages_sender_id_client_id_index)
  end

  defp ensure_body(changeset) do
    if get_field(changeset, :body) in [nil, ""],
      do: put_change(changeset, :body, ""),
      else: changeset
  end

  # Postgres rejects NUL bytes even though they're valid UTF-8; strip them and
  # trim surrounding whitespace (a whitespace-only message becomes "" and fails
  # validate_required).
  defp sanitize(nil), do: nil
  defp sanitize(body), do: body |> String.replace("\0", "") |> String.trim()
end
