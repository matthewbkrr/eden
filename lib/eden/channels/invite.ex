defmodule Eden.Channels.Invite do
  @moduledoc """
  A shareable invite link into a channel — the same shape as registration
  invites (`Eden.Accounts.Invite`): the raw token lives only in the generated
  URL, the database stores its SHA-256 hash, and validity is derived from
  `expires_at`, `used_count` vs `max_uses` (nil = unlimited), and `revoked_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "channel_invites" do
    field :hashed_token, :string, redact: true
    field :expires_at, :utc_datetime
    field :max_uses, :integer
    field :used_count, :integer, default: 0
    field :revoked_at, :utc_datetime

    belongs_to :channel, Eden.Channels.Channel
    belongs_to :created_by, Eden.Accounts.User
    # Set for a private-room invite (#41): redemption joins the channel + this
    # room. Nil for a plain channel invite.
    belongs_to :room, Eden.Chat.Conversation

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating an invite (`hashed_token`/ids set by the context)."
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [:expires_at, :max_uses])
    |> validate_required([:hashed_token, :expires_at])
    |> validate_number(:max_uses, greater_than: 0)
    |> unique_constraint(:hashed_token)
    |> assoc_constraint(:channel)
  end
end
