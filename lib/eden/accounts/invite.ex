defmodule Eden.Accounts.Invite do
  @moduledoc """
  A single- or multi-use invitation to join eden. The raw token lives only in the
  invite URL; the database stores its SHA-256 hash, so a DB leak does not expose
  usable links. Validity is derived from `expires_at`, `used_count` vs `max_uses`,
  and `revoked_at` — there is no mutable status column to drift out of sync.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "invites" do
    field :hashed_token, :string, redact: true
    field :expires_at, :utc_datetime
    field :max_uses, :integer, default: 1
    field :used_count, :integer, default: 0
    field :revoked_at, :utc_datetime

    belongs_to :inviter, Eden.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating an invite. `hashed_token` and `inviter_id` are set by the context."
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [:expires_at, :max_uses])
    |> validate_required([:hashed_token, :inviter_id, :expires_at])
    |> validate_number(:max_uses, greater_than: 0)
    |> unique_constraint(:hashed_token)
    |> assoc_constraint(:inviter)
  end
end
